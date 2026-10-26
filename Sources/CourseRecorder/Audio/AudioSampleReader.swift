import Foundation
import CoreMedia
import AudioToolbox

/// Reads LPCM audio from a sample buffer as interleaved Float32.
///
/// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` fails for every buffer delivered by
/// AVCaptureAudioDataOutput on macOS 27, so the raw bytes are copied from the data buffer instead,
/// with `CMSampleBufferCopyPCMDataIntoAudioBufferList` as a fallback.
struct AudioSampleReader {
    private var raw: [UInt8] = []
    private(set) var lastError: String?

    struct Result {
        let frames: Int
        let channels: Int
        let sampleRate: Double
    }

    mutating func read(_ sb: CMSampleBuffer, into out: inout [Float]) -> Result? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else {
            lastError = "no format description"
            return nil
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            lastError = "not LPCM (\(asbd.mFormatID))"
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
        guard frames > 0, (isFloat && bytesPerSample == 4) || (!isFloat && (bytesPerSample == 2 || bytesPerSample == 4)) else {
            lastError = "unsupported layout bits=\(asbd.mBitsPerChannel) float=\(isFloat)"
            return nil
        }
        let needed = frames * channels * bytesPerSample
        if raw.count < needed { raw = [UInt8](repeating: 0, count: needed) }

        var ok = false
        var planeStride = frames * bytesPerSample
        if let block = CMSampleBufferGetDataBuffer(sb) {
            let length = CMBlockBufferGetDataLength(block)
            if length >= needed {
                if raw.count < length { raw = [UInt8](repeating: 0, count: length) }
                let status = raw.withUnsafeMutableBytes { p in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: p.baseAddress!)
                }
                if status == noErr {
                    ok = true
                    if planar { planeStride = length / channels }
                } else {
                    lastError = "CMBlockBufferCopyDataBytes \(status)"
                }
            } else {
                lastError = "data buffer too short \(length) < \(needed)"
            }
        }
        if !ok {
            ok = copyViaBufferList(sb, frames: frames, channels: channels, bytesPerSample: bytesPerSample, planar: planar)
            planeStride = frames * bytesPerSample
        }
        guard ok else { return nil }

        let count = frames * channels
        if out.count < count { out = [Float](repeating: 0, count: count) }
        raw.withUnsafeBytes { src in
            out.withUnsafeMutableBufferPointer { dst in
                for f in 0..<frames {
                    for c in 0..<channels {
                        let offset = planar ? c * planeStride + f * bytesPerSample : (f * channels + c) * bytesPerSample
                        let v: Float
                        if isFloat {
                            v = src.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        } else if bytesPerSample == 2 {
                            v = Float(src.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768
                        } else {
                            v = Float(src.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2_147_483_648
                        }
                        dst[f * channels + c] = v
                    }
                }
            }
        }
        lastError = nil
        return Result(frames: frames, channels: channels, sampleRate: asbd.mSampleRate)
    }

    private mutating func copyViaBufferList(_ sb: CMSampleBuffer, frames: Int, channels: Int, bytesPerSample: Int, planar: Bool) -> Bool {
        let buffers = planar ? channels : 1
        let list = AudioBufferList.allocate(maximumBuffers: buffers)
        defer { free(list.unsafeMutablePointer) }
        let status: OSStatus = raw.withUnsafeMutableBytes { p in
            let base = p.baseAddress!
            for i in 0..<buffers {
                let size = planar ? frames * bytesPerSample : frames * channels * bytesPerSample
                list[i] = AudioBuffer(mNumberChannels: planar ? 1 : UInt32(channels), mDataByteSize: UInt32(size),
                                      mData: base.advanced(by: i * frames * bytesPerSample))
            }
            return CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: list.unsafeMutablePointer)
        }
        if status != noErr {
            lastError = (lastError.map { $0 + "; " } ?? "") + "CopyPCMDataIntoAudioBufferList \(status)"
            return false
        }
        return true
    }
}
