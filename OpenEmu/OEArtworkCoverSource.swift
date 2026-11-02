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

/// Library covers from the provider chosen in Preferences → Artwork. "Download Cover Art" asks that provider (and the
/// others after it, when the fallback option is on) for a portrait picture. Nothing is asked until a person asks, and
/// with Automatic or "Library covers only" chosen the library keeps getting its covers from OpenVGDB as before.
enum OEArtworkCoverSource {

    /// The providers to ask for a cover, or nil when the library's own lookup should be used.
    static func providersForCovers() -> [OEBigPictureArtProvider]? {
        guard OEBigPictureArtSource.preferredID != nil else { return nil }
        let chain = OEBigPictureArtSource.providers()
        return chain.isEmpty ? nil : chain
    }

    /// The first picture a provider has for the cover, in order. nil when none has one.
    static func cover(for key: OEBigPictureArt.GameKey, providers: [OEBigPictureArtProvider]) async -> NSImage? {
        for provider in providers {
            if let picture = await provider.art(for: key).grid { return picture }
        }
        return nil
    }
}

extension OEDBGame {

    /// Fetches the cover from the chosen provider. Returns false, having done nothing, when no provider is chosen on
    /// its own. If the provider has no cover, `onMiss` runs so the library's own lookup can take over.
    @MainActor
    func requestCoverFromChosenSource(onMiss: @escaping () -> Void) -> Bool {
        guard let providers = OEArtworkCoverSource.providersForCovers() else { return false }
        let key = OEBigPictureArt.GameKey(self)
        Task { @MainActor [weak self] in
            let picture = await OEArtworkCoverSource.cover(for: key, providers: providers)
            guard let self = self, self.managedObjectContext != nil else { return }
            if let picture = picture {
                self.setBoxImage(image: picture)
                self.status = .ok
                self.save()
                OEBigPictureArt.shared.reset()
            } else {
                onMiss()
            }
        }
        return true
    }
}
