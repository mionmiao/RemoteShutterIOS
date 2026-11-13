import Foundation

struct RSRelayConfig {
    let relayUrl: String
    let agentKey: String
    let deviceId: String
    let publicBase: String
    let version: Int
}

/// 启动 / 收到 cfg、wake 帧时，向固定 bootstrap 服务器拉中继配置。
/// 服务端只下发 relayUrl 与设备级 agentKey，不下发 VIEW_KEY。
enum BootstrapClient {
    enum Err: LocalizedError {
        case badURL, badStatus(Int), badPayload
        var errorDescription: String? {
            switch self {
            case .badURL: return "bootstrap 地址无效"
            case .badStatus(let c): return "服务端返回 \(c)"
            case .badPayload: return "配置内容无效"
            }
        }
    }

    static func fetch(cfg: RSBootstrapConfig,
                      completion: @escaping (Result<RSRelayConfig, Error>) -> Void) {
        guard var comps = URLComponents(string: cfg.url + "/_ctl/config") else {
            completion(.failure(Err.badURL)); return
        }
        comps.queryItems = [
            URLQueryItem(name: "device", value: cfg.deviceId),
            URLQueryItem(name: "token", value: cfg.token)
        ]
        guard let u = comps.url else { completion(.failure(Err.badURL)); return }
        var req = URLRequest(url: u, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(err)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let data else { completion(.failure(Err.badStatus(code))); return }
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  j["ok"] as? Bool == true,
                  let relayUrl = j["relayUrl"] as? String,
                  let agentKey = j["agentKey"] as? String,
                  let deviceId = j["deviceId"] as? String else {
                completion(.failure(Err.badPayload)); return
            }
            completion(.success(RSRelayConfig(
                relayUrl: relayUrl, agentKey: agentKey, deviceId: deviceId,
                publicBase: j["publicBase"] as? String ?? "",
                version: (j["version"] as? Int) ?? 0
            )))
        }.resume()
    }
}
