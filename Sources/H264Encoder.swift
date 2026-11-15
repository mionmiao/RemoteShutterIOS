import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox 硬件 H.264 编码。输出 AVCC（4 字节大端长度前缀的 NAL）帧，
/// 浏览器 WebCodecs `VideoDecoder` 可直接解码，无需 fMP4 封装。
///
/// 关键取舍：Baseline profile、不重排序（无 B 帧）、2 秒强制关键帧 —— 延迟最低，
/// 且观看端中途接入或丢帧后能在一个 GOP 内恢复。
final class H264Encoder {

    /// C 回调不能捕获上下文，用 box 把 self 带回去；box 由 encoder 强持有，session 只存裸指针。
    fileprivate final class Box {
        weak var encoder: H264Encoder?
    }

    let width: Int
    let height: Int
    private let box: Box
    private var session: VTCompressionSession?
    private var forceKey = true
    private var sentConfig = false
    /// 最近一次 avcC 配置，供后接入的观看端补发。
    private(set) var config: Data?

    /// 编码器输出的 avcC 配置（SPS/PPS），只在第一帧时回调一次。
    var onConfig: ((Data) -> Void)?
    /// (AVCC 帧数据, 是否关键帧, 毫秒时间戳)
    var onFrame: ((Data, Bool, Int64) -> Void)?

    init?(width: Int, height: Int, fps: Int = 8, bitrate: Int = 450_000) {
        guard width >= 16, height >= 16 else { return nil }
        let b = Box()
        self.box = b
        self.width = width
        self.height = height

        let f = Int32(max(1, min(30, fps)))
        let br = Int32(max(100_000, min(8_000_000, bitrate)))
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: false
        ]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: rsH264Output,
            refcon: Unmanaged.passUnretained(b).toOpaque(),
            compressionSessionOut: &s)
        guard status == noErr, let session = s else { return nil }
        self.session = session
        b.encoder = self

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: br))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: f))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: f * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 2))
        // 码率上限（字节/秒），防止复杂场景瞬时冲高塞满上行
        let bytesPerSecond = Int(br / 8) + 16 * 1024
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ms: Int64) {
        guard let session else { return }
        var flags: VTEncodeInfoFlags = []
        let props: CFDictionary? = forceKey
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
            : nil
        forceKey = false
        _ = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: ms, timescale: 1000),
            duration: .invalid,
            frameProperties: props,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags)
    }

    func requestKeyFrame() { forceKey = true }

    func invalidate() {
        if let session {
            _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        box.encoder = nil
    }

    deinit { invalidate() }

    // MARK: - 回调处理

    fileprivate func handle(_ sb: CMSampleBuffer, key: Bool) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        if !sentConfig { publishConfig(fmt) }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        let st = CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                             totalLengthOut: &total, dataPointerOut: &ptr)
        guard st == noErr, let p = ptr, total > 0 else { return }
        let data = Data(bytes: p, count: total)
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let ms = seconds.isFinite ? Int64(seconds * 1000) : Int64(Date().timeIntervalSince1970 * 1000)
        onFrame?(data, key, ms)
    }

    /// 从格式描述里取 SPS/PPS，拼成 avcC（WebCodecs 的 `description`）。
    private func publishConfig(_ fmt: CMFormatDescription) {
        guard let sps = paramSet(fmt, 0), let pps = paramSet(fmt, 1), sps.count >= 4 else { return }
        var c = Data([0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        c.append(UInt8((sps.count >> 8) & 0xff)); c.append(UInt8(sps.count & 0xff))
        c.append(sps)
        c.append(0x01)
        c.append(UInt8((pps.count >> 8) & 0xff)); c.append(UInt8(pps.count & 0xff))
        c.append(pps)
        config = c
        sentConfig = true
        onConfig?(c)
    }

    private func paramSet(_ fmt: CMFormatDescription, _ index: Int) -> Data? {
        var size = 0
        var count = 0
        var nalLen: Int32 = 0
        let st1 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: index, parameterSetPointerOut: nil,
            parameterSetSizeOut: &size, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLen)
        guard st1 == noErr, size > 0 else { return nil }
        var ptr: UnsafePointer<UInt8>?
        let st2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: index, parameterSetPointerOut: &ptr,
            parameterSetSizeOut: &size, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLen)
        guard st2 == noErr, let p = ptr else { return nil }
        return Data(bytes: p, count: size)
    }
}

/// 全局 C 回调：从 refcon 找回 encoder，`frameNotSync` 取反就是关键帧。
private let rsH264Output: VTCompressionOutputCallback = {
    refcon, _, status, flags, sampleBuffer in
    guard status == noErr, let refcon, let sb = sampleBuffer else { return }
    let box = Unmanaged<H264Encoder.Box>.fromOpaque(refcon).takeUnretainedValue()
    box.encoder?.handle(sb, key: !flags.contains(.frameNotSync))
}
