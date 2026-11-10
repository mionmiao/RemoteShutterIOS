import Foundation
import Network

/// 复刻 relay/README.md「协议速览」：注册 /_relay/agent，文本帧 reg|regok|open|head|end，
/// 二进制帧 [4B rid 大端][payload]，把请求原样回放到本机 127.0.0.1:8080。
/// 本地 HTTPServer 不输出 chunked，因此这里无需像 Android 端那样做双重分块解码。
final class RelayClient {
    private let onState: (String) -> Void
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

    private func sendBinary(rid: UInt32, payload: Data) {
        var f = Data(capacity: 4 + payload.count)
        f.append(UInt8((rid >> 24) & 0xff)); f.append(UInt8((rid >> 16) & 0xff))
        f.append(UInt8((rid >> 8) & 0xff));  f.append(UInt8(rid & 0xff))
        f.append(payload)
        task?.send(.data(f)) { _ in }
    }

    private func openLocal(rid: UInt32, raw: Data) {
        closeLocal(rid)
        let c = LocalConn(rid: rid, port: localPort,
            onHead: { [weak self] head in
                self?.sendText(["t": "head", "rid": Int(rid), "raw": head.base64EncodedString()])
            },
            onData: { [weak self] chunk in
                self?.sendBinary(rid: rid, payload: chunk)
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
    private let onData: (Data) -> Void
    private let onEnd: () -> Void
    private var head = Data()
    private var first = true
    private var ended = false

    init(rid: UInt32, port: UInt16,
         onHead: @escaping (Data) -> Void,
         onData: @escaping (Data) -> Void,
         onEnd: @escaping () -> Void) {
        self.onHead = onHead; self.onData = onData; self.onEnd = onEnd
        conn = NWConnection(host: .init("127.0.0.1"),
                            port: NWEndpoint.Port(rawValue: port) ?? 8080,
                            using: .tcp)
        _ = rid
    }

    func start(raw: Data) {
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
                        if !rest.isEmpty { self.onData(rest) }
                    }
                } else {
                    self.onData(d)
                }
            }
            if done || err != nil { self.conn.cancel(); self.finish() }
            else { self.read() }
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd()
    }
}
