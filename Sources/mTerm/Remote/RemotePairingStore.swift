import Darwin
import Foundation
import Security
import SystemConfiguration

protocol RemoteKeyStorage {
    func load() -> Data?
    @discardableResult
    func save(_ key: Data) -> Bool
}

/// Persists the remote-control pre-shared key in the login Keychain.
struct RemoteKeyStore: RemoteKeyStorage {
    var service = "com.mterm.remote"
    var account = "pairing-key"

    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func save(_ key: Data) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Addresses a client may use to reach this Mac, most stable first: the
/// Bonjour host name, LAN IPv4 addresses, then Tailscale (100.64.0.0/10).
enum RemoteHostAddresses {
    static func current() -> [String] {
        var hosts: [String] = []
        if let localName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            hosts.append("\(localName).local")
        }
        let addresses = interfaceIPv4Addresses()
        hosts += addresses.filter { !isTailscale($0.address) }.map(\.address)
        hosts += addresses.filter { isTailscale($0.address) }.map(\.address)
        return hosts
    }

    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func interfaceIPv4Addresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }
            result.append((String(cString: entry.ifa_name), text))
        }
        return result
    }
}
