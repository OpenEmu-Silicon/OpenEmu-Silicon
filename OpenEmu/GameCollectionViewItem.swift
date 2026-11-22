// Copyright (c) 2026, OpenEmu Team
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

import Cocoa

// Shared with the Library preference pane. Only the grid's star control is
// affected; stored game ratings and the list-view rating column are unchanged.
extension Notification.Name {
    static let oeStarRatingsVisibilityDidChange = Notification.Name("OEStarRatingsVisibilityDidChange")
    static let oeRoundedGameCornersDidChange = Notification.Name("OERoundedGameCornersDidChange")
}

/// What the box art of a game shows on top of itself.
enum GameIndication {
    case none, fileMissing, processing
}

/// A game in the library grid: box art, title and rating.
final class GameCollectionViewItem: ImageCollectionViewItem {

    @IBOutlet weak var ratingIndicator: NSLevelIndicator?

    private let indicationView = IndicationView()

    // The exact 8-bit alpha values of the provided 24x24 upper-right corner PNG.
    // RGB is uniformly white, so only alpha is needed. No image resource or
    // Xcode project/resource changes are required.
    // Original PNG SHA-256: ff630597cfe6d4e3c781fffe072b1a1c83d825c30bf1ac5d441bd1d2bbe157c3
    private static let cornerAlpha = [UInt8](Data(base64Encoded: "+/r38/Ht5t7VwaZ9RgYAAAAAAAAAAAAA/v////7///7///7//96iPgAAAAAAAAAA/v///v7+/v7///7////+7qIlAAAAAAAA/////v/////+/v///v/////NUwAAAAAA/v/+/////v7////+/////v7/3mIAAAAA/////v7+///+/////v///v/+/99TAAAA//7//v7+//7////+//7//v///v/NKAAA//////7//v/+//7//v/+///+////ogAA/////v/+/v7///////7//////v/+7UMA//7//v///////v////7//v/+///+/qIA///////+/v7//v/////+/////v7//9sJ///+///+//7+///+/////////////v8+/v/+///////+///+/v7+///+/v///v96/////////v7///////7//v///////v+m/v////7+//7//v////7//v///v////68//7+/v7//////v/+//7///7////+/v/Q/////v7+/////v///v7+/////v7+///b/v7///7//v7//////v/+/v7+//7////k///+/v/+//7+/////v/////+/v///v/q//7///7////+//7+/v/+/v///v/+///x/////v7///7+/v///////v////7//v7z//7////+/v/////////+/v7//v///v72/v///v///v////7//v7//////v/////6/v////7//v/+/////v7+//7+//7//v/+")!)
    private static let cornerSourceSize = 24
    // Source is 24 display pixels at @2x: a fixed 12-point corner, NOT
    // a fraction of the artwork's size. Scale to display backing pixels only.
    private static let cornerSizeInPoints: CGFloat = 12

    // One small reusable Core Animation nine-slice image is sufficient for
    // every game tile, regardless of artwork dimensions or current zoom.
    // Only the 1x1 center pixel stretches; the exact 24x24 corner pixels do not.
    private static let nineSliceMaskImage: CGImage? = makeNineSliceMaskImage()
    private static let nineSliceCenter = CGRect(x: 24.0 / 49.0,
                                                y: 24.0 / 49.0,
                                                width: 1.0 / 49.0,
                                                height: 1.0 / 49.0)

    private var roundedMaskLayer: CALayer?
    private var roundedCornersEnabled = false

    /// True while a placeholder stands in for missing box art.
    var isShowingMissingArtwork = false

    var indication: GameIndication {
        get { indicationView.indication }
        set { indicationView.indication = newValue }
    }

    var rating: Int {
        get { ratingIndicator?.integerValue ?? 0 }
        set { ratingIndicator?.integerValue = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(indicationView, positioned: .above, relativeTo: imageView)
        updateStarRatingsVisibility()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateStarRatingsVisibility),
                                               name: .oeStarRatingsVisibilityDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateRoundedCornersVisibility),
                                               name: .oeRoundedGameCornersDidChange,
                                               object: nil)
        updateRoundedCornersVisibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(self,
                                                  name: .oeStarRatingsVisibilityDidChange,
                                                  object: nil)
        NotificationCenter.default.removeObserver(self,
                                                  name: .oeRoundedGameCornersDidChange,
                                                  object: nil)
    }

    @objc private func updateStarRatingsVisibility() {
        let defaults = UserDefaults.standard
        let showStars = defaults.object(forKey: "OEShowStarRatings") == nil || defaults.bool(forKey: "OEShowStarRatings")
        ratingIndicator?.isHidden = !showStars
    }

    @objc private func updateRoundedCornersVisibility() {
        roundedCornersEnabled = UserDefaults.standard.bool(forKey: "OERoundedGameCorners")
        if !roundedCornersEnabled {
            imageView?.layer?.mask = nil
            roundedMaskLayer = nil
        }
        applySelectionCornerRadius()
        view.needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        indication = .none
        ratingIndicator?.integerValue = 0
        isShowingMissingArtwork = false
        roundedMaskLayer = nil
        imageView?.layer?.mask = nil
        updateStarRatingsVisibility()
    }

    override func updateHighlightState() {
        super.updateHighlightState()
        applySelectionCornerRadius()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let imageView else { return }
        indicationView.frame = view.convert(imageView.croppedBounds, from: imageView)
        updateImageCornerMask(for: imageView)
        applySelectionCornerRadius()
    }

    private func applySelectionCornerRadius() {
        guard let layer = selectionLayer else { return }
        // CollectionViewItem's selection frame extends 6 points beyond the
        // artwork. Keep its blue 4-point stroke, inset, and dynamic tint.
        let artRect = imageView?.croppedBounds ?? .zero
        let diameter = max(0, min(2 * Self.cornerSizeInPoints,
                                  min(artRect.width, artRect.height)))
        // The original alpha edge crosses 50% about halfway through the
        // 24px source corner, so this follows its visual radius.
        let artRadius = min(Self.cornerSizeInPoints / 2, diameter / 2)
        // Add one point (~2 Retina pixels) to better match the exact
        // antialiased artwork mask, leaving the blue stroke and its inset intact.
        layer.cornerRadius = roundedCornersEnabled ? artRadius + 7 : 3
    }

    // Apple's Core Animation nine-slice support does the resizing on the GPU.
    // Unlike the previous bitmap approach, this allocates NO artwork-sized
    // pixel buffer or CGImage while dragging the grid-size slider.
    private func updateImageCornerMask(for imageView: NSImageView) {
        guard roundedCornersEnabled,
              imageView.image != nil,
              let maskImage = Self.nineSliceMaskImage else {
            if imageView.layer?.mask != nil { imageView.layer?.mask = nil }
            roundedMaskLayer = nil
            return
        }

        let artwork = imageView.croppedBounds.intersection(imageView.bounds)
        guard !artwork.isNull, artwork.width > 0, artwork.height > 0 else {
            if imageView.layer?.mask != nil { imageView.layer?.mask = nil }
            roundedMaskLayer = nil
            return
        }

        imageView.wantsLayer = true
        guard let imageLayer = imageView.layer else { return }
        let scale = max(1, imageView.window?.backingScaleFactor
                              ?? NSScreen.main?.backingScaleFactor ?? 2)

        // Snap the visible picture's edges to the backing-pixel grid. The
        // mask is transparent outside this rectangle, so it also eliminates
        // the 1-pixel vertical/horizontal overdraw from NSImageCell while zooming.
        let viewRect = imageView.bounds
        let widthPx = Int((viewRect.width * scale).rounded())
        let heightPx = Int((viewRect.height * scale).rounded())
        guard widthPx > 0, heightPx > 0 else { return }
        func clampedPixel(_ value: CGFloat, limit: Int) -> Int {
            max(0, min(limit, Int((value * scale).rounded())))
        }
        let x0 = clampedPixel(artwork.minX - viewRect.minX, limit: widthPx)
        let x1 = clampedPixel(artwork.maxX - viewRect.minX, limit: widthPx)
        let y0 = clampedPixel(artwork.minY - viewRect.minY, limit: heightPx)
        let y1 = clampedPixel(artwork.maxY - viewRect.minY, limit: heightPx)
        guard x1 > x0, y1 > y0 else { return }
        let pictureFrame = CGRect(x: viewRect.minX + CGFloat(x0) / scale,
                                  y: viewRect.minY + CGFloat(y0) / scale,
                                  width: CGFloat(x1 - x0) / scale,
                                  height: CGFloat(y1 - y0) / scale)

        let mask: CALayer
        if let existing = roundedMaskLayer {
            mask = existing
        } else {
            mask = CALayer()
            mask.contents = maskImage
            mask.contentsCenter = Self.nineSliceCenter
            mask.contentsGravity = .resize
            // 24 source pixels = 12 display points on any screen. Fix this
            // at @2x even on @1x monitors so the radius never changes.
            mask.contentsScale = 2
            mask.masksToBounds = true
            roundedMaskLayer = mask
        }

        if imageLayer.mask !== mask || mask.frame != pictureFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = pictureFrame
            if imageLayer.mask !== mask { imageLayer.mask = mask }
            CATransaction.commit()
        }
    }

    // Build the 49x49 alpha template ONCE. Each 24x24 corner is copied from
    // the user's exact 8-bit image samples (with mirroring as appropriate).
    // The 1-pixel center row and column are opaque; Core Animation alone
    // stretches those straight sections with contentsCenter nine-slicing.
    private static func makeNineSliceMaskImage() -> CGImage? {
        let corner = cornerSourceSize
        let size = corner * 2 + 1
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        func write(_ x: Int, _ y: Int, _ alpha: UInt8) {
            let offset = (y * size + x) * 4
            // Premultiplied white keeps antialiased edges accurate.
            bytes[offset] = alpha
            bytes[offset + 1] = alpha
            bytes[offset + 2] = alpha
            bytes[offset + 3] = alpha
        }
        for y in 0..<corner {
            for x in 0..<corner {
                write(corner + 1 + x, y,
                      cornerAlpha[y * corner + x])            // top right
                write(x, y,
                      cornerAlpha[y * corner + corner - 1 - x]) // top left
                write(corner + 1 + x, corner + 1 + y,
                      cornerAlpha[(corner - 1 - y) * corner + x]) // bottom right
                write(x, corner + 1 + y,
                      cornerAlpha[(corner - 1 - y) * corner + corner - 1 - x]) // bottom left
            }
        }
        guard let data = CFDataCreate(kCFAllocatorDefault, bytes, bytes.count),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: size,
                       height: size,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    @IBAction func ratingDidChange(_ sender: NSLevelIndicator) {
        guard let game = representedObject as? OEDBGame else { return }
        game.rating = sender.integerValue as NSNumber
        try? game.managedObjectContext?.save()
    }
}

/// Covers the box art of a game whose file is missing (red, with a warning picture) or that is busy (dark, with a spinner).
/// Clicks go through to the item below.
private final class IndicationView: NSView {

    var indication: GameIndication = .none {
        didSet {
            guard indication != oldValue else { return }
            isHidden = indication == .none
            if indication == .processing {
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
            }
            spinner.isHidden = indication != .processing
            needsDisplay = true
        }
    }

    private let spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        return spinner
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        addSubview(spinner)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: (bounds.width - spinner.frame.width) / 2, y: (bounds.height - spinner.frame.height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch indication {
        case .none:
            return
        case .fileMissing:
            NSColor(red: 0.992, green: 0, blue: 0, alpha: 0.4).setFill()
            bounds.fill()
            if let image = NSImage(named: "missing_rom") {
                let width = bounds.width * 0.45
                let height = width * 0.9
                image.draw(in: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height).integral)
            }
        case .processing:
            NSColor(white: 0, alpha: 0.7).setFill()
            bounds.fill()
        }
    }
}
