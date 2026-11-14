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

#include "OEChdFileLoader.h"

#include <memory>
#include <mutex>

#include "Core/Loaders.h"
#include "../../OpenEmu-SDK/OpenEmuSystem/OECHDReader.h"

static const std::string OEChdPathPrefix = "oechd:";
static const std::string OEChdPathSuffix = ".iso";

namespace {

class OEChdFileLoader : public FileLoader {
public:
    OEChdFileLoader(const Path &path, OECHDReader *reader) : path_(path), reader_(reader) {}
    ~OEChdFileLoader() override { OECHDReaderClose(reader_); }

    bool Exists() override { return reader_ != nullptr; }
    bool IsDirectory() override { return false; }
    s64 FileSize() override { return reader_ != nullptr ? (s64)OECHDReaderSize(reader_) : 0; }
    Path GetPath() const override { return path_; }

    using FileLoader::ReadAt;
    // Like fread: returns how many whole items of `bytes` bytes were read. PPSSPP reads from more
    // than one thread (the emulator and its file thread), and one reader must be used by one at a time.
    size_t ReadAt(s64 absolutePos, size_t bytes, size_t count, void *data, Flags flags = Flags::NONE) override {
        if (reader_ == nullptr || absolutePos < 0 || bytes == 0)
            return 0;
        std::lock_guard<std::mutex> guard(lock_);
        return OECHDReaderRead(reader_, (uint64_t)absolutePos, data, bytes * count) / bytes;
    }

    std::string LatestError() const override {
        return reader_ != nullptr ? "" : "The CHD file could not be opened.";
    }

private:
    Path path_;
    OECHDReader *reader_;
    std::mutex lock_;
};

class OEChdFileLoaderFactory : public FileLoaderFactory {
public:
    FileLoader *ConstructFileLoader(const Path &filename) override {
        std::string chdPath = filename.ToString().substr(OEChdPathPrefix.size());
        if (chdPath.size() >= OEChdPathSuffix.size() &&
            chdPath.compare(chdPath.size() - OEChdPathSuffix.size(), OEChdPathSuffix.size(), OEChdPathSuffix) == 0)
            chdPath.resize(chdPath.size() - OEChdPathSuffix.size());

        OECHDReader *reader = nullptr;
        OECHDReaderOpenDVD(chdPath.c_str(), &reader);
        return new OEChdFileLoader(filename, reader);
    }
};

} // namespace

void OERegisterChdFileLoader()
{
    static std::once_flag registered;
    std::call_once(registered, [] {
        RegisterFileLoaderFactory(OEChdPathPrefix, std::unique_ptr<FileLoaderFactory>(new OEChdFileLoaderFactory()));
    });
}

Path OEChdFileLoaderPath(const std::string &chdPath)
{
    return Path(OEChdPathPrefix + chdPath + OEChdPathSuffix);
}
