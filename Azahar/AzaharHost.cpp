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

#include "AzaharHost.h"

#include <atomic>
#include <memory>

#include "audio_core/audio_types.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/filter.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/emu_window.h"
#include "core/frontend/image_interface.h"
#include "core/hle/service/service.h"
#include "core/loader/loader.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_base.h"

namespace {

/// The window the engine draws into. The engine never shows it; each finished frame is
/// handed to OpenEmu instead (see the engine patch 0001-openemu-host-hooks.patch).
class OEEmuWindow final : public Frontend::EmuWindow {
public:
    explicit OEEmuWindow(void *metalLayer) {
        window_info.type = Frontend::WindowSystemType::MacOS;
        window_info.render_surface = metalLayer;
        window_info.render_surface_scale = 1.0f;
    }
    ~OEEmuWindow() override = default;

    void PollEvents() override {}
    void MakeCurrent() override {}
    void DoneCurrent() override {}

    void SetLayoutSize(unsigned width, unsigned height) { UpdateCurrentFramebufferLayout(width, height); }
};

std::string gMoltenVKPath;
void *gMetalLayer = nullptr;
std::unique_ptr<OEEmuWindow> gWindow;
bool gInitialized = false;
bool gLoaded = false;

std::atomic<bool> gFrameDone{false};
std::atomic<uint32_t> gFrameWidth{0};
std::atomic<uint32_t> gFrameHeight{0};

void ApplyOpenEmuSettings() {
    // OpenEmu drives the engine one frame at a time and paces it, so the engine's own
    // limiter and audio stretching stay off (the same choice Azahar's libretro frontend makes).
    Settings::values.frame_limit = 0;
    Settings::values.enable_audio_stretching = false;

    // Vulkan through MoltenVK is the only hardware renderer on macOS. The present step runs on
    // the emulation thread so each frame is finished when the engine says it drew it.
    Settings::values.graphics_api = Settings::GraphicsAPI::Vulkan;
    Settings::values.async_presentation = false;
    Settings::values.use_vsync = false;
    Settings::values.use_disk_shader_cache = false;
    Settings::values.filter_mode = false;

    Settings::values.audio_emulation = Settings::AudioEmulation::HLE;
    Settings::values.output_type = AudioCore::SinkType::Null;
    Settings::values.input_type = AudioCore::InputType::Null;

    Settings::values.use_cpu_jit = true;
    Settings::values.use_virtual_sd = true;
    Settings::values.current_input_profile.touch_device = "engine:emu_window";
}

} // namespace

extern "C" const char *OEHostMoltenVKPath() {
    return gMoltenVKPath.empty() ? nullptr : gMoltenVKPath.c_str();
}

extern "C" void OEHostFrameRendered(u32 width, u32 height) {
    gFrameWidth = width;
    gFrameHeight = height;
    gFrameDone = true;
}

namespace AzaharHost {

bool Initialize(const Folders &folders, std::string *error) {
    if (gInitialized) {
        return true;
    }
    gMoltenVKPath = folders.moltenVKPath;

    Common::Log::Initialize();
    Common::Log::Start();

    // Point every Azahar folder (sdmc, nand, sysdata) at OpenEmu's support folder and never
    // read a standalone Azahar's own settings.
    FileUtil::SetUserPath(folders.userDir);

    // The same one-time setup Azahar's libretro frontend does in retro_init.
    for (const auto &module : Service::service_module_map) {
        Settings::values.lle_modules.emplace(module.name, false);
    }
    auto &system = Core::System::GetInstance();
    Frontend::RegisterDefaultApplets(system);
    system.RegisterImageInterface(std::make_shared<Frontend::ImageInterface>());

    ApplyOpenEmuSettings();
    gInitialized = true;
    (void)error;
    return true;
}

void SetRenderSurface(void *metalLayer) {
    gMetalLayer = metalLayer;
}

bool Load(const std::string &path, std::string *error) {
    if (!gInitialized || gMetalLayer == nullptr) {
        if (error) *error = "The Azahar host was not set up.";
        return false;
    }
    gWindow = std::make_unique<OEEmuWindow>(gMetalLayer);
    // First picture size: both screens stacked, at the engine's normal resolution.
    const unsigned scale = Settings::values.resolution_factor.GetValue() ? Settings::values.resolution_factor.GetValue() : 1;
    gWindow->SetLayoutSize(Core::kScreenTopWidth * scale, (Core::kScreenTopHeight + Core::kScreenBottomHeight) * scale);

    auto &system = Core::System::GetInstance();
    system.ApplySettings();
    const Core::System::ResultStatus result = system.Load(*gWindow, path);
    switch (result) {
    case Core::System::ResultStatus::Success:
        break;
    case Core::System::ResultStatus::ErrorLoader_ErrorEncrypted:
        if (error) *error = "This game is encrypted. Azahar needs a decrypted dump or the matching keys.";
        return false;
    case Core::System::ResultStatus::ErrorLoader_ErrorInvalidFormat:
        if (error) *error = "This file is not a format Azahar can load.";
        return false;
    case Core::System::ResultStatus::ErrorGetLoader:
        if (error) *error = "Azahar could not recognize this file.";
        return false;
    default:
        if (error) *error = "Azahar could not load this game (error " + std::to_string(static_cast<int>(result)) + ").";
        return false;
    }

    u64 programId{};
    system.GetAppLoader().ReadProgramId(programId);
    system.GPU().ApplyPerProgramSettings(programId);
    // Sets up the pipeline cache the renderer draws through. Every Azahar frontend calls this,
    // even with the disk cache turned off; without it the first programmable shader crashes.
    system.GPU().Renderer().Rasterizer()->LoadDefaultDiskResources(false, nullptr);
    gLoaded = true;
    return true;
}

bool RunFrame(std::string *error) {
    if (!gLoaded) {
        return true;
    }
    auto &system = Core::System::GetInstance();
    static bool firstFrame = true;
    if (firstFrame) {
        firstFrame = false;
        system.RegisterCoreLoopThreadId();
    }

    gFrameDone = false;
    // A frame normally takes a few engine slices. The cap keeps OpenEmu's loop alive if a
    // game goes a long while without drawing (loading screens, a hang).
    for (int slices = 0; !gFrameDone && slices < 4000; slices++) {
        const Core::System::ResultStatus result = system.RunLoop();
        if (result != Core::System::ResultStatus::Success) {
            if (error) *error = "Azahar stopped: " + system.GetStatusDetails();
            return false;
        }
    }
    return true;
}

void Reset() {
    if (gLoaded) {
        Core::System::GetInstance().Reset();
    }
}

void Shutdown() {
    if (gLoaded || Core::System::GetInstance().IsPoweredOn()) {
        Core::System::GetInstance().Shutdown();
    }
    gLoaded = false;
    gWindow.reset();
}

uint32_t FrameWidth() { return gFrameWidth; }
uint32_t FrameHeight() { return gFrameHeight; }

} // namespace AzaharHost
