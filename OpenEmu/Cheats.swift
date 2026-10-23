/*
 Copyright (c) 2017, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation

final class Cheat: Codable {
    let code: String
    let type: String
    var name: String
    var isEnabled = false
    var cheatSource: String?
    /// Unmodified text as published by the provider, before normalization. Not shown to the user;
    /// carried through for future cheat feedback correlation. `nil` for manual/Cheat Search entries.
    var rawCode: String?
    /// Set at runtime; not persisted. False when the current core can't handle this code format.
    var isCompatibleWithCore = true
    /// Core that created this cheat. Only persisted for cores whose cheats are per-core
    /// (OEGameCoreCheatsArePerCore); nil for shared-cheat systems and legacy entries.
    /// Forward/backward compatible via decodeIfPresent/encodeIfPresent. The only edge is a
    /// *downgrade*: a pre-FBNeo build reads these entries fine but, lacking the per-core filter,
    /// shows FBNeo cheats under MAME. Accepted — old shipped code can't be changed; updating fixes it.
    var coreIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case code, type, name, isEnabled, cheatSource, rawCode, coreIdentifier
    }

    init(code: String, type: String, name: String, cheatSource: String? = nil, rawCode: String? = nil, coreIdentifier: String? = nil) {
        self.code = code
        self.type = type
        self.name = name
        self.cheatSource = cheatSource
        self.rawCode = rawCode
        self.coreIdentifier = coreIdentifier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        cheatSource = try c.decodeIfPresent(String.self, forKey: .cheatSource)
        rawCode = try c.decodeIfPresent(String.self, forKey: .rawCode)
        coreIdentifier = try c.decodeIfPresent(String.self, forKey: .coreIdentifier)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(cheatSource, forKey: .cheatSource)
        try c.encodeIfPresent(rawCode, forKey: .rawCode)
        try c.encodeIfPresent(coreIdentifier, forKey: .coreIdentifier)
    }
}
