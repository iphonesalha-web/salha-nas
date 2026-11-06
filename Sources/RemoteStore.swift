import Foundation
import AMSMB2

/// واجهة موحّدة للتخزين البعيد: SMB أو FTP
protocol RemoteStore: AnyObject {
    func makeDir(_ path: String) async
    func size(_ path: String) async -> Int64?
    func upload(_ local: URL, to path: String) async throws
    func remove(_ path: String) async
    func move(_ from: String, to: String) async throws
    func listDirs(_ path: String) async throws -> [String]
    func close() async
}

enum Remote {
    static func open(_ cfg: NASConfig) async throws -> RemoteStore {
        if cfg.useFTP {
            let f = FTPClient(host: cfg.host.trimmingCharacters(in: .whitespaces))
            try await f.login(user: cfg.username, password: cfg.password)
            return FTPStore(f)
        }
        return SMBStore(try await BackupEngine.connect(cfg))
    }
}

final class SMBStore: RemoteStore {
    private let smb: SMB2Manager
    init(_ smb: SMB2Manager) { self.smb = smb }

    func makeDir(_ path: String) async { try? await smb.createDirectory(atPath: path) }

    func size(_ path: String) async -> Int64? {
        guard let a = try? await smb.attributesOfItem(atPath: path) else { return nil }
        if let n = a[.fileSizeKey] as? NSNumber { return n.int64Value }
        if let i = a[.fileSizeKey] as? Int64 { return i }
        if let i = a[.fileSizeKey] as? Int { return Int64(i) }
        return nil
    }

    func upload(_ local: URL, to path: String) async throws {
        try await smb.uploadItem(at: local, toPath: path, progress: { _ in true })
    }

    func remove(_ path: String) async { try? await smb.removeItem(atPath: path) }

    func move(_ from: String, to: String) async throws {
        try await smb.moveItem(atPath: from, toPath: to)
    }

    func listDirs(_ path: String) async throws -> [String] {
        let items = try await smb.contentsOfDirectory(atPath: path.isEmpty ? "/" : path)
        return items.compactMap { e -> String? in
            guard (e[.isDirectoryKey] as? Bool) == true, let n = e[.nameKey] as? String else { return nil }
            return n
        }
    }

    func close() async { try? await smb.disconnectShare(gracefully: true) }
}

final class FTPStore: RemoteStore {
    private let ftp: FTPClient
    init(_ ftp: FTPClient) { self.ftp = ftp }

    private func abs(_ p: String) -> String {
        "/" + p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func makeDir(_ path: String) async { await ftp.makeDir(abs(path)) }
    func size(_ path: String) async -> Int64? { await ftp.size(abs(path)) }
    func upload(_ local: URL, to path: String) async throws { try await ftp.upload(local, to: abs(path)) }
    func remove(_ path: String) async { await ftp.delete(abs(path)) }
    func move(_ from: String, to: String) async throws { try await ftp.rename(abs(from), to: abs(to)) }
    func listDirs(_ path: String) async throws -> [String] { try await ftp.listDirectories(abs(path)) }
    func close() async { await ftp.quit() }
}
