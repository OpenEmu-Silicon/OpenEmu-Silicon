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

/// A system/platform recognized by CheatWorks. The raw value is the backend's system code, sent
/// verbatim in feedback and ratings requests. Mirrors the server's `SystemCode` enum; keep in sync.
public enum CheatWorksSystem: String, Sendable, CaseIterable {
    case megaDrive = "mega_drive"
    case nintendo64 = "nintendo_64"
    case superNintendo = "super_nintendo"
    case gameboy = "gameboy"
    case gameboyAdvance = "gameboy_advance"
    case gameboyColor = "gameboy_color"
    case nintendo = "nintendo"
    case pcEngine = "pc_engine"
    case segaCD = "sega_cd"
    case sega32X = "sega_32x"
    case masterSystem = "master_system"
    case playstation = "playstation"
    case atariLynx = "atari_lynx"
    case neogeoPocket = "neogeo_pocket"
    case gameGear = "game_gear"
    case gamecube = "gamecube"
    case atariJaguar = "atari_jaguar"
    case nintendoDS = "nintendo_ds"
    case wii = "wii"
    case wiiU = "wii_u"
    case playstation2 = "playstation_2"
    case xbox = "xbox"
    case magnavoxOdyssey2 = "magnavox_odyssey2"
    case pokemonMini = "pokemon_mini"
    case atari2600 = "atari_2600"
    case msDOS = "ms_dos"
    case arcade = "arcade"
    case virtualBoy = "virtual_boy"
    case msx = "msx"
    case commodore64 = "commodore_64"
    case zx81 = "zx81"
    case oric = "oric"
    case sg1000 = "sg1000"
    case vic20 = "vic20"
    case amiga = "amiga"
    case atariST = "atari_st"
    case amstradPC = "amstrad_pc"
    case appleII = "apple_ii"
    case saturn = "saturn"
    case dreamcast = "dreamcast"
    case psp = "psp"
    case cdi = "cdi"
    case the3DO = "3do"
    case colecovision = "colecovision"
    case intellivision = "intellivision"
    case vectrex = "vectrex"
    case pc8800 = "pc8800"
    case pc9800 = "pc9800"
    case pcfx = "pcfx"
    case atari5200 = "atari_5200"
    case atari7800 = "atari_7800"
    case x68k = "x68k"
    case wonderswan = "wonderswan"
    case cassettevision = "cassettevision"
    case superCassettevision = "super_cassettevision"
    case neoGeoCD = "neo_geo_cd"
    case fairchildChannelF = "fairchild_channel_f"
    case fmTowns = "fm_towns"
    case zxSpectrum = "zx_spectrum"
    case gameAndWatch = "game_and_watch"
    case nokiaNGage = "nokia_ngage"
    case nintendo3DS = "nintendo_3ds"
    case supervision = "supervision"
    case sharpX1 = "sharpx1"
    case tic80 = "tic80"
    case thomsonTO8 = "thomsonto8"
    case pc6000 = "pc6000"
    case pico = "pico"
    case megaduck = "megaduck"
    case zeebo = "zeebo"
    case arduboy = "arduboy"
    case wasm4 = "wasm4"
    case arcadia2001 = "arcadia_2001"
    case intertonVC4000 = "interton_vc_4000"
    case elektorTVGamesComputer = "elektor_tv_games_computer"
    case pcEngineCD = "pc_engine_cd"
    case atariJaguarCD = "atari_jaguar_cd"
    case nintendoDSi = "nintendo_dsi"
    case ti83 = "ti83"
    case uzebox = "uzebox"
    case famicomDiskSystem = "famicom_disk_system"
    case playstation3 = "playstation_3"
}
