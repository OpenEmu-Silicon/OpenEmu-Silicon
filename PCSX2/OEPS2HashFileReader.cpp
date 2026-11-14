// Copyright (c) 2026, OpenEmu Team
// Author: Leonardo Kasperavičius
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.


#include "OEPS2HashFileReader.h"

#include "common/Error.h"
#include "pcsx2/CDVD/CsoFileReader.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <strings.h>
#include <vector>

namespace {

constexpr uint32_t OEPS2HashSectorSize = 2048;

struct OEPS2HashFile {
	FILE *file = nullptr;                 // a plain file,
	std::unique_ptr<CsoFileReader> cso;   // or a compressed image:
	uint64_t size = 0;
	uint64_t position = 0;
	std::vector<uint8_t> sectors;
};

// CsoFileReader reads both: a CSO (deflate) and a ZSO (LZ4).
bool OEPS2HashIsCompressed(const char *path)
{
	const size_t length = strlen(path);
	return length > 4 && (strcasecmp(path + length - 4, ".cso") == 0 || strcasecmp(path + length - 4, ".zso") == 0);
}

void *OEPS2HashOpen(const char *path)
{
	auto handle = std::make_unique<OEPS2HashFile>();
	if (OEPS2HashIsCompressed(path)) {
		handle->cso = std::make_unique<CsoFileReader>();
		Error error;
		if (!handle->cso->Open(path, &error)) {
			return nullptr;
		}
		handle->cso->SetBlockSize(OEPS2HashSectorSize);
		handle->size = (uint64_t)handle->cso->GetBlockCount() * OEPS2HashSectorSize;
		return handle.release();
	}
	handle->file = fopen(path, "rb");
	return handle->file ? handle.release() : nullptr;
}

void OEPS2HashSeek(void *opaque, int64_t offset, int origin)
{
	auto *handle = static_cast<OEPS2HashFile *>(opaque);
	if (handle->file) {
		fseeko(handle->file, (off_t)offset, origin);
		return;
	}
	const int64_t base = origin == SEEK_CUR ? (int64_t)handle->position : origin == SEEK_END ? (int64_t)handle->size : 0;
	handle->position = base + offset < 0 ? 0 : (uint64_t)(base + offset);
}

int64_t OEPS2HashTell(void *opaque)
{
	auto *handle = static_cast<OEPS2HashFile *>(opaque);
	return handle->file ? (int64_t)ftello(handle->file) : (int64_t)handle->position;
}

size_t OEPS2HashRead(void *opaque, void *buffer, size_t requested)
{
	auto *handle = static_cast<OEPS2HashFile *>(opaque);
	if (handle->file) {
		return fread(buffer, 1, requested, handle->file);
	}

	// The engine reads whole sectors; a few at a time keeps rcheevos's small reads cheap.
	constexpr uint32_t sectorsPerRead = 32;
	handle->sectors.resize(sectorsPerRead * OEPS2HashSectorSize);
	uint8_t *output = static_cast<uint8_t *>(buffer);
	size_t copied = 0;
	while (copied < requested && handle->position < handle->size) {
		const uint32_t sector = (uint32_t)(handle->position / OEPS2HashSectorSize);
		const uint64_t remainingSectors = (handle->size - (uint64_t)sector * OEPS2HashSectorSize) / OEPS2HashSectorSize;
		const uint32_t count = (uint32_t)std::min<uint64_t>(sectorsPerRead, remainingSectors);
		if (count == 0 || handle->cso->ReadSync(handle->sectors.data(), sector, count) != (int)(count * OEPS2HashSectorSize)) {
			break;
		}
		const size_t offset = (size_t)(handle->position - (uint64_t)sector * OEPS2HashSectorSize);
		const size_t chunk = std::min<size_t>(count * OEPS2HashSectorSize - offset, requested - copied);
		memcpy(output + copied, handle->sectors.data() + offset, chunk);
		copied += chunk;
		handle->position += chunk;
	}
	return copied;
}

void OEPS2HashClose(void *opaque)
{
	auto *handle = static_cast<OEPS2HashFile *>(opaque);
	if (handle->file) {
		fclose(handle->file);
	}
	if (handle->cso) {
		handle->cso->Close(); // the engine's reader must be closed before it is destroyed
	}
	delete handle;
}

} // namespace

const rc_hash_filereader_t OEPS2HashFileReader = {
	OEPS2HashOpen,
	OEPS2HashSeek,
	OEPS2HashTell,
	OEPS2HashRead,
	OEPS2HashClose,
};
