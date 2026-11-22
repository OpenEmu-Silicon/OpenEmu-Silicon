// Copyright (c) 2020, OpenEmu Team
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

final class InsetScrollView: NSScrollView {

    private static let showToolbarKey = "OEShowLibraryToolbar"

    private var libraryToolbarIsShown: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.showToolbarKey) == nil || defaults.bool(forKey: Self.showToolbarKey)
    }

    private var originalToolbarInset: CGFloat {
        if #available(macOS 11.0, *) { return 52 }
        return 37
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        applyToolbarContentInset()
        NotificationCenter.default.addObserver(self,
            selector: #selector(libraryToolbarVisibilityDidChange(_:)),
            name: .oeLibraryToolbarVisibilityDidChange,
            object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToolbarContentInset()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func libraryToolbarVisibilityDidChange(_ notification: Notification) {
        // Recompute after AppKit finishes changing the unified toolbar height.
        DispatchQueue.main.async { [weak self] in
            self?.applyToolbarContentInset()
        }
    }

    private func applyToolbarContentInset() {
        // When the Library toolbar is hidden, the artwork grid can extend
        // to the top, while the game's sortable list and the sidebar still
        // require their original titlebar clearance. Save States and
        // Screenshots also need clearance for their section headings, but
        // Retain enough room to put the media headings beneath the titlebar,
        // but reduce the inset by 21 points when the toolbar is hidden. This
        // matches the separator height of the Library/Homebrew titlebar on
        // the current Retina layout (refined from the 16-point reduction).
        // Restore the original inset whenever the toolbar is shown.
        let owner = (documentView as? NSCollectionView)?.dataSource
        let isGameGrid = owner is GameCollectionViewController
        let isMediaGrid = owner is SaveStateViewController || owner is ScreenshotViewController

        let top: CGFloat
        if libraryToolbarIsShown {
            top = originalToolbarInset
        } else if isGameGrid {
            top = 0
        } else if isMediaGrid {
            top = max(0, originalToolbarInset - 21)
        } else {
            top = originalToolbarInset
        }
        if contentInsets.top != top {
            var insets = contentInsets
            insets.top = top
            contentInsets = insets
            needsLayout = true
            contentView.needsLayout = true
        }

        // The game grid intentionally uses zero content inset while the toolbar
        // is hidden. Keep that artwork positioning, but separately inset its
        // vertical scroller so the knob/track cannot reach into the titlebar.
        // Save States and Screenshots already have equivalent titlebar clearance
        // from their content inset. List view, Homebrew and the sidebar retain
        // their existing scroller geometry.
        let scrollerTop: CGFloat = (!libraryToolbarIsShown && isGameGrid)
            ? max(0, originalToolbarInset - 21)
            : 0
        if scrollerInsets.top != scrollerTop {
            var insets = scrollerInsets
            insets.top = scrollerTop
            scrollerInsets = insets
            needsLayout = true
        }
    }
}
