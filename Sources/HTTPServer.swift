import Foundation
import Network
import CryptoKit

/// 极简 HTTP/1.1 + MJPEG + WebSocket(/audio) 服务器，复刻 Android 端 CameraServer 的核心路由。
/// 约定：响应一律用 Content-Length 或 Connection: close，绝不输出 chunked —— 中继 RelayClient
/// 直接透传字节，避免 "双重分块"。
final class HTTPServer {
    private weak var hub: ServiceHub?
    private var listener: NWListener?
    private let q = DispatchQueue(label: "rs.http", attributes: .concurrent)
    private let lock = NSLock()
    private var clients: [UUID: Client] = [:]
    private var pump: DispatchSourceTimer?
    let port: UInt16 = 8080

    init(hub: ServiceHub) { self.hub = hub }

    func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NSError(domain: "rs", code: 1) }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: p)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q)

        // 30Hz 调度，但每个客户端按自己的 fps 取帧：中继会给公网 /video 追加 ?fps=8，
        // 局域网直连不带参数仍保持 12fps。定时器频率高于最高帧率，避免量化误差把 8fps 拖成 6fps。
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pump = t
    }

    func stop() {
        pump?.cancel(); pump = nil
        listener?.cancel(); listener = nil
        lock.lock(); let all = Array(clients.values); clients.removeAll(); lock.unlock()
        all.forEach { $0.forceClose() }
    }

    private func accept(_ c: NWConnection) {
        let cl = Client(conn: c, server: self)
        lock.lock(); clients[cl.id] = cl; lock.unlock()
        cl.begin()
    }

    fileprivate func detach(_ id: UUID) {
        lock.lock(); _ = clients.removeValue(forKey: id); lock.unlock()
    }

    private func tick() {
        lock.lock(); let all = Array(clients.values); lock.unlock()
        guard let hub else { return }
        let now = Date.timeIntervalSinceReferenceDate
        for c in all {
            // 每个客户端独立节流：公网 8fps（或 VPS 设的 5fps），局域网 12fps。
            guard let pos = c.stream, c.claimFrameSlot(at: now) else { continue }
            // 单摄模式下两路 URL 都指向当前主摄；双摄模式下各走各的物理摄像头。
            if let jpg = hub.camera.latestFrame(pos) { c.sendFrame(jpg) }
        }
    }

    // MARK: - H.264（WebCodecs 解码）

    private let cfgLock = NSLock()
    private var h264Cfg: Data?

    /// 最新 avcC，供新接入的 /h264 客户端立即初始化解码器。
    var h264Config: Data? {
        cfgLock.lock(); defer { cfgLock.unlock() }
        return h264Cfg
    }

    func broadcastH264Config(_ cfg: Data) {
        cfgLock.lock(); h264Cfg = cfg; cfgLock.unlock()
        lock.lock(); let all = Array(clients.values); lock.unlock()
        for c in all where c.h264 { c.sendH264Config(cfg) }
    }

    func broadcastH264(_ data: Data, key: Bool, pts: Int64) {
        lock.lock(); let all = Array(clients.values); lock.unlock()
        for c in all where c.h264 { c.sendH264Frame(data, key: key, pts: pts) }
    }

    /// 音频帧按采集节奏逐个推给每个 /audio 客户端，并各自重采样到浏览器 AudioContext 的采样率。
    func broadcastPCM(_ pcm: Data, sourceRate: Double) {
        lock.lock(); let all = Array(clients.values); lock.unlock()
        for c in all where c.audio {
            let out = resamplePCM(pcm, from: sourceRate, to: c.audioRate)
            if !out.isEmpty { c.sendWS(out) }
        }
    }

    private func sample(_ d: Data, _ i: Int) -> Int16 {
        let lo = UInt16(d[2 * i])
        let hi = UInt16(d[2 * i + 1])
        return Int16(bitPattern: lo | (hi << 8))
    }

    /// 16bit/mono 线性插值重采样。浏览器 ?rate= 与设备采集率不一致时必须做，
    /// 否则播放消耗速率与下发速率不匹配 → 队列欠载 → 静音填补 → 听起来卡。
    private func resamplePCM(_ src: Data, from: Double, to: Double) -> Data {
        guard from > 0, to > 0, abs(from - to) >= 1 else { return src }
        let n = src.count / 2
        guard n > 1 else { return src }
        let outN = Int(Double(n) * (to / from))
        guard outN > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(outN * 2)
        let step = from / to
        var pos = 0.0
        for _ in 0..<outN {
            let i = Int(pos)
            var v = 0.0
            if i + 1 < n {
                let f = pos - Double(i)
                v = Double(sample(src, i)) * (1 - f) + Double(sample(src, i + 1)) * f
            } else if i < n {
                v = Double(sample(src, i))
            }
            let clamped = Int16(max(-32768.0, min(32767.0, v)))
            let u = UInt16(bitPattern: clamped)
            out.append(UInt8(u & 0xff))
            out.append(UInt8(u >> 8))
            pos += step
        }
        return out
    }
}

private final class Client {
    let id = UUID()
    let conn: NWConnection
    private weak var server: HTTPServer?
    private var buf = Data()
    private var routed = false
    /// 发送背压：上一帧还没写完就跳过下一帧，避免慢网 / 半开连接把 JPEG 排队堆在内存里，
    /// 也避免观看端关页后仍持续编码推帧。
    private let ioLock = NSLock()
    private var frameInFlight = false
    private var wsInFlight = false
    private var lastFrameAt: TimeInterval = 0
    /// 每客户端帧率。局域网默认 12fps；中继 rewriteForPublic 会追加 ?fps=<PUBLIC_FPS>。
    fileprivate var fps: Double = 12
    fileprivate var stream: CameraService.Pos?
    fileprivate var audio = false
    fileprivate var audioRate: Double = 48_000
    /// H.264 不能丢帧（丢参考帧会连续花屏），所以这里用「不丢帧 + 有界队列」：
    /// 客户端慢到积压 30 帧（约 3.7 秒 @8fps）说明链路撑不住，直接断开让它重连。
    fileprivate var h264 = false
    private var h264Queue: [(Data, Bool, Int64)] = []
    private var h264InFlight = false
    private var h264ConfigSent = false

    /// 原子地占用一个发送时隙：未到间隔、或上一帧还没写完就跳过（丢帧保实时，不排队）。
    func claimFrameSlot(at now: TimeInterval) -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }
        guard !frameInFlight, now - lastFrameAt >= 1.0 / fps else { return false }
        lastFrameAt = now
        return true
    }

    init(conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    func begin() {
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state, let self { self.server?.detach(self.id) }
            if case .failed = state { self?.forceClose() }
        }
        conn.start(queue: .global(qos: .userInitiated))
        readRequest()
    }

    private func readRequest() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            // 路由后不再需要任何入向数据，直接丢弃，防止长流客户端把 buf 撑大。
            if !self.routed, let d = data { self.buf.append(d) }
            if !self.routed, let r = self.buf.range(of: Data("\r\n\r\n".utf8)) {
                self.routed = true
                let head = Data(self.buf[..<r.upperBound])
                self.buf.removeAll()
                self.route(head: head)
            }
            if error != nil || done { self.forceClose(); return }
            // MJPEG / audio 也必须持续 receive：对端正常 FIN 时 NWConnection 状态不会变成
            // .failed，只靠 send 报错检测会滞后几帧，导致关页后仍继续推流。
            self.readRequest()
        }
    }

    private func route(head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let full = String(parts[1])
        let pieces = full.split(separator: "?", maxSplits: 1)
        let path = String(pieces.first ?? "/")
        let query = pieces.count > 1 ? String(pieces[1]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { headers[String(kv[0]).lowercased()] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"): serveStatic("index.html")
        case ("GET", "/app.css"): serveStatic("app.css")
        case ("GET", "/app.js"): serveStatic("app.js")
        case ("GET", "/view.html"): serveStatic("view.html")
        // 前端「后置 / 前置」标签：单摄版通过切换物理主摄来实现。
        case ("POST", "/camera"):
            let c = qs(query, "cam") ?? "back"
            if c == "back" || c == "front" { ServiceHub.shared.setPrimary(c) }
            send(RSUtil.json(["ok": true, "cam": c]), type: "application/json")
        // 网页「公网访问」卡片沿用 Android 端 /relay 协议：?action=start|stop / 无参数取状态。
        case ("GET", "/relay"): relay(query: query)
        case ("GET", "/status"):
            send(RSUtil.json(ServiceHub.shared.statusSnapshot()), type: "application/json")
        case ("GET", "/settings"):
            var p: [String: String] = [:]
            for k in ["multiCam", "primary", "backgroundAudio", "restart"] {
                if let v = qs(query, k) { p[k] = v }
            }
            send(RSUtil.json(ServiceHub.shared.applySettings(p)), type: "application/json")
        // 「独立新标签页」按钮走 /cam/back | /cam/front，返回同一个 view.html。
        case ("GET", "/cam/back"), ("GET", "/cam/front"):
            let c = path.hasSuffix("front") ? "front" : "back"
            ServiceHub.shared.setPrimary(c)
            serveStatic("view.html")
        case ("GET", "/cam/mirror"): unsupported()
        case ("GET", "/video"): startMJPEG(.back, query: query)
        case ("GET", "/video/front"): startMJPEG(.front, query: query)
        case ("GET", "/h264.html"): serveStatic("h264.html")
        case ("GET", "/h264"): startH264(query: query)
        case ("GET", "/audio"): startAudioWS(key: headers["sec-websocket-key"] ?? "", query: query)
        case ("GET", "/audio/quality"): startAudioQuality(query: query)
        case ("POST", "/capture"): capture(query: query)
        case ("GET", "/last"): lastPhoto()
        case ("GET", "/params"): params(query: query)
        case ("POST", "/zoom"): zoom(query: query)
        case ("POST", "/exposure"): exposure(query: query)
        default:
            if path.hasPrefix("/photo/") { photo(path: path) } else { unsupported() }
        }
    }

    private func qs(_ query: String, _ key: String) -> String? {
        URLComponents(string: "/?" + query)?.queryItems?.first { $0.name == key }?.value
    }

    private func cam(_ query: String) -> CameraService.Pos {
        CameraService.Pos(rawValue: qs(query, "cam") ?? "back") ?? .back
    }

    // MARK: - routes

    private func serveStatic(_ file: String) {
        let url = Bundle.main.bundleURL.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { unsupported(); return }
        send(data, type: RSUtil.mime(file))
    }

    private func startMJPEG(_ pos: CameraService.Pos, query: String) {
        // 中继 rewriteForPublic 会追加 ?fps=<PUBLIC_FPS>；Android 端支持，iOS 端此前忽略，
        // 导致公网降帧完全失效、12fps 全速推流挤爆上行。这里补齐。
        if let raw = qs(query, "fps"), let v = Double(raw), v >= 1, v <= 30 {
            fps = v
        }
        let h = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: multipart/x-mixed-replace; boundary=rsframe\r\n" +
                "Cache-Control: no-store, no-cache, no-transform\r\n" +
                "X-Accel-Buffering: no\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.forceClose() }
        })
        stream = pos
    }

    func sendFrame(_ jpg: Data) {
        ioLock.lock()
        guard !frameInFlight else { ioLock.unlock(); return }
        frameInFlight = true
        ioLock.unlock()

        var part = Data("--rsframe\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\n\r\n".utf8)
        part.append(jpg)
        part.append(Data("\r\n".utf8))
        conn.send(content: part, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.ioLock.lock(); self.frameInFlight = false; self.ioLock.unlock()
            if err != nil { self.forceClose() }
        })
    }

    /// H.264 原始流：先发 `RSH1 + len + avcC`，之后每帧 `[1B flags][4B pts][4B len][AVCC]`。
    /// 全在 body 里，不依赖自定义响应头，中继透传即可。
    private func startH264(query: String) {
        if let raw = qs(query, "fps"), let v = Double(raw), v >= 1, v <= 30 {
            ServiceHub.shared.camera.setH264FPS(v)
        }
        let h = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/octet-stream\r\n" +
                "Cache-Control: no-store, no-cache, no-transform\r\n" +
                "X-Accel-Buffering: no\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.forceClose() }
        })
        h264 = true
        if let cfg = server?.h264Config { sendH264Config(cfg) }
    }

    /// 前端音质档位按钮会请求这个路径。下发率由随后重建的 /audio?rate= 决定，
    /// 这里只回执，避免 501 噪音；真正的降带宽在 resamplePCM。
    private func startAudioQuality(query: String) {
        send(RSUtil.json(["ok": true, "rate": qs(query, "rate") ?? "48000"]),
             type: "application/json")
    }

    private func startAudioWS(key: String, query: String) {
        let salt = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(salt.utf8))
        var bytes = [UInt8]()
        digest.withUnsafeBytes { bytes.append(contentsOf: $0) }
        let accept = Data(bytes).base64EncodedString()
        let h = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
                "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.forceClose() }
        })
        audio = true
        // 浏览器把 AudioContext 的实际采样率放在 ?rate=，据此重采样。
        if let r = Double(qs(query, "rate") ?? ""), r >= 8_000, r <= 96_000 {
            audioRate = r
        }
    }

    func sendH264Config(_ cfg: Data) {
        ioLock.lock()
        guard h264, !h264ConfigSent else { ioLock.unlock(); return }
        h264ConfigSent = true
        ioLock.unlock()

        var d = Data("RSH1".utf8)
        let n = cfg.count
        d.append(UInt8((n >> 24) & 0xff)); d.append(UInt8((n >> 16) & 0xff))
        d.append(UInt8((n >> 8) & 0xff));  d.append(UInt8(n & 0xff))
        d.append(cfg)
        conn.send(content: d, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.forceClose() }
        })
    }

    func sendH264Frame(_ data: Data, key: Bool, pts: Int64) {
        ioLock.lock()
        guard h264, h264ConfigSent else { ioLock.unlock(); return }
        if h264Queue.count > 30 { ioLock.unlock(); forceClose(); return }
        h264Queue.append((data, key, pts))
        let start = !h264InFlight
        if start { h264InFlight = true }
        ioLock.unlock()
        if start { pumpH264() }
    }

    private func pumpH264() {
        ioLock.lock()
        guard h264, !h264Queue.isEmpty else {
            h264InFlight = false
            ioLock.unlock()
            return
        }
        let f = h264Queue.removeFirst()
        ioLock.unlock()

        var pkt = Data(capacity: 9 + f.0.count)
        pkt.append(f.1 ? 1 : 0)
        pkt.append(UInt8((f.2 >> 24) & 0xff)); pkt.append(UInt8((f.2 >> 16) & 0xff))
        pkt.append(UInt8((f.2 >> 8) & 0xff));  pkt.append(UInt8(f.2 & 0xff))
        let n = f.0.count
        pkt.append(UInt8((n >> 24) & 0xff)); pkt.append(UInt8((n >> 16) & 0xff))
        pkt.append(UInt8((n >> 8) & 0xff));  pkt.append(UInt8(n & 0xff))
        pkt.append(f.0)

        conn.send(content: pkt, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil { self.forceClose(); return }
            self.pumpH264()
        })
    }

    func sendWS(_ payload: Data) {
        ioLock.lock()
        guard !wsInFlight else { ioLock.unlock(); return }
        wsInFlight = true
        ioLock.unlock()

        var f = Data([0x82])
        let n = payload.count
        if n < 126 {
            f.append(UInt8(n))
        } else if n < 65536 {
            f.append(126)
            f.append(UInt8((n >> 8) & 0xff)); f.append(UInt8(n & 0xff))
        } else {
            f.append(127)
            for i in stride(from: 7, through: 0, by: -1) { f.append(UInt8((n >> (i * 8)) & 0xff)) }
        }
        f.append(payload)
        conn.send(content: f, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.ioLock.lock(); self.wsInFlight = false; self.ioLock.unlock()
            if err != nil { self.forceClose() }
        })
    }

    private func capture(query: String) {
        // 高分辨率走 AVCapturePhotoOutput；high=0 时直接回预览帧，省一次拍照。
        if qs(query, "high") != "1", let jpg = ServiceHub.shared.camera.latestFrame(cam(query)) {
            send(jpg, type: "image/jpeg"); return
        }
        ServiceHub.shared.camera.capture(pos: cam(query)) { [weak self] data in
            guard let self else { return }
            guard let data else { self.unsupported(); return }
            self.send(data, type: "image/jpeg")
        }
    }

    private func lastPhoto() {
        let info = ServiceHub.shared.camera.lastPhotoInfo()
        send(RSUtil.json(["name": info.name, "cam": "back"]), type: "application/json")
    }

    private func photo(path: String) {
        let info = ServiceHub.shared.camera.lastPhotoInfo()
        guard let data = info.data, path.contains(info.name) else { unsupported(); return }
        send(data, type: "image/jpeg")
    }

    /// 与 index.html 的 paintRelay() 字段对齐，让网页表单能直接配置 iOS 端中继。
    private func relay(query: String) {
        let hub = ServiceHub.shared
        switch qs(query, "action") ?? "" {
        case "start":
            let url = qs(query, "url") ?? ""
            let id = qs(query, "id") ?? "phone1"
            let key = qs(query, "key") ?? ""
            hub.viewKey = qs(query, "view") ?? ""
            guard !url.isEmpty, !key.isEmpty else {
                send(RSUtil.json(["ok": false, "error": "中继地址与连接密钥不能为空"]),
                     type: "application/json")
                return
            }
            hub.saveRelay(url: url, id: id, key: key)
        case "stop":
            hub.stopRelay()
        default:
            hub.refreshRelayLink()
        }
        let online = (hub.relayStatus == "在线")
        let connecting = (hub.relayStatus == "连接中" || hub.relayStatus == "重连中")
        send(RSUtil.json([
            "ok": true,
            "server": hub.relayURL, "id": hub.deviceId,
            "key": hub.agentKey, "view": hub.viewKey,
            "online": online, "enabled": hub.relayEnabled,
            "state": online ? "online" : (connecting ? "connecting" : "offline"),
            "error": hub.relayLastError ?? "",
            "link": hub.relayLink
        ]), type: "application/json")
    }

    private func params(query: String) {
        // 前端 loadParams() 期望 /params 返回可用摄像头数组，用它决定是否隐藏「前置」标签。
        if qs(query, "cam") == nil {
            let primary = UserDefaults.standard.string(forKey: "rs.primary") ?? "back"
            send(RSUtil.json(["available": ["back", "front"], "primary": primary]),
                 type: "application/json")
            return
        }
        send(RSUtil.json(ServiceHub.shared.camera.params(pos: cam(query))), type: "application/json")
    }

    private func zoom(query: String) {
        if let v = Double(qs(query, "level") ?? "") {
            ServiceHub.shared.camera.setZoom(CGFloat(v), pos: cam(query))
        }
        send(RSUtil.json(["ok": true]), type: "application/json")
    }

    private func exposure(query: String) {
        if let v = Float(qs(query, "ev") ?? "") {
            ServiceHub.shared.camera.setExposure(v, pos: cam(query))
        }
        send(RSUtil.json(["ok": true]), type: "application/json")
    }

    private func unsupported() {
        send(RSUtil.json(["error": "not supported on iOS"]), type: "application/json", status: "501 Not Implemented")
    }

    // MARK: - output

    private func send(_ data: Data, type: String, status: String = "200 OK") {
        let h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n" +
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var body = Data(h.utf8)
        body.append(data)
        conn.send(content: body, completion: .contentProcessed { [weak self] _ in self?.forceClose() })
    }

    func forceClose() {
        server?.detach(id)
        conn.cancel()
    }
}
