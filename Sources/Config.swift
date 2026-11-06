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

import Network

enum NASError {
    /// رسالة واضحة بالعربي لأخطاء الاتصال الشائعة
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let code = ns.code
        if ns.domain == NSPOSIXErrorDomain || ns.domain == "NSPOSIXErrorDomain" || error is POSIXError {
            switch code {
            case 1:  return "الآيفون يمنع الاتصال بالشبكة المحلية. فعّل: الإعدادات ← الخصوصية والأمن ← الشبكة المحلية ← صالحة NAS"
            case 13: return "اسم المستخدم أو كلمة المرور غير صحيحة، أو المستخدم ليس له صلاحية على هذا المجلد."
            case 2:  return "المجلد المشترك غير موجود. اضغط «عرض المجلدات الموجودة» واختر منها."
            case 60: return "الـ FRITZ!Box لم يرد. تأكد أنك متصل بواي فاي البيت."
            case 61: return "الـ FRITZ!Box رفض الاتصال. تأكد أن خدمة FRITZ!NAS ومشاركة الشبكة (SMB) مفعّلة."
            case 51, 65: return "لا يمكن الوصول إلى الـ FRITZ!Box. تأكد أنك متصل بواي فاي البيت وأن العنوان صحيح."
            default: break
            }
        }
        let msg = ns.localizedDescription
        return msg.isEmpty || msg.hasPrefix("Error code") ? "خطأ في الاتصال (رمز \(code))" : msg
    }
}

/// يطلب إذن «الشبكة المحلية» مبكراً حتى لا يفشل أول اتصال
final class LocalNetworkPrompt {
    static let shared = LocalNetworkPrompt()
    private var browser: NWBrowser?

    func trigger() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { _ in }
        b.browseResultsChangedHandler = { _, _ in }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
        }
    }
}
