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

#include "OEChdVirtualFS.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>

#include "MemoryStream.h"

using namespace Mednafen;

static bool OEChdHasExtension(const std::string &path, const char *extension)
{
    const size_t length = strlen(extension);
    return path.size() > length && strcasecmp(path.c_str() + path.size() - length, extension) == 0;
}

#pragma mark - OEChdDisc

std::shared_ptr<OEChdDisc> OEChdDisc::open(const std::string &chdPath, OECHDReaderStatus *status)
{
    OECHDReader *reader = nullptr;
    *status = OECHDReaderOpenCD(chdPath.c_str(), &reader);
    if (*status != OECHDReaderStatusOK)
        return nullptr;

    std::shared_ptr<OEChdDisc> disc(new OEChdDisc());
    disc->_reader = reader;

    const size_t slash = chdPath.find_last_of('/');
    const std::string folder = slash == std::string::npos ? std::string(".") : chdPath.substr(0, slash);
    const std::string fileName = slash == std::string::npos ? chdPath : chdPath.substr(slash + 1);
    const size_t dot = fileName.find_last_of('.');
    std::string baseName = dot == std::string::npos ? fileName : fileName.substr(0, dot);
    for (char &character : baseName) // a quote would end the track's name in the CUE sheet
        if (character == '"')
            character = '\'';

    const size_t cueLength = OECHDReaderWriteCueSheet(reader, baseName.c_str(), nullptr, 0);
    disc->_cueSheet.assign(cueLength + 1, '\0');
    OECHDReaderWriteCueSheet(reader, baseName.c_str(), &disc->_cueSheet[0], disc->_cueSheet.size());
    disc->_cueSheet.resize(cueLength);

    for (unsigned index = 0; index < OECHDReaderTrackCount(reader); index++) {
        const unsigned number = OECHDReaderTrackAtIndex(reader, index)->number;
        std::string trackName(OECHDReaderTrackFileName(baseName.c_str(), number, nullptr, 0) + 1, '\0');
        OECHDReaderTrackFileName(baseName.c_str(), number, &trackName[0], trackName.size());
        trackName.pop_back();
        disc->_trackPaths.push_back(folder + "/" + trackName);
    }
    return disc;
}

OEChdDisc::~OEChdDisc()
{
    OECHDReaderClose(_reader);
}

uint64_t OEChdDisc::trackSize(int track) const
{
    return OECHDReaderTrackSize(_reader, (unsigned)track);
}

size_t OEChdDisc::readTrack(int track, uint64_t offset, void *buffer, size_t length)
{
    std::lock_guard<std::mutex> guard(_lock);
    return OECHDReaderReadTrack(_reader, (unsigned)track, offset, buffer, length);
}

#pragma mark - Track stream

namespace {

/// One track's .bin, read from the CHD.
class OEChdTrackStream final : public Stream
{
public:
    OEChdTrackStream(std::shared_ptr<OEChdDisc> disc, int track) : _disc(std::move(disc)), _track(track), _size(_disc->trackSize(track)) {}

    uint64 attributes(void) override { return ATTRIBUTE_READABLE | ATTRIBUTE_SEEKABLE; }

    uint64 read(void *data, uint64 count, bool error_on_eos = true) override
    {
        const size_t got = _position < _size ? _disc->readTrack(_track, _position, data, (size_t)count) : 0;
        _position += got;
        if (got < count && error_on_eos)
            throw MDFN_Error(0, "Unexpected EOF");
        return got;
    }

    void write(const void *, uint64) override { throw MDFN_Error(EBADF, "A track of a CHD cannot be written to."); }
    void truncate(uint64) override { throw MDFN_Error(EBADF, "A track of a CHD cannot be written to."); }

    void seek(int64 offset, int whence = SEEK_SET) override
    {
        int64 base = 0;
        if (whence == SEEK_CUR)
            base = (int64)_position;
        else if (whence == SEEK_END)
            base = (int64)_size;
        if (base + offset < 0)
            throw MDFN_Error(EINVAL, "Seek before the start of a CHD track.");
        _position = (uint64)(base + offset);
    }

    uint64 tell(void) override { return _position; }
    uint64 size(void) override { return _size; }
    void flush(void) override {}
    void close(void) override {}

private:
    std::shared_ptr<OEChdDisc> _disc;
    int _track;
    uint64 _size;
    uint64 _position = 0;
};

} // namespace

#pragma mark - OEChdVirtualFS

OEChdVirtualFS::OEChdVirtualFS(VirtualFS *fallback)
    : VirtualFS('/', "/"), _fallback(fallback)
{
}

OECHDReaderStatus OEChdVirtualFS::addDisc(const std::string &chdPath)
{
    std::lock_guard<std::mutex> guard(_lock);
    if (_discs.count(chdPath))
        return OECHDReaderStatusOK;

    OECHDReaderStatus status = OECHDReaderStatusCouldNotOpen;
    std::shared_ptr<OEChdDisc> disc = OEChdDisc::open(chdPath, &status);
    if (!disc)
        return status;

    _discs[chdPath] = disc;
    for (size_t index = 0; index < disc->trackPaths().size(); index++)
        _tracks[disc->trackPaths()[index]] = Track { disc, (int)index };
    return OECHDReaderStatusOK;
}

std::shared_ptr<OEChdDisc> OEChdVirtualFS::discAtPath(const std::string &path)
{
    std::lock_guard<std::mutex> guard(_lock);
    auto found = _discs.find(path);
    return found != _discs.end() ? found->second : nullptr;
}

bool OEChdVirtualFS::trackAtPath(const std::string &path, Track *track)
{
    std::lock_guard<std::mutex> guard(_lock);
    auto found = _tracks.find(path);
    if (found == _tracks.end())
        return false;
    *track = found->second;
    return true;
}

Stream *OEChdVirtualFS::open(const std::string &path, const uint32 mode, const int do_lock, const bool throw_on_noent, const CanaryType canary)
{
    // A .chd a playlist lists, read for the first time.
    if (OEChdHasExtension(path, ".chd") && !discAtPath(path)) {
        const OECHDReaderStatus status = addDisc(path);
        if (status != OECHDReaderStatusOK)
            throw MDFN_Error(0, "%s", OEChdLoadErrorReason(status).c_str());
    }

    std::shared_ptr<OEChdDisc> disc = discAtPath(path);
    Track track;
    const bool isTrack = !disc && trackAtPath(path, &track);
    if (!disc && !isTrack)
        return _fallback->open(path, mode, do_lock, throw_on_noent, canary);

    if (mode != MODE_READ)
        throw MDFN_Error(EPERM, "A file inside a CHD cannot be written to.");
    if (isTrack)
        return new OEChdTrackStream(track.disc, track.index);

    const std::string &cue = disc->cueSheet();
    MemoryStream *stream = new MemoryStream(cue.size(), true);
    if (!cue.empty())
        memcpy(stream->map(), cue.data(), cue.size());
    return stream;
}

bool OEChdVirtualFS::mkdir(const std::string &path, const bool throw_on_exist)
{
    return _fallback->mkdir(path, throw_on_exist);
}

bool OEChdVirtualFS::unlink(const std::string &path, const bool throw_on_noent, const CanaryType canary)
{
    return _fallback->unlink(path, throw_on_noent, canary);
}

void OEChdVirtualFS::rename(const std::string &oldpath, const std::string &newpath, const CanaryType canary)
{
    _fallback->rename(oldpath, newpath, canary);
}

bool OEChdVirtualFS::finfo(const std::string &path, FileInfo *info, const bool throw_on_noent)
{
    std::shared_ptr<OEChdDisc> disc = discAtPath(path);
    Track track;
    if (!disc && !trackAtPath(path, &track))
        return _fallback->finfo(path, info, throw_on_noent);

    if (info != nullptr) {
        *info = FileInfo();
        info->size = disc ? disc->cueSheet().size() : track.disc->trackSize(track.index);
        info->is_regular = true;
    }
    return true;
}

void OEChdVirtualFS::readdirentries(const std::string &path, std::function<bool(const std::string &)> callb)
{
    _fallback->readdirentries(path, callb);
}

bool OEChdVirtualFS::is_absolute_path(const std::string &path)
{
    return _fallback->is_absolute_path(path);
}

static std::mutex OEChdCurrentLock;
static OEChdVirtualFS *OEChdCurrentVFS;

void OEChdVirtualFS::setCurrent(OEChdVirtualFS *vfs)
{
    std::lock_guard<std::mutex> guard(OEChdCurrentLock);
    OEChdCurrentVFS = vfs;
}

OEChdVirtualFS *OEChdVirtualFS::current()
{
    std::lock_guard<std::mutex> guard(OEChdCurrentLock);
    return OEChdCurrentVFS;
}

#pragma mark - RetroAchievements file reader

namespace {

struct OEChdHashFile {
    FILE *file = nullptr;                 // a real file
    std::shared_ptr<OEChdDisc> disc;      // or a CHD, read as its first track's .bin
    uint64_t position = 0;
};

void *OEChdHashOpen(const char *path)
{
    OEChdVirtualFS *vfs = OEChdVirtualFS::current();
    OEChdHashFile *handle = new OEChdHashFile();
    if (vfs != nullptr && OEChdHasExtension(path, ".chd") && vfs->addDisc(path) == OECHDReaderStatusOK) {
        handle->disc = vfs->discAtPath(path);
        return handle;
    }
    handle->file = fopen(path, "rb");
    if (handle->file == nullptr) {
        delete handle;
        return nullptr;
    }
    return handle;
}

void OEChdHashSeek(void *opaque, int64_t offset, int origin)
{
    OEChdHashFile *handle = (OEChdHashFile *)opaque;
    if (handle->file != nullptr) {
        fseeko(handle->file, (off_t)offset, origin);
        return;
    }
    const int64_t base = origin == SEEK_CUR ? (int64_t)handle->position : origin == SEEK_END ? (int64_t)handle->disc->trackSize(0) : 0;
    handle->position = base + offset < 0 ? 0 : (uint64_t)(base + offset);
}

int64_t OEChdHashTell(void *opaque)
{
    OEChdHashFile *handle = (OEChdHashFile *)opaque;
    return handle->file != nullptr ? (int64_t)ftello(handle->file) : (int64_t)handle->position;
}

size_t OEChdHashRead(void *opaque, void *buffer, size_t requested)
{
    OEChdHashFile *handle = (OEChdHashFile *)opaque;
    if (handle->file != nullptr)
        return fread(buffer, 1, requested, handle->file);

    const size_t got = handle->disc->readTrack(0, handle->position, buffer, requested);
    handle->position += got;
    return got;
}

void OEChdHashClose(void *opaque)
{
    OEChdHashFile *handle = (OEChdHashFile *)opaque;
    if (handle->file != nullptr)
        fclose(handle->file);
    delete handle;
}

} // namespace

const rc_hash_filereader_t OEChdHashFileReader = {
    OEChdHashOpen,
    OEChdHashSeek,
    OEChdHashTell,
    OEChdHashRead,
    OEChdHashClose,
};

std::string OEChdLoadErrorReason(OECHDReaderStatus status)
{
    switch (status) {
        case OECHDReaderStatusNotCD:
            return "This CHD holds a DVD or another kind of image. These games need a CD-type CHD: make it again from the CUE/BIN with \"chdman createcd\".";
        case OECHDReaderStatusNeedsParent:
            return "This CHD only stores the differences from another CHD (its parent), which OpenEmu does not support. Make it again from the CUE/BIN with \"chdman createcd\".";
        case OECHDReaderStatusUnsupported:
            return "This CHD uses a CHD version, a compression method or a kind of track OpenEmu does not support. Make it again from the CUE/BIN with \"chdman createcd\".";
        default:
            return "The CHD file could not be read. It may be damaged or incomplete.";
    }
}
