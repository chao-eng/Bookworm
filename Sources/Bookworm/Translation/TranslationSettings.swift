import Foundation
import Combine
import AppKit
import Security

/// User-visible translation preferences (engine choice, target language,
/// OpenAI API key). Stored in UserDefaults so they apply across reader
/// windows and persist across launches. The OpenAI key lives in the
/// macOS Keychain rather than defaults — it's a credential, not a preference.
@MainActor
final class TranslationSettings: ObservableObject {
    static let shared = TranslationSettings()

    @Published var engine: TranslationEngineKind {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine)
        }
    }
    @Published var sourceLanguage: SupportedLanguage {
        didSet {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: Keys.source)
        }
    }
    @Published var targetLanguage: SupportedLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: Keys.target)
        }
    }
    @Published var openAIModel: String {
        didSet {
            UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel)
        }
    }

    /// Convenience read-only view onto the keychain-backed OpenAI key.
    /// Setting this writes through to the keychain immediately.
    var openAIAPIKey: String? {
        get { Keychain.read(account: Keys.openAIAccount) }
        set {
            if let v = newValue, !v.isEmpty {
                Keychain.write(account: Keys.openAIAccount, value: v)
            } else {
                Keychain.delete(account: Keys.openAIAccount)
            }
            // The @Published `_apiKeyTouch` below pokes SwiftUI to re-read
            // the keychain-backed value on the next render.
            apiKeyTouch += 1
        }
    }

    @Published private(set) var apiKeyTouch: Int = 0

    private enum Keys {
        static let engine        = "Bookworm.translate.engine"
        static let source        = "Bookworm.translate.source"
        static let target        = "Bookworm.translate.target"
        static let openAIModel   = "Bookworm.translate.openAIModel"
        static let openAIAccount = "Bookworm.translate.openAIKey"
    }

    init() {
        let d = UserDefaults.standard
        self.engine = TranslationEngineKind(rawValue: d.string(forKey: Keys.engine) ?? "") ?? .google
        self.sourceLanguage = SupportedLanguage(rawValue: d.string(forKey: Keys.source) ?? "") ?? .auto
        self.targetLanguage = SupportedLanguage(rawValue: d.string(forKey: Keys.target) ?? "") ?? .en
        self.openAIModel = d.string(forKey: Keys.openAIModel) ?? "gpt-4o-mini"
    }
}

/// Tiny generic-secret keychain wrapper for the OpenAI key. UserDefaults
/// would also work but credentials belong in the keychain so they're not
/// readable by any process that can `defaults read` our domain.
enum Keychain {
    private static let service = "app.bookworm.translation"

    static func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Overwrite if present; insert otherwise.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
