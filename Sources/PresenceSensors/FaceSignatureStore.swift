import Foundation
import Security

/// Keeps the Face signature as one item in the login keychain: never synced to iCloud, readable by other
/// apps only through a user prompt, and gone with one call when the Owner deletes it.
///
/// The login keychain ignores `kSecAttrAccessible`, so "this device only" and "only while unlocked" are
/// not enforced: a Time Machine restore or Migration Assistant can carry the item to another Mac, and it
/// reads fine while the screen is locked. Only the data protection keychain enforces those, and it needs a
/// team-signed entitlement that ad-hoc builds lack (errSecMissingEntitlement). See ADR 0004.
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
        let attributes: [CFString: Any] = [kSecValueData: data]
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
