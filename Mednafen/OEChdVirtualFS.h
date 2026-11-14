/*
 Copyright (c) 2026, OpenEmu Team
 Author: Leonardo Kasperavičius

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

// Mednafen cannot read CHD files. Instead of changing Mednafen, the wrapper gives it a VirtualFS of
// our own: opening a .chd through it reads a CUE sheet written for that CHD, and each track file the
// sheet names ("<CHD name> (Track NN).bin", next to the CHD) is served from the CHD (OECHDReader).
// Every other path goes to Mednafen's normal file system, so files next to the disc (a LibCrypt
// .sbi) still work. Mednafen opens a .m3u's entries through the same VirtualFS, so a playlist can list
// CHDs. A single CHD is loaded as a CD (MDFNI_LoadGame's force_cd), since its extension is not one
// Mednafen knows; the CUE sheet keeps the CHD's name, so saves are named as for the CUE/BIN version.
//
// RetroAchievements reads the CHDs through OEChdHashFileReader: a .chd reads as its first track's
// .bin, which is what rcheevos hashes for a PlayStation or Saturn disc.

#pragma once

#include "mednafen.h" // first: Mednafen's types.h must come before any standard header

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <rc_hash.h>
#include "../OpenEmu-SDK/OpenEmuSystem/OECHDReader.h"

/// One open CD-type CHD, and the CUE sheet and track files it is presented as.
class OEChdDisc
{
public:
    /// Opens the CHD at `chdPath`; on failure returns nullptr and sets `status`.
    static std::shared_ptr<OEChdDisc> open(const std::string &chdPath, OECHDReaderStatus *status);
    ~OEChdDisc();

    const std::string &cueSheet() const { return _cueSheet; }
    const std::vector<std::string> &trackPaths() const { return _trackPaths; }

    uint64_t trackSize(int track) const;
    size_t readTrack(int track, uint64_t offset, void *buffer, size_t length);

private:
    OEChdDisc() = default;

    OECHDReader *_reader = nullptr;
    std::mutex _lock; // Mednafen reads the disc on its own thread, RetroAchievements on another
    std::string _cueSheet;
    std::vector<std::string> _trackPaths;
};

/// The VirtualFS Mednafen loads a game with CHD discs through.
class OEChdVirtualFS final : public Mednafen::VirtualFS
{
public:
    explicit OEChdVirtualFS(Mednafen::VirtualFS *fallback);

    /// Opens the CHD at `chdPath` as one of the game's discs. Discs a .m3u lists are also opened when
    /// Mednafen first reads them; opening them first gives a clear error for an unusable CHD.
    OECHDReaderStatus addDisc(const std::string &chdPath);

    /// The disc whose CHD is at `path`, or nullptr.
    std::shared_ptr<OEChdDisc> discAtPath(const std::string &path);

    Mednafen::Stream *open(const std::string &path, const uint32 mode, const int do_lock = false, const bool throw_on_noent = true, const CanaryType canary = CanaryType::open) override;
    bool mkdir(const std::string &path, const bool throw_on_exist = false) override;
    bool unlink(const std::string &path, const bool throw_on_noent = false, const CanaryType canary = CanaryType::unlink) override;
    void rename(const std::string &oldpath, const std::string &newpath, const CanaryType canary = CanaryType::rename) override;
    bool finfo(const std::string &path, FileInfo *info, const bool throw_on_noent = true) override;
    void readdirentries(const std::string &path, std::function<bool(const std::string &)> callb) override;
    // VirtualFS treats every path as absolute; without this, Mednafen opens a CUE sheet's track files
    // by their bare names instead of next to the CUE sheet.
    bool is_absolute_path(const std::string &path) override;

    /// The VirtualFS of the game being played, for RetroAchievements. Set by the wrapper, nullptr when none.
    static void setCurrent(OEChdVirtualFS *vfs);
    static OEChdVirtualFS *current();

private:
    struct Track { std::shared_ptr<OEChdDisc> disc; int index; };
    bool trackAtPath(const std::string &path, Track *track);

    Mednafen::VirtualFS *_fallback;
    std::mutex _lock; // the disc lists, used from Mednafen's thread and RetroAchievements'
    std::map<std::string, std::shared_ptr<OEChdDisc>> _discs;
    std::map<std::string, Track> _tracks;
};

/// A file reader for rcheevos that reads the current game's CHDs as their first track's .bin and any
/// other path from disk.
extern const rc_hash_filereader_t OEChdHashFileReader;

/// Why a CHD cannot be played, in words for the player.
std::string OEChdLoadErrorReason(OECHDReaderStatus status);
