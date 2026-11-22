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

// The Controls nib still instantiates this compatibility class. Once the nib
// has finished loading, replace it with a real AppKit NSScroller. A custom
// NSScroller subclass can prevent NSScrollView from using overlay scrollers,
// even if it no longer draws custom thumb/track artwork.
final class ControlsScroller: NSScroller {

    override func awakeFromNib() {
        super.awakeFromNib()

        // Defer until the scroll view has finished attaching the nib's scroller.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let scrollView = self.enclosingScrollView,
                  scrollView.verticalScroller === self else { return }

            // Use the actual system class, not our subclass.
            let nativeScroller = NSScroller(frame: self.frame)
            scrollView.verticalScroller = nativeScroller

            // Let the panel's existing wood/image background show through.
            scrollView.drawsBackground = false
            scrollView.scrollerStyle = .overlay
            scrollView.scrollerKnobStyle = .dark
            scrollView.tile()
        }
    }
}
