import Foundation
import Photos
import Network
import AMSMB2

struct BackupResult {
    var uploaded = 0
    var skipped = 0
    var failed = 0
    var message = ""
}

@MainActor
final class BackupEngine: ObservableObject {
    static let shared = BackupEngine()

    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var backedUp = 0
    @Published private(set) var pending = 0
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastMessage = ""

    /// يُستدعى عند كل تقدّم (للمهمة التي تكمل بعد إقفال الشاشة)
    var onProgress: ((Int, Int) -> Void)?

    private var cancelRequested = false
    private var uploadedIDs: Set<String> = []

    private let fm = FileManager.default
    private var supportDir: URL {
        let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var idsFile: URL { supportDir.appendingPathComponent("uploaded.json") }

    private init() {
        if let d = try? Data(contentsOf: idsFile), let ids = try? JSONDecoder().decode([String].self, from: d) {
            uploadedIDs = Set(ids)
        }
        lastRun = UserDefaults.standard.object(forKey: "lastRun") as? Date
        lastMessage = UserDefaults.standard.string(forKey: "lastMessage") ?? ""
        backedUp = uploadedIDs.count
    }

    private func saveIDs() {
        if let d = try? JSONEncoder().encode(Array(uploadedIDs)) {
            try? d.write(to: idsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: - الصور

    static var photosAllowed: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func requestPhotos() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    private func fetchAssets(_ cfg: NASConfig) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if cfg.includeVideos {
            opts.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                         PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        } else {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        let r = PHAsset.fetchAssets(with: opts)
        var out: [PHAsset] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    func refreshCounts() {
        guard Self.photosAllowed else { return }
        let cfg = NASConfig.load()
        let all = fetchAssets(cfg)
        pending = all.filter { !uploadedIDs.contains($0.localIdentifier) }.count
        backedUp = uploadedIDs.count
    }

    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        status = "جاري الإيقاف…"
    }

    // MARK: - الشبكة

    private func onLocalWiFi() async -> Bool {
        await withCheckedContinuation { cont in
            let m = NWPathMonitor()
            m.pathUpdateHandler = { path in
                m.cancel()
                let ok = path.status == .satisfied &&
                    (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
                cont.resume(returning: ok)
            }
            m.start(queue: DispatchQueue(label: "path"))
        }
    }

    static func connect(_ cfg: NASConfig) async throws -> SMB2Manager {
        let host = cfg.host.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "smb://" + host),
              let smb = SMB2Manager(url: url, credential: URLCredential(user: cfg.username, password: cfg.password,
                                                                        persistence: .forSession)) else {
            throw NSError(domain: "NAS", code: 1, userInfo: [NSLocalizedDescriptionKey: "عنوان السيرفر غير صحيح"])
        }
        smb.timeout = 30
        try await smb.connectShare(name: cfg.share)
        return smb
    }

    static func listShares(_ cfg: NASConfig) async throws -> [String] {
        let host = cfg.host.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "smb://" + host),
              let smb = SMB2Manager(url: url, credential: URLCredential(user: cfg.username, password: cfg.password,
                                                                        persistence: .forSession)) else {
            throw NSError(domain: "NAS", code: 1, userInfo: [NSLocalizedDescriptionKey: "عنوان السيرفر غير صحيح"])
        }
        smb.timeout = 20
        return try await smb.listShares().map { $0.name }
    }

    // MARK: - النسخ

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
    private static let yearF: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy"; return f
    }()
    private static let monthF: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM"; return f
    }()

    private func resources(of asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = [.photo, .video, .pairedVideo, .alternatePhoto]
        let picks = all.filter { wanted.contains($0.type) }
        if !picks.isEmpty { return picks }
        return all.filter { $0.type != .adjustmentData }.prefix(1).map { $0 }
    }

    private func export(_ r: PHAssetResource, to url: URL) async throws {
        try? fm.removeItem(at: url)
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = true   // يجلب الأصل من iCloud إذا لزم
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: r, toFile: url, options: o) { err in
                if let e = err { c.resume(throwing: e) } else { c.resume() }
            }
        }
    }

    private func finish(_ r: BackupResult) -> BackupResult {
        saveIDs()
        isRunning = false
        cancelRequested = false
        lastRun = Date()
        lastMessage = r.message
        UserDefaults.standard.set(lastRun, forKey: "lastRun")
        UserDefaults.standard.set(r.message, forKey: "lastMessage")
        status = r.message
        backedUp = uploadedIDs.count
        refreshCounts()
        return r
    }

    @discardableResult
    func run() async -> BackupResult {
        if isRunning { return BackupResult(message: "النسخ يعمل بالفعل") }
        isRunning = true
        cancelRequested = false
        done = 0; total = 0
        var result = BackupResult()
        let cfg = NASConfig.load()

        guard cfg.isComplete else { result.message = "أكمل الإعدادات أولاً"; return finish(result) }
        guard Self.photosAllowed else { result.message = "اسمح للتطبيق بالوصول إلى الصور"; return finish(result) }
        if cfg.wifiOnly, !(await onLocalWiFi()) {
            result.message = "لا يوجد واي فاي، لم يتم النسخ"; return finish(result)
        }

        status = "جاري فحص الصور…"
        let todo = fetchAssets(cfg).filter { !uploadedIDs.contains($0.localIdentifier) }
        total = todo.count
        onProgress?(0, total)
        if todo.isEmpty { result.message = "لا توجد صور جديدة ✓"; return finish(result) }

        status = "جاري الاتصال بالـ NAS…"
        let smb: SMB2Manager
        do { smb = try await Self.connect(cfg) }
        catch { result.message = "تعذّر الاتصال: " + NASError.describe(error); return finish(result) }

        var madeDirs: Set<String> = []
        func ensureDir(_ path: String) async {
            guard !madeDirs.contains(path) else { return }
            var cur = ""
            for part in path.split(separator: "/") {
                cur = cur.isEmpty ? String(part) : cur + "/" + part
                if madeDirs.contains(cur) { continue }
                try? await smb.createDirectory(atPath: cur)
                madeDirs.insert(cur)
            }
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("nas-upload", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        var consecutiveErrors = 0

        for asset in todo {
            if cancelRequested { break }
            let date = asset.creationDate ?? Date()
            var dir = cfg.cleanFolder
            let sub = Self.yearF.string(from: date) + "/" + Self.monthF.string(from: date)
            dir = dir.isEmpty ? sub : dir + "/" + sub
            await ensureDir(dir)

            var assetOK = true
            for res in resources(of: asset) {
                if cancelRequested { assetOK = false; break }
                let name = Self.stamp.string(from: date) + "_" + res.originalFilename
                let remote = dir + "/" + name
                status = name
                let local = tmp.appendingPathComponent(UUID().uuidString + "_" + res.originalFilename)
                do {
                    try await export(res, to: local)
                    let size = ((try? fm.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? -1

                    // موجود مسبقاً بنفس الحجم؟ لا داعي لرفعه مرة ثانية
                    if let attrs = try? await smb.attributesOfItem(atPath: remote),
                       let remoteSize = (attrs[.fileSizeKey] as? NSNumber)?.int64Value, remoteSize == size {
                        result.skipped += 1
                    } else {
                        let part = remote + ".part"
                        try? await smb.removeItem(atPath: part)
                        try await smb.uploadItem(at: local, toPath: part, progress: { _ in true })
                        try? await smb.removeItem(atPath: remote)
                        try await smb.moveItem(atPath: part, toPath: remote)
                        result.uploaded += 1
                    }
                    consecutiveErrors = 0
                } catch {
                    assetOK = false
                    result.failed += 1
                    consecutiveErrors += 1
                    lastMessage = "خطأ في \(name): " + NASError.describe(error)
                }
                try? fm.removeItem(at: local)
                if consecutiveErrors >= 3 { break }
            }

            if assetOK { uploadedIDs.insert(asset.localIdentifier) }
            done += 1
            onProgress?(done, total)
            if done % 10 == 0 { saveIDs() }
            if consecutiveErrors >= 3 { break }
        }

        try? await smb.disconnectShare(gracefully: true)
        try? fm.removeItem(at: tmp)

        if consecutiveErrors >= 3 {
            result.message = "توقف بسبب أخطاء متكررة. \(lastMessage)"
        } else if cancelRequested {
            result.message = "تم الإيقاف — نُسخ \(result.uploaded) ملف"
        } else if result.failed > 0 {
            result.message = "نُسخ \(result.uploaded) ملف، وفشل \(result.failed)"
        } else {
            result.message = "تم ✓ نُسخ \(result.uploaded) ملف"
        }
        return finish(result)
    }
}
