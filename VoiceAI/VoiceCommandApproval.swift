import Foundation
import Security

/// The user's approval of the voice program, kept in the Keychain rather than in preferences:
/// another process of this user can rewrite preferences at will, but reading or changing this
/// item asks the user — it belongs to VoiceAI alone. See `VoiceCommand.Approval`.
enum VoiceCommandApproval {
    private static let service = "com.mikagosz.VoiceAI.voiceCommand"
    private static let account = "approved"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> VoiceCommand.Approval? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = fields["path"], let fingerprint = fields["sha256"] else { return nil }
        return VoiceCommand.Approval(path: path, fingerprint: fingerprint)
    }

    /// Approves the file as it is now. False when it cannot be read or the Keychain refuses.
    @discardableResult
    static func approve(_ path: String) -> Bool {
        guard let fingerprint = VoiceCommand.fingerprint(of: path),
              let data = try? JSONSerialization.data(withJSONObject: ["path": path, "sha256": fingerprint]) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "VoiceAI — voice program"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("Voice command approval not saved: \(status, privacy: .public)") }
        return status == errSecSuccess
    }

    static func revoke() {
        SecItemDelete(query as CFDictionary)
    }

    /// What Settings, the menu and the reader go by.
    static func status(in defaults: UserDefaults = .standard) -> VoiceCommand.Status {
        VoiceCommand.status(path: defaults.string(forKey: VoiceCommand.pathKey), approval: load())
    }

    /// The program, only when picked and approved as it is now.
    static var readyPath: String? {
        if case .ready(let path) = status() { return path }
        return nil
    }
}
