// Copyright (c) 2022, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
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

import Foundation
import AVFoundation
internal import os
import OpenEmuBase.OEGameCore

@available(macOS 11.0, iOS 14.0, *)
private var log = Logger(subsystem: "org.openemu.OpenEmuKit", category: "GameAudio2")

@available(macOS 11.0, iOS 14.0, *)
final public class GameAudio2: GameAudioProtocol {
    public var volume: Float {
        didSet {
            engine.mainMixerNode.outputVolume = volume
        }
    }
    
    private let engine = AVAudioEngine()
    private var src: AVAudioSourceNode?
    private weak var gameCore: OEGameCore!
    private var isDefaultOutputDevice = true
    private var isRunning = false
    private var currentSampleRate: Double = 0
    /// The device rate the current source node was built for.
    private var outputSampleRate: Double = 0
    /// Bumped whenever audio is paused or stopped, so a restart queued before that point does nothing.
    private var resumeGeneration = 0
    private var configurationChangePending = false
    private var rateListenerDevice: AudioObjectID = 0
    private var rateListener: AudioObjectPropertyListenerBlock?

    public init(withCore gameCore: OEGameCore) {
        self.gameCore = gameCore
        volume = 1.0
    }
    
    deinit {
        stopMonitoringEngineConfiguration()
    }
    
    @objc public func audioSampleRateDidChange() {
        let newRate = gameCore.audioSampleRate(forBuffer: 0)
        log.info("Sample rate changed to \(newRate); engine running: \(self.isRunning)")
        guard isRunning else { return }
        // Some games announce the same rate again (Mario 64 does, about a second after it starts). Rebuilding the
        // engine for that stops the sound for roughly 100 ms while the core keeps writing, so the buffer overflows.
        guard newRate != currentSampleRate else { return }
        
        engine.stop()
        updateSourceNode()
        connectNodes()
        engine.prepare()
        performResumeAudio()
    }
    
    public func startAudio() {
        log.info("startAudio")
        precondition(gameCore.audioBufferCount == 1,
                     "nly one buffer supported; got \(gameCore.audioBufferCount)")
        
        updateSourceNode()
        connectNodes()
        setOutputDeviceID(outputDeviceID)
        if engine.outputNode.outputFormat(forBus: 0).sampleRate != outputSampleRate {
            updateSourceNode()
            connectNodes()
        }
        
        engine.prepare()
        // per the following, we need to wait before resuming to allow devices to start 🤦🏻‍♂️
        //  https://github.com/AudioKit/AudioKit/blob/f2a404ff6cf7492b93759d2cd954c8a5387c8b75/Examples/macOS/OutputSplitter/OutputSplitter/Audio/Output.swift#L88-L95
        performResumeAudio()
        startMonitoringEngineConfiguration()
        startMonitoringDeviceRate()
    }
    
    public func stopAudio() {
        // Forget any restart still waiting on the main queue, and stop listening for device changes, so nothing
        // brings the engine back after the game has been closed.
        resumeGeneration &+= 1
        stopMonitoringEngineConfiguration()
        isRunning = false
        engine.stop()
        destroyNodes()
    }

    public func pauseAudio() {
        resumeGeneration &+= 1
        engine.pause()
        isRunning = false
    }

    private func performResumeAudio() {
        let generation = resumeGeneration
        DispatchQueue.main
            .asyncAfter(deadline: .now() + 0.020) { [weak self] in
                guard let self, generation == self.resumeGeneration else { return }
                self.resumeAudio()
            }
    }
    
    public func resumeAudio() {
        isRunning = true
        do {
            try engine.start()
            log.info("Audio engine started")
        } catch {
            log.error("Unable to start AVAudioEngine: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func readBlockForBuffer(_ buffer: OEAudioBuffer) -> OEAudioBufferReadBlock {
        if buffer.responds(to: #selector(OEAudioBuffer.readBlock)) {
            return buffer.readBlock!()
        }
        return { buf, max -> UInt in
            buffer.read(buf, maxLength: max)
        }
    }
    
    private var streamDescription: AudioStreamBasicDescription {
        let channelCount    = UInt32(gameCore.channelCount(forBuffer: 0))
        let bytesPerSample  = UInt32(gameCore.audioBitDepth / 8)
        
        let formatFlags: AudioFormatFlags = bytesPerSample == 4
            // assume 32-bit float
            ? kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked
            : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian
        
        return AudioStreamBasicDescription(mSampleRate: gameCore.audioSampleRate(forBuffer: 0),
                                           mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: formatFlags,
                                           mBytesPerPacket: bytesPerSample * channelCount,
                                           mFramesPerPacket: 1,
                                           mBytesPerFrame: bytesPerSample * channelCount,
                                           mChannelsPerFrame: channelCount,
                                           mBitsPerChannel: 8 * bytesPerSample,
                                           mReserved: 0)
    }
    
    private var renderFormat: AVAudioFormat {
        var desc = streamDescription
        return AVAudioFormat(streamDescription: &desc)!
        
    }
    
    // MARK: - Helpers
    
    private func updateSourceNode() {
        if let src {
            engine.detach(src)
            self.src = nil
        }
        
        let read = readBlockForBuffer(gameCore.audioBuffer(at: 0))
        let sd   = streamDescription
        currentSampleRate = sd.mSampleRate
        let bytesPerFrame = sd.mBytesPerFrame
        let channelCount  = sd.mChannelsPerFrame
        
        // The system mixer converts a core's rate to the device's rate. For some pairs it does that very slowly: a
        // 32768 Hz core (Game Boy Advance) or a 32728 Hz core (DS) on a 44.1 kHz device makes the audio thread use
        // about ten times the CPU, which crackles and can leave the engine unable to pause when the game closes.
        // When the core is slower than the device, convert here with a cheap interpolator and hand the mixer audio
        // that is already at the device rate.
        let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        outputSampleRate = deviceRate
        if deviceRate > sd.mSampleRate * 1.0001,
           channelCount > 0,
           let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: deviceRate,
                                      channels: AVAudioChannelCount(channelCount),
                                      interleaved: false) {
            let renderer = UpsamplingRenderer(read: read,
                                              channelCount: Int(channelCount),
                                              bytesPerSample: Int(sd.mBytesPerFrame / channelCount),
                                              inputRate: sd.mSampleRate,
                                              outputRate: deviceRate)
            src = AVAudioSourceNode(format: format, renderBlock: renderer.renderBlock)
        } else {
            src = AVAudioSourceNode(format: renderFormat,
                                    renderBlock: Self.makeRenderBlock(read: read,
                                                                     bytesPerFrame: bytesPerFrame,
                                                                     channelCount: channelCount))
        }
        if let src {
            engine.attach(src)
        }
    }
    
    static func makeRenderBlock(read: @escaping OEAudioBufferReadBlock,
                                bytesPerFrame: UInt32,
                                channelCount: UInt32) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, outputData in
            let bytesRequested = UInt(frameCount * bytesPerFrame)
            let data = outputData.pointee.mBuffers.mData
            let bytesCopied = read(data, bytesRequested)

            // The audio engine requires a full buffer even when the core runs short.
            // Preserve available samples and silence only the missing tail.
            if bytesCopied < bytesRequested, let data {
                memset(data.advanced(by: Int(bytesCopied)), 0, Int(bytesRequested - bytesCopied))
            }

            outputData.pointee.mBuffers.mDataByteSize = UInt32(bytesRequested)
            outputData.pointee.mBuffers.mNumberChannels = channelCount
            isSilence.pointee = ObjCBool(bytesCopied == 0)
            return noErr
        }
    }

    private func destroyNodes() {
        if let src {
            engine.detach(src)
        }
        src = nil
    }
    
    private func connectNodes() {
        guard let src else { fatalError("Expected src node") }
        engine.connect(src, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
    }
    
    private var token: NSObjectProtocol?
    
    private func startMonitoringEngineConfiguration() {
        token = NotificationCenter.default
            .addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                
                self.handleConfigurationChange()
            }
    }

    /// The output device changed (a different device, or the same one at a new sample rate). The engine has already
    /// stopped itself. Reconnect the nodes to the new output format and start again. Do not set the output device here:
    /// setting it, even to the device already in use, makes CoreAudio send another change notification, and the
    /// notifications feed each other until the audio thread is spinning and closing the game hangs.
    private func handleConfigurationChange() {
        log.debug("AVAudioEngine configuration change; running: \(self.isRunning)")
        guard isRunning, src != nil else { return }
        // Several notifications usually arrive together for one change; restart once.
        guard !configurationChangePending else { return }
        configurationChangePending = true

        let generation = resumeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.100) { [weak self] in
            guard let self else { return }
            self.configurationChangePending = false
            guard generation == self.resumeGeneration, self.isRunning, self.src != nil else { return }
                self.engine.stop()
            self.updateSourceNode()
            self.connectNodes()
            self.engine.prepare()
            self.performResumeAudio()
            self.startMonitoringDeviceRate()
        }
    }
    
    /// AVAudioEngine announces a device change only some of the time: after one change it can keep playing at the old
    /// rate through a later one, and the audio thread then spins and pausing the engine never returns. Listen to the
    /// device ourselves so every rate change restarts the engine.
    private func startMonitoringDeviceRate() {
        stopMonitoringDeviceRate()
        let device = engine.outputNode.auAudioUnit.deviceID
        guard device != 0 else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleConfigurationChange()
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
            rateListener = block
            rateListenerDevice = device
        }
    }
    
    private func stopMonitoringDeviceRate() {
        guard let block = rateListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, DispatchQueue.main, block)
        rateListener = nil
        rateListenerDevice = 0
    }
    
    private func stopMonitoringEngineConfiguration() {
        stopMonitoringDeviceRate()
        if let token = token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
    
    private var defaultAudioOutputDeviceID: AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }
    
    func setOutputDeviceID(_ newOutputDeviceID: AudioDeviceID) {
        let id: AudioDeviceID
        if newOutputDeviceID == 0 {
            id = defaultAudioOutputDeviceID
            isDefaultOutputDevice = true
            log.debug("Using default audio device \(id)")
        } else {
            id = newOutputDeviceID
            isDefaultOutputDevice = false
        }
        
        engine.stop()
        
        // Setting the device it already has still makes CoreAudio announce a configuration change.
        if engine.outputNode.auAudioUnit.deviceID != id {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(id)
            } catch {
                log.error("Unable to set output device ID \(id): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        connectNodes()
        
        if isRunning && !engine.isRunning {
            engine.prepare()
            performResumeAudio()
        }
    }
    
    var outputDeviceID: AudioDeviceID {
        isDefaultOutputDevice ? 0 : engine.outputNode.auAudioUnit.deviceID
    }
}


/// Converts a core's audio to a higher device rate inside the render callback, using Catmull-Rom interpolation.
/// It allocates everything up front and takes no locks of its own, so it is safe on the audio thread.
final class UpsamplingRenderer {
    private let read: OEAudioBufferReadBlock
    private let channelCount: Int
    private let bytesPerSample: Int
    private let step: Double            // input frames consumed per output frame; below 1 when upsampling
    private let chunkFrames = 64
    private let raw: UnsafeMutableRawPointer
    private let stage: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>   // four frames, oldest first
    private var stageIndex: Int
    private var stageCount = 0
    private var position = 4.0          // fractional position; starts high so the first frames fill the history
    private var gotRealFrames = false
    
    init(read: @escaping OEAudioBufferReadBlock, channelCount: Int, bytesPerSample: Int, inputRate: Double, outputRate: Double) {
        self.read = read
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
        self.step = inputRate / outputRate
        raw = .allocate(byteCount: chunkFrames * channelCount * bytesPerSample, alignment: 16)
        stage = .allocate(capacity: chunkFrames * channelCount)
        history = .allocate(capacity: 4 * channelCount)
        history.initialize(repeating: 0, count: 4 * channelCount)
        stageIndex = chunkFrames
    }
    
    deinit {
        raw.deallocate()
        stage.deallocate()
        history.deallocate()
    }
    
    var renderBlock: AVAudioSourceNodeRenderBlock {
        { [self] isSilence, _, frameCount, outputData in
            gotRealFrames = false
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            let channels = channelCount
            let h = history
            
            for i in 0..<frames {
                while position >= 1 {
                    position -= 1
                    pushInputFrame()
                }
                let t = Float(position)
                for c in 0..<min(channels, buffers.count) {
                    let p0 = h[c], p1 = h[channels + c], p2 = h[2 * channels + c], p3 = h[3 * channels + c]
                    let a = -p0 + 3 * p1 - 3 * p2 + p3
                    let b = 2 * p0 - 5 * p1 + 4 * p2 - p3
                    let k = p2 - p0
                    let value = p1 + 0.5 * t * (k + t * (b + t * a))
                    buffers[c].mData?.assumingMemoryBound(to: Float.self)[i] = value
                }
                position += step
            }
            for c in 0..<buffers.count {
                buffers[c].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
            isSilence.pointee = ObjCBool(!gotRealFrames)
            return noErr
        }
    }
    
    /// Slides the history window by one input frame, reading a new chunk from the core when the last one runs out.
    private func pushInputFrame() {
        if stageIndex >= stageCount {
            refill()
        }
        let channels = channelCount
        let h = history
        for f in 0..<3 {
            for c in 0..<channels {
                h[f * channels + c] = h[(f + 1) * channels + c]
            }
        }
        let base = stageIndex * channels
        for c in 0..<channels {
            h[3 * channels + c] = stage[base + c]
        }
        stageIndex += 1
    }
    
    private func refill() {
        let bytesPerFrame = channelCount * bytesPerSample
        let wanted = chunkFrames * bytesPerFrame
        let copied = Int(read(raw, UInt(wanted)))
        let frames = copied / bytesPerFrame
        if frames > 0 { gotRealFrames = true }
        
        let total = chunkFrames * channelCount
        let have = frames * channelCount
        if bytesPerSample == 2 {
            let src = raw.assumingMemoryBound(to: Int16.self)
            for i in 0..<have { stage[i] = Float(src[i]) * (1.0 / 32768.0) }
        } else {
            let src = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<have { stage[i] = src[i] }
        }
        // A short read (the core fell behind) plays out as silence, as the direct path does.
        if have < total {
            (stage + have).update(repeating: 0, count: total - have)
        }
        stageCount = chunkFrames
        stageIndex = 0
    }
}
