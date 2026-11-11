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

// The engine side of the Azahar core: a thin C++ layer between OpenEmu's game core
// (AzaharGameCore.mm, which includes no engine headers) and the Azahar engine.

#pragma once

#include <cstdint>
#include <string>

namespace AzaharHost {

struct Folders {
    std::string userDir;       // Azahar's user directory (virtual SD card, NAND, config)
    std::string moltenVKPath;  // libMoltenVK.dylib inside the plugin bundle
};

/// One-time engine setup. Call before anything else.
bool Initialize(const Folders &folders, std::string *error);

/// The CAMetalLayer the engine's Vulkan surface is created from. Call before Load.
void SetRenderSurface(void *metalLayer);

/// Load a game (.3ds, .cci, .cxi, .3dsx, .app). Call after Initialize and SetRenderSurface.
bool Load(const std::string &path, std::string *error);

/// Run the engine until it has drawn one frame. Returns false if the engine reported an error.
bool RunFrame(std::string *error);

void Reset();
void Shutdown();

// Input. The core sets these from OpenEmu's responder; the engine reads them each frame through
// the "openemu" input factory registered in Initialize.
enum class Button { A, B, X, Y, Up, Down, Left, Right, L, R, Start, Select, ZL, ZR, Count };
enum class Axis { CirclePadX, CirclePadY, CStickX, CStickY, Count };

void SetButton(Button button, bool pressed);
/// value runs from -1.0 to 1.0; negative is left on X and up on Y.
void SetAxis(Axis axis, float value);

/// Touch in the picture's own pixels, the size of the engine's frame (OpenEmu sends points in the
/// displayed picture, which is this frame). The engine maps them through the current layout.
void TouchPressed(unsigned x, unsigned y);
void TouchMoved(unsigned x, unsigned y);
void TouchReleased();

/// Size in pixels of the last frame the engine drew; 0 before the first one.
uint32_t FrameWidth();
uint32_t FrameHeight();

/// The id<MTLTexture> of the last frame the engine drew (not retained; null before the first one).
/// The texture belongs to the engine's frame pool and stays valid until the frame size changes
/// or the game stops, and the engine does not draw into it again for at least two frames.
void *FrameTexture();

} // namespace AzaharHost
