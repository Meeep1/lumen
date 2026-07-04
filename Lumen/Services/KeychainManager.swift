import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()
    
    private let accessTokenKey = "com.lumen.accessToken"
    private let refreshTokenKey = "com.lumen.refreshToken"
    private let userIdKey = "com.lumen.userId"
    
    private init() {}
    
    // MARK: - Save
    
    func saveAccessToken(_ token: String) {
        save(token, forKey: accessTokenKey)
    }
    
    func saveRefreshToken(_ token: String) {
        save(token, forKey: refreshTokenKey)
    }
    
    func saveUserId(_ userId: String) {
        save(userId, forKey: userIdKey)
    }
    
    // MARK: - Get
    
    func getAccessToken() -> String? {
        return get(forKey: accessTokenKey)
    }
    
    func getRefreshToken() -> String? {
        return get(forKey: refreshTokenKey)
    }
    
    func getUserId() -> String? {
        return get(forKey: userIdKey)
    }
    
    // MARK: - Delete
    
    func deleteAccessToken() {
        delete(forKey: accessTokenKey)
    }
    
    func deleteRefreshToken() {
        delete(forKey: refreshTokenKey)
    }
    
    func deleteUserId() {
        delete(forKey: userIdKey)
    }
    
    func clearAll() {
        deleteAccessToken()
        deleteRefreshToken()
        deleteUserId()
    }
    
    // MARK: - Private Helpers
    
    private func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        // Delete any existing value first
        delete(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            print("Keychain save error: \(status)")
        }
    }
    
    private func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    private func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
