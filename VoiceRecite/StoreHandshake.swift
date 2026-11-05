import Foundation
import Security

/// 版本握手：每个 App 启动时把自己的版本写进共享钥匙串，
/// 应用市场 App 读同一组钥匙串条目 → 就能知道「装了没有、装的是哪个版本」。
///
/// 原理：描述文件里 keychain-access-groups 含 `Q2GXT7348T.*` 通配，
/// 所以同一 Team 签的 App 都能用 `Q2GXT7348T.shared` 这个访问组。
enum StoreHandshake {

    /// 同一个 Team 的共享访问组（换证书时改这里）
    static let accessGroup = "Q2GXT7348T.shared"
    static let service = "appstore.version"

    /// 上报本 App 的版本（App 启动时调用）
    @discardableResult
    static func report(_ bundleId: String? = nil, version: String? = nil) -> Bool {
        let bid = bundleId ?? Bundle.main.bundleIdentifier ?? "unknown"
        let ver = version
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "1.0"
        return report(bundleId: bid, version: ver, group: accessGroup)
    }

    @discardableResult
    static func report(bundleId: String, version: String, group: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bundleId,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(version.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        return st == errSecSuccess
    }

    /// 读取共享组里所有 App 的版本：bundleId -> version
    static func readAll(group: String = accessGroup) -> [String: String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: group,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return [:] }

        var result: [String: String] = [:]
        let items: [[String: Any]]
        if let arr = out as? [[String: Any]] {
            items = arr
        } else if let one = out as? [String: Any] {
            items = [one]
        } else {
            return [:]
        }
        for it in items {
            guard let bid = it[kSecAttrAccount as String] as? String,
                  let data = it[kSecValueData as String] as? Data,
                  let ver = String(data: data, encoding: .utf8) else { continue }
            result[bid] = ver
        }
        return result
    }
}
