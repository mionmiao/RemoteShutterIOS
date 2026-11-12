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

    let camera = CameraService()
    let audio = AudioService()
    lazy var http = HTTPServer(hub: self)
    var relay: RelayClient?

    private(set) var started = false
    private var watchdog: Timer?

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
        connectRelayIfConfigured()
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
        primaryRaw = raw
        UserDefaults.standard.set(raw, forKey: "rs.primary")
        guard started else { return }
        camera.rebuild()
    }

    func connectRelayIfConfigured() {
        guard !relayURL.isEmpty, !agentKey.isEmpty else { return }
        relay?.stop()
        let c = RelayClient { [weak self] state in
            DispatchQueue.main.async { self?.relayStatus = state }
        }
        relay = c
        c.connect(url: relayURL, deviceId: deviceId, agentKey: agentKey, localPort: 8080)
    }

    func saveRelay(url: String, id: String, key: String) {
        relayURL = url; deviceId = id; agentKey = key
        connectRelayIfConfigured()
    }
}
