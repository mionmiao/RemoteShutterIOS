import Foundation
import Combine
import AVFoundation

/// 生命周期总控。主力机分时：
/// - 前台：相机 + HTTP +（可选）中继全开，禁自动锁屏
/// - 后台：主动停相机（系统也会中断），只按开关保留 audio 会话与中继链路
final class ServiceHub: ObservableObject {
    static let shared = ServiceHub()

    @Published var status = "未启动"
    @Published var relayStatus = "未连接"
    @Published var address = ""
    @Published var blackout = false
    /// 默认开启：靠 audio 会话在后台保住中继长连接与声音（相机画面仍会被系统中断）。
    @Published var backgroundAudio = UserDefaults.standard.object(forKey: "rs.backgroundAudio") as? Bool ?? true
    @Published var cameraNote = ""

    // SwiftUI 的 Binding 赋值走 @Published.wrappedValue setter，不会触发属性 didSet。
    // 所有需要副作用的开关都改为显式方法 setMultiCam / setPrimary。
    @Published var multiCam = UserDefaults.standard.bool(forKey: "rs.multiCam")
    @Published var primaryRaw = UserDefaults.standard.string(forKey: "rs.primary") ?? "back"
    @Published var relayEnabled = UserDefaults.standard.bool(forKey: "rs.relayEnabled")
    @Published var relayLink = ""

    /// 最近一次中继错误，供网页 /relay 状态展示。
    var relayLastError: String?
    @Published var bootstrapState = "未配置"

    private var bootstrapVersion = 0
    private var lastBootstrapAt: TimeInterval = 0

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
        audio.keepAlive = backgroundAudio
    }

    func onBackground() {
        camera.suspend()
        // 免费 Apple ID 没有 APNs VoIP 证书，后台只靠 audio 会话保活；默认开启。
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
            self.bootstrap()          // 内部 30s 节流，服务端配置轮换后自动生效
            DispatchQueue.main.async { self.cameraNote = self.camera.note }
        }
        // 启动即向内置固定服务器拉配置，不再需要先连局域网网页填表。
        bootstrap(force: true)
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

    // MARK: - 观看端控制接口（相机端界面已隐藏，全部配置走网页）

    func setBackgroundAudio(_ on: Bool) {
        backgroundAudio = on
        UserDefaults.standard.set(on, forKey: "rs.backgroundAudio")
        audio.keepAlive = on
    }

    func statusSnapshot() -> [String: Any] {
        [
            "ok": true,
            "started": started,
            "address": address,
            "camera": cameraNote,
            "relay": relayStatus,
            "relayOnline": relayStatus == "在线",
            "relayEnabled": relayEnabled,
            "multiCam": multiCam,
            "multiCamSupported": AVCaptureMultiCamSession.isMultiCamSupported,
            "primary": primaryRaw,
            "backgroundAudio": backgroundAudio,
            "bootstrap": bootstrapState,
            "bootstrapEnabled": RSConfig.bootstrap != nil,
            "watchPath": "/watch/\(deviceId)"
        ]
    }

    /// /settings?<key>=<value>；返回最新状态快照供前端直接刷新。
    func applySettings(_ p: [String: String]) -> [String: Any] {
        if let v = p["multiCam"] { setMultiCam(v == "1" || v == "true") }
        if let v = p["primary"], v == "back" || v == "front" { setPrimary(v) }
        if p["restart"] == "1", started { camera.rebuild() }
        return statusSnapshot()
    }

    // MARK: - B 方案：自动 bootstrap（固定服务器 → 下发中继配置 → 自动连）

    /// 启动时、每 30s、以及收到服务端 wake/cfg 帧时调用。
    func bootstrap(force: Bool = false) {
        let now = Date.timeIntervalSinceReferenceDate
        if !force, now - lastBootstrapAt < 30 { return }
        lastBootstrapAt = now
        guard let cfg = RSConfig.bootstrap else {
            bootstrapState = "未启用（用网页手动配置）"
            if relayEnabled { connectRelayIfConfigured(); buildRelayLink() }
            return
        }
        BootstrapClient.fetch(cfg: cfg) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let r):
                    let changed = (r.version != self.bootstrapVersion) ||
                        (r.relayUrl != self.relayURL) || (r.agentKey != self.agentKey)
                    self.bootstrapVersion = r.version
                    self.bootstrapState = "已自动配置 v\(r.version)"
                    if changed || !self.relayEnabled {
                        self.saveRelay(url: r.relayUrl, id: r.deviceId, key: r.agentKey)
                    }
                    self.buildRelayLink()
                case .failure(let e):
                    self.bootstrapState = "自动配置失败：\(e.localizedDescription)"
                    // 降级：沿用上一次保存的配置，不因服务器暂时不可达而中断
                    if self.relayEnabled { self.connectRelayIfConfigured(); self.buildRelayLink() }
                }
            }
        }
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
        c.onControl = { [weak self] _, version in
            DispatchQueue.main.async {
                guard let self else { return }
                // 观看请求 / 配置变更：版本变了立刻重拉，否则走 30s 节流
                self.bootstrap(force: version != self.bootstrapVersion)
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
