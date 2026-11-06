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
                    row("المجلد المشترك", config.share.isEmpty ? "—" : config.share)
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
    @State private var shares: [String] = []
    @State private var busy = false
    @State private var testResult = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("الـ FRITZ!Box"),
                        footer: Text("عادةً العنوان fritz.box أو 192.168.178.1. المستخدم وكلمة المرور هما حساب FRITZ!NAS.")) {
                    field("العنوان", $cfg.host)
                    field("اسم المستخدم", $cfg.username)
                    SecureField("كلمة المرور", text: $password)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .environment(\.layoutDirection, .leftToRight)
                }

                Section(header: Text("المجلد المشترك")) {
                    if shares.isEmpty {
                        field("مثال: FRITZ.NAS", $cfg.share)
                    } else {
                        Picker("المجلد المشترك", selection: $cfg.share) {
                            ForEach(shares, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button {
                        Task { await loadShares() }
                    } label: {
                        Label("عرض المجلدات الموجودة", systemImage: "folder.badge.questionmark")
                    }
                    .disabled(busy)
                    field("مجلد الحفظ داخله، مثال: iPhone", $cfg.folder)
                }

                Section(header: Text("الخيارات")) {
                    Toggle("نسخ الفيديوهات أيضاً", isOn: $cfg.includeVideos)
                    Toggle("على الواي فاي فقط", isOn: $cfg.wifiOnly)
                }

                Section(footer: Text(testResult)) {
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

    private func loadShares() async {
        save()
        busy = true
        defer { busy = false }
        do {
            let list = try await BackupEngine.listShares(cfg)
                .filter { !$0.hasSuffix("$") }
            shares = list
            if !list.contains(cfg.share), let first = list.first { cfg.share = first }
            testResult = list.isEmpty ? "لم يتم العثور على مجلدات مشتركة." : "اختر المجلد من القائمة."
        } catch {
            testResult = "تعذّر الاتصال: " + error.localizedDescription
        }
    }

    private func test() async {
        save()
        busy = true
        defer { busy = false }
        do {
            let smb = try await BackupEngine.connect(cfg)
            try? await smb.disconnectShare(gracefully: true)
            testResult = "✓ الاتصال ناجح بالمجلد «\(cfg.share)»"
        } catch {
            testResult = "✗ " + error.localizedDescription
        }
    }
}
