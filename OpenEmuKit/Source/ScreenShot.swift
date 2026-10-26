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
import OpenEmuShaders
import CoreImage
import CoreGraphics
import Metal
internal import os

private let captureLog = Logger(subsystem: "org.openemu.OpenEmuKit", category: "capture")

private func describe(_ texture: MTLTexture) -> String {
    let storage: String
    switch texture.storageMode {
    case .shared: storage = "shared"
    case .managed: storage = "managed"
    case .private: storage = "private"
    case .memoryless: storage = "memoryless"
    @unknown default: storage = "unknown"
    }
    var usage: [String] = []
    if texture.usage.contains(.shaderRead) { usage.append("shaderRead") }
    if texture.usage.contains(.shaderWrite) { usage.append("shaderWrite") }
    if texture.usage.contains(.renderTarget) { usage.append("renderTarget") }
    if texture.usage.contains(.pixelFormatView) { usage.append("pixelFormatView") }
    return "\(texture.width)x\(texture.height) pixelFormat=\(texture.pixelFormat.rawValue) storage=\(storage) usage=\(usage.joined(separator: "|"))"
}

public class Screenshot {
    let ss: OpenEmuShaders.Screenshot
    let commandQueue: MTLCommandQueue
    
    public init(device: MTLDevice) {
        ss = .init(device: device)
        commandQueue = device.makeCommandQueue()!
    }
    
    /// Returns a raw image from the GameRenderer.
    ///
    /// The image dimensions are equal to the source pixel
    /// buffer and therefore not aspect corrected.
    func getCGImageFromGameRenderer(_ f: GameRenderer, flippedVertically: Bool) -> CGImage {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return blackImage }
        
        guard let sourceTexture = f.prepareFrameForRender(commandBuffer: commandBuffer) else {
            captureLog.info("capture source: the renderer had no frame to give")
            return blackImage
        }
        captureLog.info("capture source texture: \(describe(sourceTexture), privacy: .public)")
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        guard let img = ss.ciImagefromTexture(tex: sourceTexture, flip: !flippedVertically) else {
            return blackImage
        }
        
        return ss.cgImageFromCIImage(img) ?? blackImage
    }
    
    /// Returns an image of the last source image after all shaders have been applied
    func getCGImageFromOutput(gameRenderer gr: GameRenderer, filterChain f: FilterChain, flippedVertically: Bool) -> CGImage {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return blackImage }
        
        guard let sourceTexture = gr.prepareFrameForRender(commandBuffer: commandBuffer) else {
            captureLog.info("capture output: the renderer had no frame to give")
            return blackImage
        }
        captureLog.info("capture output source texture: \(describe(sourceTexture), privacy: .public)")
        
        return ss.applyFilterChain(f, to: sourceTexture, flip: flippedVertically, commandBuffer: commandBuffer) ?? blackImage
    }
    
    private lazy var blackImage: CGImage = {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx: CGContext = .init(data: nil,
                                   width: 32, height: 32,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 32 * 4,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()!
    }()
}
