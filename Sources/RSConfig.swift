import Foundation

struct RSBootstrapConfig {
    let url: String
    let token: String
    let deviceId: String
}

/// B 方案：IPA 里只内置一个固定 bootstrap 地址 + 设备令牌，其余中继配置由服务端下发。
/// 优先读 UserDefaults（网页 /settings 可覆盖），否则读 Info.plist（打包前填好即可）。
/// 三项留空 = 不启用自动配置，退回网页手动填中继。
enum RSConfig {
    static var bootstrap: RSBootstrapConfig? {
        let d = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        let url = (d.string(forKey: "rs.bootstrapURL") ?? info["RSBootstrapURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (d.string(forKey: "rs.bootstrapToken") ?? info["RSBootstrapToken"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (d.string(forKey: "rs.deviceId") ?? info["RSDeviceId"] as? String ?? "phone1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !token.isEmpty else { return nil }
        return RSBootstrapConfig(
            url: url.hasSuffix("/") ? String(url.dropLast()) : url,
            token: token,
            deviceId: id.isEmpty ? "phone1" : id
        )
    }
}
