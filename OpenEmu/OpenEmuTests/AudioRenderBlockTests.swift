// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import XCTest
import AVFoundation
@testable import OpenEmuKit

final class AudioRenderBlockTests: XCTestCase {
    func testEmptyReadReturnsFullSilentBuffer() {
        let result = render(bytesAvailable: 0)
        XCTAssertEqual(Array(result.data.prefix(32)), Array(repeating: 0, count: 32))
        XCTAssertTrue(result.isSilent)
    }

    func testPartialReadPreservesSamplesAndSilencesMissingTail() {
        let result = render(bytesAvailable: 12)
        XCTAssertEqual(Array(result.data.prefix(12)), Array(repeating: 0x5A, count: 12))
        XCTAssertEqual(Array(result.data[12..<32]), Array(repeating: 0, count: 20))
        XCTAssertFalse(result.isSilent)
    }

    func testCompleteReadPreservesEntireBuffer() {
        let result = render(bytesAvailable: 32)
        XCTAssertEqual(Array(result.data.prefix(32)), Array(repeating: 0x5A, count: 32))
        XCTAssertFalse(result.isSilent)
    }

    func testZeroFrameRequestDoesNotTouchBuffer() {
        let result = render(bytesAvailable: 0, bytesRequested: 0)
        XCTAssertEqual(result.data, Array(repeating: 0xA5, count: 4))
        XCTAssertTrue(result.isSilent)
    }

    func testAudioEngineRendersSilenceDuringUnderflowAndRecovers() throws {
        var hasSamples = false
        let block = GameAudio2.makeRenderBlock(read: { data, requested in
            guard hasSamples else { return 0 }
            let count = Int(requested) / MemoryLayout<Int16>.size
            data?.bindMemory(to: Int16.self, capacity: count).initialize(repeating: 8192, count: count)
            return requested
        }, bytesPerFrame: 4, channelCount: 2)

        let input = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 48000, channels: 2, interleaved: true))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let node = AVAudioSourceNode(format: input, renderBlock: block)
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: input)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
        engine.prepare()
        try engine.start()
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512))
        for _ in 0..<4 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            XCTAssertEqual(buffer.frameLength, 512)
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            XCTAssertTrue((0..<512).allSatisfy { channel[$0] == 0 })
        }

        hasSamples = true
        for _ in 0..<4 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
        }
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        XCTAssertTrue((0..<512).contains { channel[$0] > 0 })

        // A later underflow must clear previously rendered audio, not repeat it.
        hasSamples = false
        for _ in 0..<4 {
            XCTAssertEqual(try engine.renderOffline(512, to: buffer), .success)
            XCTAssertEqual(buffer.frameLength, 512)
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            XCTAssertTrue((0..<512).allSatisfy { channel[$0] == 0 })
        }
    }

    private func render(bytesAvailable: Int, bytesRequested: Int = 32) -> (data: [UInt8], isSilent: Bool) {
        let block = GameAudio2.makeRenderBlock(read: { data, requested in
            let count = min(bytesAvailable, Int(requested))
            if count > 0 {
                data?.initializeMemory(as: UInt8.self, repeating: 0x5A, count: count)
            }
            return UInt(count)
        }, bytesPerFrame: 4, channelCount: 2)

        // Extra bytes expose a write beyond the requested frame count.
        var data = [UInt8](repeating: 0xA5, count: bytesRequested + 4)
        var isSilent = ObjCBool(true)
        var timestamp = AudioTimeStamp()
        data.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1,
                                          mBuffers: AudioBuffer(mNumberChannels: 2,
                                                                mDataByteSize: UInt32(bytesRequested),
                                                                mData: bytes.baseAddress))
            XCTAssertEqual(block(&isSilent, &timestamp, UInt32(bytesRequested / 4), &buffers), noErr)
            XCTAssertEqual(buffers.mBuffers.mDataByteSize, UInt32(bytesRequested))
            XCTAssertEqual(buffers.mBuffers.mNumberChannels, 2)
        }
        XCTAssertEqual(Array(data.suffix(4)), Array(repeating: 0xA5, count: 4))
        return (data, isSilent.boolValue)
    }
}

/// The converter that stands in for the system mixer when a core's rate is below the device's. The system converter
/// is very slow for pairs such as 32768 Hz to 44100 Hz, which crackles and can stop the game from closing.
final class UpsamplingRendererTests: XCTestCase {
    private let coreRate = 32768.0
    private let deviceRate = 44100.0

    func testSineKeepsItsPitch() {
        var phase = 0.0
        let step = 2 * Double.pi * 1000 / coreRate
        let renderer = UpsamplingRenderer(read: { data, requested in
            let frames = Int(requested) / 4
            let samples = data!.bindMemory(to: Int16.self, capacity: frames * 2)
            for i in 0..<frames {
                let v = Int16(sin(phase) * 12000)
                samples[2 * i] = v
                samples[2 * i + 1] = v
                phase += step
            }
            return requested
        }, channelCount: 2, bytesPerSample: 2, inputRate: coreRate, outputRate: deviceRate)

        let left = renderSeconds(1, renderer: renderer).left
        var crossings = 0
        for i in 1..<left.count where left[i - 1] < 0 && left[i] >= 0 { crossings += 1 }
        XCTAssertEqual(crossings, 1000, accuracy: 3)
        XCTAssertLessThan(left.map(abs).max() ?? 0, 0.40, "interpolation must not overshoot the 12000/32768 peak by much")
    }

    func testConstantLevelIsPreserved() {
        let renderer = UpsamplingRenderer(read: { data, requested in
            let count = Int(requested) / 2
            data!.bindMemory(to: Int16.self, capacity: count).initialize(repeating: 8192, count: count)
            return requested
        }, channelCount: 2, bytesPerSample: 2, inputRate: coreRate, outputRate: deviceRate)

        let out = renderSeconds(0.2, renderer: renderer)
        XCTAssertTrue(out.left.suffix(2000).allSatisfy { abs($0 - 0.25) < 0.001 })
        XCTAssertTrue(out.right.suffix(2000).allSatisfy { abs($0 - 0.25) < 0.001 })
        XCTAssertFalse(out.wasSilent)
    }

    func testEmptyReadIsSilent() {
        let renderer = UpsamplingRenderer(read: { _, _ in 0 },
                                          channelCount: 2, bytesPerSample: 2, inputRate: coreRate, outputRate: deviceRate)
        let out = renderSeconds(0.1, renderer: renderer)
        XCTAssertTrue(out.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(out.wasSilent)
    }

    func testShortReadPlaysTheSamplesThenSilence() {
        var delivered = false
        let renderer = UpsamplingRenderer(read: { data, requested in
            guard !delivered else { return 0 }
            delivered = true
            let count = Int(requested) / 2
            data!.bindMemory(to: Int16.self, capacity: count).initialize(repeating: 8192, count: count)
            return requested / 2   // only half of the first chunk
        }, channelCount: 2, bytesPerSample: 2, inputRate: coreRate, outputRate: deviceRate)

        let out = renderSeconds(0.1, renderer: renderer)
        XCTAssertTrue(out.left.contains { $0 > 0.2 })
        XCTAssertTrue(out.left.suffix(1000).allSatisfy { $0 == 0 })
    }

    /// Renders in 512-frame calls, like the audio thread, and returns both channels.
    private func renderSeconds(_ seconds: Double, renderer: UpsamplingRenderer) -> (left: [Float], right: [Float], wasSilent: Bool) {
        let block = renderer.renderBlock
        let calls = Int(seconds * deviceRate / 512)
        var left: [Float] = [], right: [Float] = []
        var lastSilent = true
        for _ in 0..<calls {
            var l = [Float](repeating: 9, count: 512), r = [Float](repeating: 9, count: 512)
            var silent = ObjCBool(false)
            var timestamp = AudioTimeStamp()
            l.withUnsafeMutableBytes { lb in
                r.withUnsafeMutableBytes { rb in
                    let list = AudioBufferList.allocate(maximumBuffers: 2)
                    defer { free(list.unsafeMutablePointer) }
                    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: lb.baseAddress)
                    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: rb.baseAddress)
                    XCTAssertEqual(block(&silent, &timestamp, 512, list.unsafeMutablePointer), noErr)
                }
            }
            lastSilent = silent.boolValue
            left += l
            right += r
        }
        return (left, right, lastSilent)
    }
}
