// Copyright (c) 2026, CheatWorks Team
// Author: Leonardo Kasperavičius
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the CheatWorks Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY CheatWorks Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL CheatWorks Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Part of the portable CheatWorks Integration SDK core — no host dependencies.

import Foundation

/// An emulator/core recognized by CheatWorks. The raw value is the backend's emulator code, sent
/// verbatim in feedback requests. Mirrors the server's `EmulatorCode` enum; keep in sync.
public enum CheatWorksEmulatorCode: String, Sendable, CaseIterable {
    case nestopia = "nestopia"
    case mgba = "mgba"
    case gambatte = "gambatte"
    case genesisPlus = "genesisplus"
    case snes9x = "snes9x"
    case bsnes = "bsnes"
    case fceu = "fceu"
    case proSystem = "prosystem"
    case mame = "mame"
    case dolphin = "dolphin"
    case ppsspp = "ppsspp"
    case the4DO = "4do"
    case atari800 = "atari800"
    case bliss = "bliss"
    case crabEmu = "crabemu"
    case deSmuME = "desmume"
    case flycast = "flycast"
    case jollyCV = "jollycv"
    case mednafen = "mednafen"
    case mupen64Plus = "mupen64plus"
    case o2em = "o2em"
    case pokeMini = "pokemini"
    case potator = "potator"
    case stella = "stella"
    case vecXGL = "vecxgl"
    case virtualJaguar = "virtualjaguar"
    case blueMSX = "bluemsx"
    case picodrive = "picodrive"
}
