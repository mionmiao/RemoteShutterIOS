import Foundation
import Combine

/// 生命周期总控。主力机分时：
/// - 前台：相机 + HTTP +（可选）中继全开，禁自动锁屏
/// - 后台：主动停相机（系统也会中断），只按开关保留 audio 会话与中继链路
final class ServiceHub: ObservableObject {
    static let shared = ServiceHub()

    @Published var status = "未启动"
    @Published var relayStatus = "未连接"
    @Published var address = ""
    @Published var blackout = false
    @Published var backgroundAudio = false
    @Published var cameraNote = ""

    // SwiftUI 的 Binding 赋值走 @Published.wrappedValue setter，不会触发属性 didSet。
    // 所有需要副作用的开关都改为显式方法 setMultiCam / setPrimary。
    @Published var multiCam = UserDefaults.standard.bool(forKey: "rs.multiCam")
    @Published var primaryRaw = UserDefaults.standard.string(forKey: "rs.primary") ?? "back"
    @Published var relayEnabled = UserDefaults.standard.bool(forKey: "rs.relayEnabled")
    @Published var relayLink = ""

    /// 最近一次中继错误，供网页 /relay 状态展示。
    var relayLastError: String?

    let camera = CameraService()
    let audio = AudioService()
    lazy var http = HTTPServer(hub: self)
    var relay: RelayClient?

    private(set) var started = false
    private var watchdog: Timer?
    private var lastPublicFetch: TimeInterval = 0

    private init() {}

    var relayURL: String {
        get { UserDefaults.standard.string(forKey: "rs.relayURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "rs.relayURL") }
    }
    var deviceId: String {
        get { UserDefaults.standard.string(forKey: "rs.deviceId") ?? "phone1" }
        set { UserDefaults.standard.set(newValue, forKey: "rs.deviceId") }
    }
    var agentKey: String {
        get { UserDefaults.standard.string(forKey: "rs.agentKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "rs.agentKey") }
    }
    var viewKey: String {
        get { UserDefaults.standard.string(forKey: "rs.viewKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "rs.viewKey") }
    }

    func onForeground() {
        startIfNeeded()
        camera.resume()
        audio.keepAlive = false
    }

    func onBackground() {
        camera.suspend()
        // 免费 Apple ID 没有 APNs VoIP 证书，voip/PushKit 保活不可用。
        // 后台只靠 audio 会话，且默认关闭，避免主力机常年橙点 + 耗电。
        audio.keepAlive = backgroundAudio
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        camera.start()
        audio.start()
        audio.onPCM = { [weak self] pcm in
            guard let self else { return }
            self.http.broadcastPCM(pcm, sourceRate: self.audio.actualSampleRate)
        }
        do {
            try http.start()
            address = "http://\(NetUtils.localIPv4()):8080"
            status = "运行中（前台）"
        } catch {
            status = "HTTP 启动失败: \(error.localizedDescription)"
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.camera.checkFreeze()
            DispatchQueue.main.async { self.cameraNote = self.camera.note }
        }
        // 用户点过「断开中继」后不应在下次启动又自动连上。
        if relayEnabled { connectRelayIfConfigured(); buildRelayLink() }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        relay?.stop(); relay = nil; relayStatus = "未连接"
        http.stop()
        audio.onPCM = nil
        audio.stop()
        camera.stop()
        started = false
        status = "已停止"
    }

    func toggleService() { started ? stop() : startIfNeeded() }

    func setMultiCam(_ on: Bool) {
        multiCam = on
        UserDefaults.standard.set(on, forKey: "rs.multiCam")
        guard started else { return }
        camera.rebuild()
    }

    func setPrimary(_ raw: String) {
        let changed = (primaryRaw != raw)
        primaryRaw = raw
        UserDefaults.standard.set(raw, forKey: "rs.primary")
        // 前端每次点标签都会发请求；重复值不重建会话，避免来回抢摄像头。
        guard started, changed else { return }
        camera.rebuild()
    }

    // MARK: - 中继（网页 /relay 协议，与 Android 版前端表单对齐）

    func connectRelayIfConfigured() {
        guard !relayURL.isEmpty, !agentKey.isEmpty else { return }
        relay?.stop()
        let c = RelayClient { [weak self] state in
            DispatchQueue.main.async {
                self?.relayStatus = state
                if state == "在线" { self?.relayLastError = nil }
                else if state.contains("注册被拒绝") { self?.relayLastError = state }
            }
        }
        relay = c
        c.connect(url: relayURL, deviceId: deviceId, agentKey: agentKey, localPort: 8080)
    }

    func saveRelay(url: String, id: String, key: String) {
        relayURL = url; deviceId = id; agentKey = key
        relayEnabled = true
        UserDefaults.standard.set(true, forKey: "rs.relayEnabled")
        relayLastError = nil
        connectRelayIfConfigured()
        buildRelayLink()
    }

    func stopRelay() {
        relay?.stop()
        relay = nil
        relayEnabled = false
        UserDefaults.standard.set(false, forKey: "rs.relayEnabled")
        relayStatus = "未连接"
        relayLink = ""
        relayLastError = nil
    }

    /// 观看链接：先给直连地址兜底，再尝试从中继 /_relay/public 取 Cloudflare 临时域名。
    func buildRelayLink() {
        guard let base = relayHTTPBase() else { relayLink = ""; return }
        relayLink = "\(base)/d/\(deviceId)/?k=\(viewKey)"
        tryFetchPublicBase(base)
    }

    /// 前端每 1.5s 轮询 /relay，这里做 20s 节流，避免打爆中继。
    func refreshRelayLink() {
        guard relayEnabled, let base = relayHTTPBase() else { return }
        tryFetchPublicBase(base)
    }

    private func relayHTTPBase() -> String? {
        guard let u = URLComponents(string: relayURL), let host = u.host, !host.isEmpty else { return nil }
        let scheme = (u.scheme?.lowercased() == "wss") ? "https" : "http"
        let port = u.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func tryFetchPublicBase(_ fallback: String) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPublicFetch > 20 else { return }
        lastPublicFetch = now
        guard let url = URL(string: fallback + "/_relay/public") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pub = obj["base"] as? String, !pub.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.relayEnabled else { return }
                self.relayLink = pub + "/d/" + self.deviceId + "/?k=" + self.viewKey
            }
        }.resume()
    }
}
