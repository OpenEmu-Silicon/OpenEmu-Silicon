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

/// A game in the library grid: box art, title and rating.
final class GameCollectionViewItem: ImageCollectionViewItem {
    
    @IBOutlet weak var ratingIndicator: NSLevelIndicator?
    
    private let indicationLayer = GameCollectionViewItemIndicationLayer()
    
    /// True while a placeholder stands in for missing box art.
    var isShowingMissingArtwork = false
    
    var indication: OEGridViewCellIndicationType {
        get { indicationLayer.type }
        set { indicationLayer.type = newValue }
    }
    
    var rating: Int {
        get { ratingIndicator?.integerValue ?? 0 }
        set { ratingIndicator?.integerValue = newValue }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        indicationLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
        view.layer?.addSublayer(indicationLayer)
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        indication = .none
        ratingIndicator?.integerValue = 0
        isShowingMissingArtwork = false
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        
        guard let imageView else { return }
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setDisableActions(true)
        
        indicationLayer.frame = view.convert(imageView.croppedBounds, from: imageView)
        indicationLayer.zPosition = 1
    }
    
    @IBAction func ratingDidChange(_ sender: NSLevelIndicator) {
        guard let game = representedObject as? OEDBGame else { return }
        game.rating = sender.integerValue as NSNumber
        try? game.managedObjectContext?.save()
    }
}
