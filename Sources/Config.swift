import Foundation
import Security

struct NASConfig: Codable, Equatable {
    var host = "fritz.box"
    var share = ""
    var username = ""
    var folder = "iPhone"
    var includeVideos = true
    var wifiOnly = true

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !share.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !Keychain.get("nas-password").isEmpty
    }

    private static let key = "nas.config.v1"

    static func load() -> NASConfig {
        guard let d = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(NASConfig.self, from: d) else { return NASConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var password: String {
        get { Keychain.get("nas-password") }
        nonmutating set { Keychain.set(newValue, for: "nas-password") }
    }

    /// المسار داخل المجلد المشترك، بدون / في البداية والنهاية
    var cleanFolder: String {
        folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}

enum Keychain {
    private static let service = "com.salha.nas"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        // متاح والهاتف مقفل (بعد أول فتح منذ التشغيل) حتى يعمل النسخ الليلي
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
