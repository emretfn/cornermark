import AVFoundation
import AppKit

/// A short movie made by the harness, standing in for a video someone already has: a coloured sweep, a moving block and a frame
/// counter, with a quiet tone when `sound` is set. Nothing in it comes from the screen.
enum SyntheticMovie {
    struct Spec {
        var size = CGSize(width: 640, height: 360)
        var fps = 30
        var frames = 60
        var sound = true
        var fileType: AVFileType = .mov
        /// Stored turned a quarter, as a phone's video can be.
        var turned = false
    }

    static func write(to url: URL, _ spec: Spec = Spec()) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        let w = Int(spec.size.width), h = Int(spec.size.height)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        video.expectsMediaDataInRealTime = false
        if spec.turned { video.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(video)
        let rate = 48_000.0
        var audio: AVAssetWriterInput?
        if spec.sound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<spec.frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            draw(frame: i, of: spec, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(spec.fps)))
        }
        video.markAsFinished()

        if let audio {
            let seconds = Double(spec.frames) / Double(spec.fps)
            let total = Int(seconds * rate), chunk = 4800
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            var start = 0
            while start < total, let format {
                while !audio.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                let count = min(chunk, total - start)
                var samples = (0..<count).map { Int16(sin(2 * .pi * 440 * Double(start + $0) / rate) * 3000) }
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil,
                                                   offsetToData: 0, dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard let block else { break }
                samples.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                                                                     presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                                     packetDescriptions: nil, sampleBufferOut: &sample)
                if let sample { audio.append(sample) }
                start += count
            }
            audio.markAsFinished()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func draw(frame i: Int, of spec: Spec, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = spec.size.width, h = spec.size.height
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(w), height: Int(h), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let t = CGFloat(i) / CGFloat(max(spec.frames - 1, 1))
        let colors = [CGColor(srgbRed: 0.10, green: 0.16 + 0.2 * t, blue: 0.34, alpha: 1), CGColor(srgbRed: 0.42, green: 0.20, blue: 0.46 - 0.2 * t, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.80, blue: 0.20, alpha: 1))
        let side = h * 0.22
        ctx.fill(CGRect(x: (w - side) * t, y: h * 0.5 - side / 2, width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: h * 0.07, weight: .semibold), .foregroundColor: NSColor.white]
        ("synthetic clip  frame \(i)" as NSString).draw(at: CGPoint(x: h * 0.06, y: h * 0.08), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
