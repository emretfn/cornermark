import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// How fast the hardware encoder takes frames of one pixel format, with nothing else running.
func encodeBench(format: OSType, frames: Int, w: Int = 2560, h: Int = 1440, codec: CMVideoCodecType = kCMVideoCodecType_H264, extra: [CFString: Any] = [:]) -> String {
    var session: VTCompressionSession?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec,
                                     encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                     imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { return "no session" }
    var props: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: false, kVTCompressionPropertyKey_ProfileLevel: codec == kCMVideoCodecType_H264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel,
                                  kVTCompressionPropertyKey_AverageBitRate: 12_000_000, kVTCompressionPropertyKey_ExpectedFrameRate: 60,
                                  kVTCompressionPropertyKey_MaxKeyFrameInterval: 120, kVTCompressionPropertyKey_AllowFrameReordering: false]
    for (k, v) in extra { props[k] = v }
    VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
    VTCompressionSessionPrepareToEncodeFrames(session)
    var pool: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &pool)
    guard let buffer = pool else { return "no buffer" }
    CVPixelBufferLockBaseAddress(buffer, [])
    if CVPixelBufferIsPlanar(buffer) {
        for p in 0..<CVPixelBufferGetPlaneCount(buffer) { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, p), Int32(100 + p * 20), CVPixelBufferGetBytesPerRowOfPlane(buffer, p) * CVPixelBufferGetHeightOfPlane(buffer, p)) }
    } else { memset(CVPixelBufferGetBaseAddress(buffer), Int32(90), CVPixelBufferGetDataSize(buffer)) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let t0 = DispatchTime.now().uptimeNanoseconds
    for i in 0..<frames {
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60), duration: CMTime(value: 1, timescale: 60), frameProperties: nil, infoFlagsOut: nil) { _, _, _ in }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    VTCompressionSessionInvalidate(session)
    return String(format: "%.2fs for %d frames = %.0f fps", secs, frames, Double(frames) / secs)
}
