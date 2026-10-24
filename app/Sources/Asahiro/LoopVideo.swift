import AVFoundation
import AppKit
import SwiftUI
import VideoToolbox

// webkit cannot loop webm without a hitch and avfoundation cannot open webm at all, so the vp9 background
// is demuxed here, decoded with videotoolbox's vp9 decoder and re-encoded once to a cached hevc file that
// AVPlayerLooper plays gaplessly
enum LoopTranscoder {
    struct Frame {
        let data: Data
        let pts: Double
    }

    struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0
        var codec = ""
        var width = 0
        var height = 0
    }

    static func cachedLoop(for webm: String) -> URL {
        URL(fileURLWithPath: webm).deletingPathExtension().appendingPathExtension("loop.mov")
    }

    static func transcode(webm: String) async throws -> URL {
        let out = cachedLoop(for: webm)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: webm), options: .mappedIfSafe)
        let (track, frames) = try demux(bytes)
        guard track.codec == "V_VP9", !frames.isEmpty else { throw CoreError(message: "unsupported background codec \(track.codec)") }
        let tmp = out.deletingPathExtension().appendingPathExtension("tmp.mov")
        try? FileManager.default.removeItem(at: tmp)
        try await encode(frames: frames, width: track.width, height: track.height, to: tmp)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    // a flat ebml walk: master elements we care about are stepped into, everything else is skipped by size
    static func demux(_ d: Data) throws -> (Track, [Frame]) {
        let masters: Set<UInt32> = [0x18538067, 0x1549A966, 0x1654AE6B, 0xAE, 0xE0, 0x1F43B675, 0xA0]
        var tracks: [Track] = []
        var frames: [Frame] = []
        var scale: Double = 1_000_000
        var clusterTime: Int64 = 0
        var i = d.startIndex

        func vint(_ keepMarker: Bool) -> (UInt64, Int)? {
            guard i < d.endIndex else { return nil }
            let first = d[i]
            guard first != 0 else { return nil }
            let len = first.leadingZeroBitCount + 1
            guard i + len <= d.endIndex else { return nil }
            var v = UInt64(keepMarker ? first : first & (0xFF >> len))
            for k in 1..<len { v = (v << 8) | UInt64(d[i + k]) }
            return (v, len)
        }

        func uint(_ start: Int, _ size: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<size { v = (v << 8) | UInt64(d[start + k]) }
            return v
        }

        while i < d.endIndex {
            guard let (id, idLen) = vint(true) else { break }
            i += idLen
            guard let (rawSize, sizeLen) = vint(false) else { break }
            i += sizeLen
            let unknown = rawSize == (UInt64(1) << (7 * UInt64(sizeLen))) - 1
            let size = unknown ? 0 : Int(rawSize)
            let id32 = UInt32(truncatingIfNeeded: id)
            if masters.contains(id32) {
                if id32 == 0xAE { tracks.append(Track()) }
                continue
            }
            guard !unknown, i + size <= d.endIndex else { break }
            switch id32 {
            case 0x2AD7B1: scale = Double(uint(i, size))
            case 0xD7: if !tracks.isEmpty { tracks[tracks.count - 1].number = uint(i, size) }
            case 0x83: if !tracks.isEmpty { tracks[tracks.count - 1].type = uint(i, size) }
            case 0x86: if !tracks.isEmpty { tracks[tracks.count - 1].codec = String(decoding: d[i..<(i + size)], as: UTF8.self) }
            case 0xB0: if !tracks.isEmpty { tracks[tracks.count - 1].width = Int(uint(i, size)) }
            case 0xBA: if !tracks.isEmpty { tracks[tracks.count - 1].height = Int(uint(i, size)) }
            case 0xE7: clusterTime = Int64(uint(i, size))
            case 0xA3, 0xA1:
                let blockEnd = i + size
                let save = i
                if let (trackNo, tl) = vint(false) {
                    let head = i + tl
                    let rel = Int16(bitPattern: UInt16(d[head]) << 8 | UInt16(d[head + 1]))
                    let flags = d[head + 2]
                    let video = tracks.first { $0.type == 1 }
                    // video blocks are never laced in practice, skip anything else rather than mis-split it
                    if trackNo == video?.number, flags & 0x06 == 0 {
                        let pts = Double(clusterTime + Int64(rel)) * scale / 1_000_000_000
                        frames.append(Frame(data: d.subdata(in: (head + 3)..<blockEnd), pts: pts))
                    }
                }
                i = save
            default: break
            }
            i += size
        }
        guard let video = tracks.first(where: { $0.type == 1 }) else { throw CoreError(message: "no video track in background") }
        frames.sort { $0.pts < $1.pts }
        return (video, frames)
    }

    // minimal vpcC box (profile 0, 8 bit 4:2:0, bt.709) so videotoolbox accepts the format description
    private static func vpcC() -> Data {
        Data([1, 0, 0, 0, 0, 31, (8 << 4) | (1 << 1), 1, 1, 1, 0, 0])
    }

    private static func encode(frames: [Frame], width: Int, height: Int, to url: URL) async throws {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        var format: CMFormatDescription?
        let ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": vpcC()]]
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_VP9, width: Int32(width),
                                             height: Int32(height), extensions: ext as CFDictionary,
                                             formatDescriptionOut: &format) == noErr, let format
        else { throw CoreError(message: "vp9 format description failed") }

        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session
        else { throw CoreError(message: "vp9 decoder unavailable") }
        defer { VTDecompressionSessionInvalidate(session) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CoreError(message: "writer failed") }
        let start = frames[0].pts
        writer.startSession(atSourceTime: .zero)

        var failure: OSStatus = noErr
        for frame in frames {
            var block: CMBlockBuffer?
            let bytes = frame.data
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                     blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
                  let block else { throw CoreError(message: "block buffer failed") }
            _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
            let pts = CMTime(seconds: frame.pts - start, preferredTimescale: 90_000)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var size = bytes.count
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
            else { throw CoreError(message: "sample buffer failed") }

            var decoded: CVImageBuffer?
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status != noErr { failure = status }
                decoded = image
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if status != noErr || failure != noErr { throw CoreError(message: "vp9 decode failed (\(status), \(failure))") }
            // altref frames inside superframes are hidden and produce no picture
            guard let decoded else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            if !adaptor.append(decoded, withPresentationTime: pts) { throw writer.error ?? CoreError(message: "append failed") }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: frames[frames.count - 1].pts - start + 1.0 / 30, preferredTimescale: 90_000))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CoreError(message: "writer did not complete") }
    }
}

// gapless looping playback of the cached file
struct LoopPlayerView: NSViewRepresentable {
    let url: URL
    let paused: Bool

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var url: URL?
        private let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer = playerLayer
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func load(_ url: URL) {
            guard url != self.url else { return }
            self.url = url
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
            // the first appearance fades in over the still background
            playerLayer.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                self?.playerLayer.opacity = 1
                CATransaction.commit()
            }
        }
    }

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.load(url)
        if paused { view.player.pause() } else { view.player.play() }
    }
}
