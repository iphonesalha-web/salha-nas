import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: BackupEngine
    @State private var showSettings = false
    @State private var config = NASConfig.load()
    @State private var photosOK = BackupEngine.photosAllowed

    private static let dateF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: engine.isRunning ? "arrow.up.circle.fill" : "externaldrive.fill.badge.checkmark")
                            .font(.system(size: 54))
                            .foregroundColor(.accentColor)
                            .padding(.top, 8)

                        HStack(spacing: 0) {
                            stat("\(engine.backedUp)", "تم نسخها")
                            Divider().frame(height: 40)
                            stat("\(engine.pending)", "بانتظار النسخ")
                        }

                        if engine.isRunning {
                            ProgressView(value: Double(engine.done), total: Double(max(engine.total, 1)))
                            Text("\(engine.done) من \(engine.total)")
                                .font(.subheadline.monospacedDigit())
                            Text(engine.status)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if let last = engine.lastRun {
                            VStack(spacing: 4) {
                                Text("آخر نسخ: " + Self.dateF.string(from: last))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Text(engine.lastMessage)
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                Section {
                    if !photosOK {
                        Button {
                            Task { photosOK = await BackupEngine.requestPhotos(); engine.refreshCounts() }
                        } label: {
                            Label("السماح بالوصول إلى الصور", systemImage: "photo.on.rectangle")
                        }
                    } else if !config.isComplete {
                        Button { showSettings = true } label: {
                            Label("أكمل إعدادات الـ NAS", systemImage: "gearshape")
                        }
                    } else if engine.isRunning {
                        Button(role: .destructive) { engine.cancel() } label: {
                            Label("إيقاف النسخ", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            Notifier.requestPermission()
                            ForegroundBackup.start()
                        } label: {
                            Label("ابدأ النسخ الآن", systemImage: "arrow.up.to.line")
                                .font(.headline)
                        }
                    }
                } footer: {
                    if engine.isRunning {
                        Text("تقدر تقفل الشاشة، والنسخ يكمل مع شريط تقدّم على شاشة القفل.")
                    }
                }

                Section(header: Text("النسخ التلقائي كل يوم")) {
                    Label("كل ليلة والهاتف على الشاحن والواي فاي، يبدأ النسخ وحده والهاتف مقفل.",
                          systemImage: "moon.zzz")
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("لضمان أكثر، أضف أتمتة:", systemImage: "bolt.badge.automatic")
                            .font(.subheadline.weight(.semibold))
                        Text("الاختصارات ← أتمتة ← + ← «الشاحن» ← «متصل» ← تشغيل فوراً ← أضف إجراء «نسخ الصور إلى NAS».")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section(header: Text("الوجهة")) {
                    row("السيرفر", config.host)
                    row("الاتصال", "FTP")
                    row("المجلد", "/" + (config.cleanFolder.isEmpty ? "" : config.cleanFolder + "/") + "السنة/الشهر")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("صالحة NAS")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(engine.isRunning)
                }
            }
            .refreshable { engine.refreshCounts() }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showSettings, onDismiss: {
            config = NASConfig.load()
            engine.refreshCounts()
        }) {
            SettingsView()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .onAppear {
            LocalNetworkPrompt.shared.trigger()
            photosOK = BackupEngine.photosAllowed
            if !photosOK {
                Task { photosOK = await BackupEngine.requestPhotos(); engine.refreshCounts() }
            }
            engine.refreshCounts()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cfg = NASConfig.load()
    @State private var password = NASConfig.load().password
    @State private var busy = false
    @State private var testResult = ""
    @State private var showFolders = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("الـ FRITZ!Box"),
                        footer: Text("عادةً العنوان fritz.box أو 192.168.178.1. المستخدم وكلمة المرور هما حساب FRITZ!NAS.")) {
                    field("العنوان", $cfg.host)
                    field("اسم المستخدم", $cfg.username)
                    SecureField("كلمة المرور", text: $password, prompt: Text("كلمة المرور"))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .environment(\.layoutDirection, .leftToRight)
                }

                Section(header: Text("مكان النسخ"),
                        footer: Text("الاتصال عبر FTP. تأكد أن «Zugriff über FTP» مفعّل في الـ FRITZ!Box. يظهر كل قرص كمجلد.")) {
                    Button {
                        save()
                        showFolders = true
                    } label: {
                        HStack {
                            Label("مكان النسخ", systemImage: "folder")
                            Spacer()
                            Text("/" + cfg.cleanFolder)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                    .disabled(busy || password.isEmpty)
                }

                Section(header: Text("الخيارات")) {
                    Toggle("نسخ الفيديوهات أيضاً", isOn: $cfg.includeVideos)
                    Toggle("على الواي فاي فقط", isOn: $cfg.wifiOnly)
                }

                Section(footer: Text(testResult).environment(\.layoutDirection, .rightToLeft)) {
                    Button {
                        Task {
                            busy = true
                            testResult = "جاري الفحص…"
                            testResult = await NetworkCheck.run(host: cfg.host)
                            busy = false
                        }
                    } label: {
                        Label("فحص الشبكة", systemImage: "stethoscope")
                    }
                    .disabled(busy)
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("اختبار الاتصال", systemImage: "antenna.radiowaves.left.and.right")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy)
                }
            }
            .sheet(isPresented: $showFolders) {
                FolderPicker(cfg: cfg, selection: $cfg.folder)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("حفظ") { save(); dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .environment(\.layoutDirection, .leftToRight)
    }

    private func save() {
        cfg.save()
        cfg.password = password
    }

    private func test() async {
        save()
        if password.isEmpty { testResult = "اكتب كلمة المرور أولاً."; return }
        busy = true
        defer { busy = false }
        do {
            let store = try await Remote.open(cfg)
            let dirs = (try? await store.listDirs(cfg.cleanFolder)) ?? []
            await store.close()
            testResult = "✓ الاتصال ناجح (\(dirs.count) مجلد في مكان النسخ)"
        } catch {
            testResult = "✗ " + NASError.describe(error)
        }
    }
}


/// متصفح مجلدات داخل المجلد المشترك لاختيار مكان النسخ
struct FolderPicker: View {
    let cfg: NASConfig
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var store: RemoteStore?
    @State private var path: [String] = []
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var error = ""
    @State private var showNew = false
    @State private var newName = ""

    private var current: String { path.joined(separator: "/") }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text("/" + current)
                            .lineLimit(2)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .foregroundColor(.secondary)
                    if !path.isEmpty {
                        Button {
                            path.removeLast()
                            Task { await load() }
                        } label: {
                            Label("رجوع للمجلد الأعلى", systemImage: "arrow.turn.left.up")
                        }
                    }
                }

                Section(header: Text("المجلدات")) {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if folders.isEmpty && error.isEmpty {
                        Text("لا توجد مجلدات هنا").foregroundColor(.secondary)
                    }
                    ForEach(folders, id: \.self) { f in
                        Button {
                            path.append(f)
                            Task { await load() }
                        } label: {
                            HStack {
                                Label(f, systemImage: "folder.fill")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.left")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(loading)
                    }
                }

                Section {
                    Button {
                        newName = "iPhone-Backup"
                        showNew = true
                    } label: {
                        Label("مجلد جديد هنا", systemImage: "folder.badge.plus")
                    }
                    .disabled(loading || store == nil)
                }

                if !error.isEmpty {
                    Section { Text(error).foregroundColor(.red).font(.footnote) }
                }

                Section(footer: Text("الصور تُحفظ داخل المجلد الذي تختاره، مرتّبة في مجلدات حسب السنة والشهر.")) {
                    Button {
                        selection = current
                        dismiss()
                    } label: {
                        Label("اختيار هذا المجلد", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    }
                    .disabled(loading || store == nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("اختر مكان النسخ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
            }
            .alert("مجلد جديد", isPresented: $showNew) {
                TextField("اسم المجلد", text: $newName)
                Button("إنشاء") { Task { await create() } }
                Button("إلغاء", role: .cancel) {}
            }
            .task {
                let start = cfg.cleanFolder
                path = start.isEmpty ? [] : start.split(separator: "/").map(String.init)
                await load()
                if !error.isEmpty && !path.isEmpty {   // المجلد المحفوظ غير موجود → نبدأ من الجذر
                    path = []
                    await load()
                }
            }
            .onDisappear {
                let s = store
                Task { await s?.close() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        loading = true
        error = ""
        defer { loading = false }
        do {
            if store == nil { store = try await Remote.open(cfg) }
            guard let store = store else { return }
            folders = try await store.listDirs(current)
                .filter { !$0.hasPrefix(".") && !$0.hasPrefix("$") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            folders = []
            self.error = NASError.describe(error)
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !name.isEmpty, let store = store else { return }
        let target = current.isEmpty ? name : current + "/" + name
        do {
            await store.makeDir(target)
            path.append(name)
            await load()
        } catch {
            self.error = NASError.describe(error)
        }
    }
}
