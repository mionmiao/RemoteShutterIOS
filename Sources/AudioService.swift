import AVFoundation
import UIKit
import Foundation

/// 麦克风 PCM(48k/16bit/mono) → /audio WebSocket；同时用静音播放维持 audio 后台会话。
/// 免费 Apple ID 没有 APNs VoIP 证书，这是 iOS 18/26 上唯一可用的后台保活通道。
final class AudioService: ObservableObject {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let lock = NSLock()
    private var pending = Data()
    private var running = false

    /// 后台是否继续保活。主力机分时默认 false：退到后台就释放麦克风（去掉橙点、省电）。
    var keepAlive = false {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let inBackground = UIApplication.shared.applicationState != .active
                if self.keepAlive {
                    if !self.running { self.start() }
                } else if inBackground {
                    self.stop()
                }
            }
        }
    }

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch { return }

        let e = AVAudioEngine()
        let input = e.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 3840, format: inFmt) { [weak self] buf, _ in
            self?.push(buf)
        }

        // 静音循环：让系统在后台认定「正在播放音频」，保住整个进程与网络 socket。
        let p = AVAudioPlayerNode()
        e.attach(p)
        let outFmt = e.outputNode.outputFormat(forBus: 0)
        e.connect(p, to: e.outputNode, format: outFmt)
        if let silence = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 4800) {
            silence.frameLength = 4800
            p.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
        }
        do {
            try e.start()
            p.play()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        engine = e
        player = p
        running = true
    }

    func stop() {
        guard running else { return }
        engine?.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        running = false
        lock.lock(); pending.removeAll(); lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func takePCM() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let d = pending
        pending.removeAll(keepingCapacity: true)
        return d
    }

    private func push(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        let src = ch[0]
        var samples = [Int16]()
        samples.reserveCapacity(n)
        for i in 0..<n {
            let s = max(-1.0, min(1.0, src[i]))
            samples.append(Int16(s * 32767))
        }
        let data = samples.withUnsafeBytes { Data($0) }
        lock.lock()
        pending.append(data)
        if pending.count > 256 * 1024 { pending = Data(pending.suffix(64 * 1024)) }
        lock.unlock()
    }
}
