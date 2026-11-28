import Foundation
import Security

/// Keeps the Face signature as one Keychain item on this Mac only: never synced, readable only while
/// the Mac is unlocked, and gone with one call when the Owner turns recognition off.
/// It lives in the login keychain: the data protection keychain needs a team-signed entitlement that an
/// ad-hoc signed build does not have (it fails with errSecMissingEntitlement).
public struct FaceSignatureStore: Sendable {
    static let defaultService = "io.github.esharif20.proximity-mac.face"
    private let service: String
    private let account = "owner"

    public init() {
        self.init(service: Self.defaultService)
    }

    /// Tests use their own service so they never touch a real enrolment.
    init(service: String) {
        self.service = service
    }

    public func load() -> FaceSignature? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(FaceSignature.self, from: data)
    }

    public func save(_ signature: FaceSignature) throws {
        let data = try JSONEncoder().encode(signature)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    public struct StoreError: Error, Equatable {
        public var status: OSStatus
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }
}
