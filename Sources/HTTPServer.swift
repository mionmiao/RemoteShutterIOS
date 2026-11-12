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

        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 12.0)
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
        for c in all {
            // 单摄模式下两路 URL 都指向当前主摄；双摄模式下各走各的物理摄像头。
            if let pos = c.stream, let jpg = hub.camera.latestFrame(pos) { c.sendFrame(jpg) }
        }
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
    fileprivate var stream: CameraService.Pos?
    fileprivate var audio = false
    fileprivate var audioRate: Double = 48_000

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
            if let d = data { self.buf.append(d) }
            if !self.routed, let r = self.buf.range(of: Data("\r\n\r\n".utf8)) {
                self.routed = true
                let head = Data(self.buf[..<r.upperBound])
                self.buf.removeSubrange(..<r.upperBound)
                self.route(head: head)
            }
            if error != nil { self.forceClose(); return }
            if done && self.stream == nil && !self.audio { self.forceClose(); return }
            if self.stream == nil && !self.audio { self.readRequest() }
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
        // 「独立新标签页」按钮走 /cam/back | /cam/front，返回同一个 view.html。
        case ("GET", "/cam/back"), ("GET", "/cam/front"):
            let c = path.hasSuffix("front") ? "front" : "back"
            ServiceHub.shared.setPrimary(c)
            serveStatic("view.html")
        case ("GET", "/cam/mirror"): unsupported()
        case ("GET", "/video"): startMJPEG(.back)
        case ("GET", "/video/front"): startMJPEG(.front)
        case ("GET", "/audio"): startAudioWS(key: headers["sec-websocket-key"] ?? "", query: query)
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

    private func startMJPEG(_ pos: CameraService.Pos) {
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
        var part = Data("--rsframe\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpg.count)\r\n\r\n".utf8)
        part.append(jpg)
        part.append(Data("\r\n".utf8))
        conn.send(content: part, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.forceClose() }
        })
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

    func sendWS(_ payload: Data) {
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
            if err != nil { self?.forceClose() }
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

    private func params(query: String) {
        // 前端 loadParams() 期望 /params 返回可用摄像头数组，用它决定是否隐藏「前置」标签。
        if qs(query, "cam") == nil {
            send(RSUtil.json(["available": ["back", "front"]]), type: "application/json")
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
