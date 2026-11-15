import Foundation
import Network

/// 复刻 relay/README.md「协议速览」：注册 /_relay/agent，文本帧 reg|regok|open|head|end，
/// 二进制帧 [4B rid 大端][payload]，把请求原样回放到本机 127.0.0.1:8080。
/// 本地 HTTPServer 不输出 chunked，因此这里无需像 Android 端那样做双重分块解码。
final class RelayClient {
    private let onState: (String) -> Void
    /// 服务端推来的控制帧：(wake|cfg, configVersion)
    var onControl: ((String, Int) -> Void)?
    private var rawURL = ""
    private var deviceId = ""
    private var agentKey = ""
    private var localPort: UInt16 = 8080
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var enabled = false
    private let lock = NSLock()
    private var locals: [UInt32: LocalConn] = [:]

    /// 出站二进制帧队列。单条 agent WS 是串行字节流，一个大 JPEG 帧会把后面的音频小帧
    /// 堵住（队头阻塞）。这里串行发送 + 8KB 切片 + 音频优先 + 有界队列，避免延迟无限累积。
    private struct OutFrame {
        let data: Data
        let audio: Bool
    }
    private let outLock = NSLock()
    private var outQueue: [OutFrame] = []
    private var outSending = false
    private var queuedBytes = 0
    private let maxQueuedBytes = 96 * 1024

    init(onState: @escaping (String) -> Void) {
        self.onState = onState
    }

    func connect(url: String, deviceId: String, agentKey: String, localPort: UInt16) {
        teardown()
        rawURL = url; self.deviceId = deviceId; self.agentKey = agentKey; self.localPort = localPort
        enabled = true
        guard var comps = URLComponents(string: url) else { onState("中继地址无效"); return }
        comps.path = "/_relay/agent"
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "id", value: deviceId))
        items.append(URLQueryItem(name: "key", value: agentKey))
        comps.queryItems = items
        guard let u = comps.url else { onState("中继地址无效"); return }

        let s = URLSession(configuration: .default)
        let t = s.webSocketTask(with: u)
        session = s; task = t
        t.resume()
        sendText(["t": "reg", "id": deviceId, "key": agentKey])
        onState("连接中")
        receive()
        DispatchQueue.main.async {
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.task?.sendPing { _ in }
            }
        }
    }

    func stop() {
        enabled = false
        teardown()
        onState("未连接")
    }

    private func teardown() {
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        outLock.lock()
        outQueue.removeAll(); queuedBytes = 0; outSending = false
        outLock.unlock()
        lock.lock(); let all = Array(locals.values); locals.removeAll(); lock.unlock()
        all.forEach { $0.close() }
    }

    // MARK: - frames

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, self.enabled else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let text): self.handleText(text)
                case .data(let d): self.handleBinary(d)
                @unknown default: break
                }
                self.receive()
            case .failure:
                self.reconnect()
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["t"] as? String else { return }
        switch t {
        case "regok": onState("在线")
        case "regfail":
            onState("注册被拒绝（检查 AGENT_KEY / DEVICES）")
            enabled = false
        case "open":
            guard let rid = obj["rid"] as? Int,
                  let b64 = obj["raw"] as? String,
                  let raw = Data(base64Encoded: b64) else { return }
            openLocal(rid: UInt32(rid), raw: raw)
        case "close":
            if let rid = obj["rid"] as? Int { closeLocal(UInt32(rid)) }
        case "wake", "cfg":
            // 观看请求 / 配置变更：通知 ServiceHub 重新拉 bootstrap 配置
            onControl?(t, (obj["version"] as? Int) ?? 0)
        default: break
        }
    }

    private func handleBinary(_ d: Data) {
        guard d.count > 4 else { return }
        let rid = d.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let payload = Data(d.dropFirst(4))
        lock.lock(); let c = locals[rid]; lock.unlock()
        c?.write(payload)
    }

    private func sendText(_ obj: [String: Any]) {
        let s = String(decoding: RSUtil.json(obj), as: UTF8.self)
        task?.send(.string(s)) { _ in }
    }

    /// 上报设备状态，服务端 /watch 离线页与排障用（不对应转发请求）。
    func sendState(camera: String, relay: String) {
        sendText(["t": "state", "camera": camera, "relay": relay])
    }

    /// 入站媒体帧统一入队，而不是直接 task.send —— 后者无背压，帧会在内存里无限排队，
    /// 表现就是「延迟越看越高、音视频一起卡」。
    private func enqueue(rid: UInt32, payload: Data, audio: Bool) {
        guard !payload.isEmpty else { return }
        var f = Data(capacity: 4 + payload.count)
        f.append(UInt8((rid >> 24) & 0xff)); f.append(UInt8((rid >> 16) & 0xff))
        f.append(UInt8((rid >> 8) & 0xff));  f.append(UInt8(rid & 0xff))
        f.append(payload)

        outLock.lock()
        // 视频积压时丢最旧的片，永远保留最新画面；迟到帧没有播放价值。
        if !audio {
            while queuedBytes + f.count > maxQueuedBytes {
                guard let idx = outQueue.firstIndex(where: { !$0.audio }) else { break }
                queuedBytes -= outQueue[idx].data.count
                outQueue.remove(at: idx)
            }
        }
        let frame = OutFrame(data: f, audio: audio)
        // 音频插到第一个视频片之前（音频片之间仍保持 FIFO），避免被大 JPEG 堵住。
        if audio, let idx = outQueue.firstIndex(where: { !$0.audio }) {
            outQueue.insert(frame, at: idx)
        } else {
            outQueue.append(frame)
        }
        queuedBytes += f.count
        let start = !outSending
        if start { outSending = true }
        outLock.unlock()
        if start { pumpOut() }
    }

    /// 一次只提交一帧给 URLSession，等写完再取下一帧 —— 真正的出站背压。
    private func pumpOut() {
        outLock.lock()
        guard enabled, !outQueue.isEmpty else {
            outSending = false
            outLock.unlock()
            return
        }
        let f = outQueue.removeFirst()
        queuedBytes -= f.data.count
        outLock.unlock()
        guard let t = task, enabled else {
            outLock.lock(); outQueue.removeAll(); queuedBytes = 0; outSending = false; outLock.unlock()
            return
        }
        t.send(.data(f.data)) { [weak self] _ in self?.pumpOut() }
    }

    private func openLocal(rid: UInt32, raw: Data) {
        closeLocal(rid)
        let c = LocalConn(rid: rid, port: localPort,
            onHead: { [weak self] head in
                self?.sendText(["t": "head", "rid": Int(rid), "raw": head.base64EncodedString()])
            },
            onData: { [weak self] chunk, isAudio in
                self?.enqueue(rid: rid, payload: chunk, audio: isAudio)
            },
            onEnd: { [weak self] in
                self?.sendText(["t": "end", "rid": Int(rid)])
                self?.closeLocal(rid)
            })
        lock.lock(); locals[rid] = c; lock.unlock()
        c.start(raw: raw)
    }

    private func closeLocal(_ rid: UInt32) {
        lock.lock(); let c = locals.removeValue(forKey: rid); lock.unlock()
        c?.close()
    }

    private func reconnect() {
        guard enabled else { return }
        onState("重连中")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.enabled else { return }
            self.connect(url: self.rawURL, deviceId: self.deviceId,
                         agentKey: self.agentKey, localPort: self.localPort)
        }
    }
}

private final class LocalConn {
    private let conn: NWConnection
    private let onHead: (Data) -> Void
    private let onData: (Data, Bool) -> Void
    private let onEnd: () -> Void
    private var head = Data()
    private var first = true
    private var ended = false
    /// 从原始请求行判断是不是音频流；音频帧小、实时性要求高，要优先出站。
    private(set) var audio = false

    init(rid: UInt32, port: UInt16,
         onHead: @escaping (Data) -> Void,
         onData: @escaping (Data, Bool) -> Void,
         onEnd: @escaping () -> Void) {
        self.onHead = onHead; self.onData = onData; self.onEnd = onEnd
        conn = NWConnection(host: .init("127.0.0.1"),
                            port: NWEndpoint.Port(rawValue: port) ?? 8080,
                            using: .tcp)
        _ = rid
    }

    func start(raw: Data) {
        let cr = raw.firstIndex(of: UInt8(0x0d)) ?? raw.startIndex
        let requestLine = String(decoding: raw[raw.startIndex..<cr], as: UTF8.self)
        // 公网路径形如 /d/phone1/audio?rate=16000，局域网为 /audio?rate=...
        audio = requestLine.contains("/audio")

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.conn.send(content: raw, completion: .contentProcessed { [weak self] _ in self?.read() })
            case .failed, .cancelled:
                self.finish()
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func write(_ d: Data) {
        conn.send(content: d, completion: .contentProcessed { _ in })
    }

    func close() { conn.cancel() }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let d = data {
                if self.first {
                    self.head.append(d)
                    if let r = self.head.range(of: Data("\r\n\r\n".utf8)) {
                        let h = Data(self.head[..<r.upperBound])
                        let rest = Data(self.head[r.upperBound...])
                        self.first = false
                        self.onHead(h)
                        self.emit(rest)
                    }
                } else {
                    self.emit(d)
                }
            }
            if done || err != nil { self.conn.cancel(); self.finish() }
            else { self.read() }
        }
    }

    /// 切片后再入队：8KB 一片，音频帧才有机会插到大 JPEG 中间，把队头阻塞从
    /// 「整帧 50KB」降到「一片 8KB」。中继只是按 rid 顺序 write，切片对字节流透明。
    private func emit(_ d: Data) {
        guard !d.isEmpty else { return }
        let limit = 8 * 1024
        let base = d.startIndex
        var off = 0
        while off < d.count {
            let n = min(limit, d.count - off)
            onData(Data(d[(base + off)..<(base + off + n)]), audio)
            off += n
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd()
    }
}
