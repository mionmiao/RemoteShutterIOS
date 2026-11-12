import AVFoundation
import UIKit
import CoreImage

/// AVFoundation 相机端。支持 A12+ 的 AVCaptureMultiCamSession 双摄，失败自动降级单摄。
/// 关键约束：iOS 会在 app 进入后台时以 videoDeviceNotAvailableInBackground 中断会话，
/// 回到前台由 interruptionEndedNotification 自动恢复。
final class CameraService: NSObject, ObservableObject,
                           AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCapturePhotoCaptureDelegate {

    enum Pos: String { case back, front }

    @Published private(set) var note = ""

    private let q = DispatchQueue(label: "rs.camera")
    private let ci = CIContext()
    private let lock = NSLock()

    private var session: AVCaptureSession?
    private var inputs: [Pos: AVCaptureDeviceInput] = [:]
    private var outputs: [Pos: AVCaptureVideoDataOutput] = [:]
    private var photoOutput: AVCapturePhotoOutput?
    private var frames: [Pos: Data] = [:]
    private var times: [Pos: TimeInterval] = [:]
    private var lastPhoto: Data?
    private var lastName = ""
    private var photoHandlers: [Int64: (Data?) -> Void] = [:]
    private var wantRunning = false
    private var startedAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    override init() { super.init() }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.publish("相机权限被拒绝"); return }
            self.q.async { self.build() }
        }
    }

    private func resetForRebuild() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        inputs.removeAll()
        outputs.removeAll()
        photoOutput = nil
        lock.lock(); frames.removeAll(); times.removeAll(); lock.unlock()
    }

    /// 默认单摄（标准 AVCaptureSession，最稳）。双摄由 UI 开关开启，走 AVCaptureMultiCamSession。
    /// 注意：AVCaptureMultiCamSession **不支持 sessionPreset**，设置任何值都会抛 NSException。
    private func build(forceSingle: Bool = false) {
        resetForRebuild()
        let wantMulti = !forceSingle && UserDefaults.standard.bool(forKey: "rs.multiCam")
        let useMulti = wantMulti && AVCaptureMultiCamSession.isMultiCamSupported
        let s: AVCaptureSession = useMulti ? AVCaptureMultiCamSession() : AVCaptureSession()
        s.beginConfiguration()
        if !useMulti, s.canSetSessionPreset(.medium) { s.sessionPreset = .medium }

        let list: [Pos] = useMulti ? [.back, .front] : [.back]
        for p in list {
            let position: AVCaptureDevice.Position = (p == .back) ? .back : .front
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else { continue }
            s.addInput(input)
            inputs[p] = input

            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: q)
            guard s.canAddOutput(out) else { continue }
            s.addOutput(out)
            outputs[p] = out
        }
        // multiCam 对 AVCapturePhotoOutput 兼容性差，双摄模式下拍照统一回退预览帧。
        if !useMulti {
            let po = AVCapturePhotoOutput()
            if s.canAddOutput(po) { s.addOutput(po); photoOutput = po }
        }
        s.commitConfiguration()

        // 双路输出任一失败 → 自动降级单摄，避免半残会话。
        if useMulti, outputs[.back] == nil || outputs[.front] == nil {
            publish("双摄不可用，自动降级单摄")
            build(forceSingle: true)
            return
        }

        session = s
        startedAt = Date.timeIntervalSinceReferenceDate
        publish(useMulti ? "双摄会话（实验）" : "单摄会话")

        let c = NotificationCenter.default
        let interrupted = Notification.Name("AVCaptureSessionWasInterruptedNotification")
        let ended = Notification.Name("AVCaptureSessionInterruptionEndedNotification")
        observers.append(c.addObserver(forName: interrupted,
                                       object: s, queue: nil) { [weak self] _ in
            self?.publish("相机被系统中断（后台/被占用）")
        })
        observers.append(c.addObserver(forName: ended,
                                       object: s, queue: nil) { [weak self] _ in
            self?.resume()
        })
        if wantRunning { s.startRunning() }
    }

    func resume() {
        wantRunning = true
        q.async {
            guard let s = self.session, !s.isRunning else { return }
            self.startedAt = Date.timeIntervalSinceReferenceDate
            s.startRunning()
        }
    }

    func suspend() {
        wantRunning = false
        q.async { self.session?.stopRunning() }
    }

    func stop() {
        wantRunning = false
        q.async {
            self.session?.stopRunning()
            self.observers.forEach { NotificationCenter.default.removeObserver($0) }
            self.observers.removeAll()
            self.session = nil
        }
    }

    /// 3.5s 无新帧则重建会话（照搬 Android 端看门狗）。
    func checkFreeze() {
        guard wantRunning, Date.timeIntervalSinceReferenceDate - startedAt > 5 else { return }
        lock.lock()
        let newest = times.values.max() ?? 0
        lock.unlock()
        guard newest > 0, Date.timeIntervalSinceReferenceDate - newest > 3.5 else { return }
        q.async {
            self.session?.stopRunning()
            self.startedAt = Date.timeIntervalSinceReferenceDate
            self.session?.startRunning()
            self.publish("画面冻结，已重开相机")
        }
    }

    func latestFrame(_ p: Pos) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return frames[p]
    }

    func capture(pos: Pos, completion: @escaping (Data?) -> Void) {
        q.async {
            // 双摄 / 无 PhotoOutput 时退回最近一帧预览 JPEG，保证 /capture 永远有图。
            guard let po = self.photoOutput else {
                completion(self.latestFrame(pos))
                return
            }
            guard let conn = po.connections.first(where: { c in
                      c.inputPorts.contains { $0.mediaType == .video }
                  }) else {
                completion(self.latestFrame(pos))
                return
            }
            let settings: AVCapturePhotoSettings
            if po.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            let id = settings.uniqueID
            self.lock.lock(); self.photoHandlers[id] = completion; self.lock.unlock()
            conn.isEnabled = true
            po.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = (error == nil) ? photo.fileDataRepresentation() : nil
        lock.lock()
        let handler = photoHandlers.removeValue(forKey: id)
        if let data { lastPhoto = data; lastName = "rs_\(Int64(Date().timeIntervalSince1970)).jpg" }
        lock.unlock()
        DispatchQueue.main.async { handler?(data) }
    }

    func lastPhotoInfo() -> (name: String, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        return (lastName, lastPhoto)
    }

    func setZoom(_ level: CGFloat, pos: Pos) {
        q.async {
            guard let d = (self.inputs[pos]?.device ?? self.inputs[.back]?.device) else { return }
            do {
                try d.lockForConfiguration()
                d.videoZoomFactor = min(max(1, level), min(d.activeFormat.videoMaxZoomFactor, 8))
                d.unlockForConfiguration()
            } catch { }
        }
    }

    func setExposure(_ ev: Float, pos: Pos) {
        q.async {
            guard let d = (self.inputs[pos]?.device ?? self.inputs[.back]?.device) else { return }
            do {
                try d.lockForConfiguration()
                d.setExposureTargetBias(max(d.minExposureTargetBias, min(d.maxExposureTargetBias, ev)), completionHandler: nil)
                d.unlockForConfiguration()
            } catch { }
        }
    }

    func params(pos: Pos) -> [String: Any] {
        q.sync { () -> [String: Any] in
            guard let d = (inputs[pos]?.device ?? inputs[.back]?.device) else { return [:] }
            return [
                "maxZoom": Double(min(d.activeFormat.videoMaxZoomFactor, 8)),
                "minEv": Double(d.minExposureTargetBias),
                "maxEv": Double(d.maxExposureTargetBias),
                "available": outputs[pos] != nil || outputs[.back] != nil
            ]
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var p: Pos?
        for (key, o) in outputs where o === output { p = key; break }
        guard let pos = p, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(image, from: image.extent) else { return }
        guard let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.55) else { return }
        lock.lock()
        frames[pos] = jpg
        times[pos] = Date.timeIntervalSinceReferenceDate
        lock.unlock()
    }

    private func publish(_ s: String) {
        DispatchQueue.main.async { self.note = s }
    }
}
