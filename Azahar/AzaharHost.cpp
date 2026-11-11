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

#include <algorithm>
#include <array>
#include <atomic>
#include <deque>
#include <memory>
#include <mutex>
#include <tuple>

#include "audio_core/audio_types.h"
#include "audio_core/sink.h"
#include "audio_core/sink_details.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/logging/filter.h"
#include "common/settings.h"
#include "core/core.h"
#include "core/frontend/applets/default_applets.h"
#include "core/frontend/emu_window.h"
#include "core/frontend/image_interface.h"
#include "core/frontend/input.h"
#include "core/hle/service/service.h"
#include "core/loader/loader.h"
#include "video_core/gpu.h"
#include "video_core/rasterizer_interface.h"
#include "video_core/renderer_base.h"

namespace {

/// Samples the engine has produced and OpenEmu has not taken yet. The engine pushes them from the
/// emulation thread as it makes them; the core drains them in executeFrame.
std::mutex gAudioLock;
std::deque<int16_t> gAudio;

class OEAudioSink final : public AudioCore::Sink {
public:
    unsigned int GetNativeSampleRate() const override { return 32728; }
    void SetCallback(std::function<void(s16 *, std::size_t)>) override {}
    bool ImmediateSubmission() override { return true; }
    void PushSamples(const void *data, std::size_t numSamples) override {
        const int16_t *samples = static_cast<const int16_t *>(data);
        std::lock_guard<std::mutex> lock(gAudioLock);
        gAudio.insert(gAudio.end(), samples, samples + numSamples * 2);
        // Never hold more than about a second; if OpenEmu stops draining, drop the oldest.
        constexpr size_t kMaxSamples = 32728 * 2;
        if (gAudio.size() > kMaxSamples) {
            gAudio.erase(gAudio.begin(), gAudio.begin() + (gAudio.size() - kMaxSamples));
        }
    }
};

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
std::atomic<void *> gFrameTexture{nullptr};

// Input state written by OpenEmu's input thread and read by the engine on the emulation thread.
std::array<std::atomic<bool>, static_cast<size_t>(AzaharHost::Button::Count)> gButtons{};
/// Frames since each button was last pressed. A press is kept for at least kMinHoldFrames so a very
/// quick tap (a click or a key pressed and released within one frame) is still seen: the engine only
/// looks at its buttons a few times per frame.
std::array<std::atomic<int>, static_cast<size_t>(AzaharHost::Button::Count)> gButtonAge{};
constexpr int kMinHoldFrames = 4;
std::atomic<bool> gTouchDown{false};
std::atomic<bool> gTouchReleaseWanted{false};
std::atomic<int> gTouchAge{0};
std::array<std::atomic<float>, static_cast<size_t>(AzaharHost::Axis::Count)> gAxes{};

/// The engine's buttons, in OpenEmu's order (AzaharHost::Button), by their native index.
constexpr std::array<int, static_cast<size_t>(AzaharHost::Button::Count)> kNativeButtons = {
    Settings::NativeButton::A,     Settings::NativeButton::B,    Settings::NativeButton::X,
    Settings::NativeButton::Y,     Settings::NativeButton::Up,   Settings::NativeButton::Down,
    Settings::NativeButton::Left,  Settings::NativeButton::Right, Settings::NativeButton::L,
    Settings::NativeButton::R,     Settings::NativeButton::Start, Settings::NativeButton::Select,
    Settings::NativeButton::ZL,    Settings::NativeButton::ZR,
};

class OEButton final : public ::Input::ButtonDevice {
public:
    explicit OEButton(size_t index) : index(index) {}
    bool GetStatus() const override { return gButtons[index] || gButtonAge[index] < kMinHoldFrames; }

private:
    size_t index;
};

class OEButtonFactory final : public ::Input::Factory<::Input::ButtonDevice> {
public:
    std::unique_ptr<::Input::ButtonDevice> Create(const Common::ParamPackage &params) override {
        const size_t index = static_cast<size_t>(params.Get("button", 0));
        return std::make_unique<OEButton>(index < gButtons.size() ? index : 0);
    }
};

/// A stick: axis 0 is the Circle Pad, axis 1 the C-Stick. The engine wants up to be positive Y.
class OEStick final : public ::Input::AnalogDevice {
public:
    explicit OEStick(size_t stick) : stick(stick) {}
    std::tuple<float, float> GetStatus() const override {
        return {gAxes[stick * 2], -gAxes[stick * 2 + 1]};
    }

private:
    size_t stick;
};

class OEStickFactory final : public ::Input::Factory<::Input::AnalogDevice> {
public:
    std::unique_ptr<::Input::AnalogDevice> Create(const Common::ParamPackage &params) override {
        return std::make_unique<OEStick>(params.Get("axis", 0) == 1 ? 1 : 0);
    }
};

void ApplyOpenEmuSettings() {
    for (auto &age : gButtonAge) age = 1000;
    // OpenEmu drives the engine one frame at a time and paces it, so the engine's own
    // limiter and audio stretching stay off (the same choice Azahar's libretro frontend makes).
    Settings::values.frame_limit = 0;
    Settings::values.enable_audio_stretching = false;

    // Vulkan through MoltenVK is the only hardware renderer on macOS. The present step runs on
    // the emulation thread so each frame is finished when the engine says it drew it.
    Settings::values.graphics_api = Settings::GraphicsAPI::Vulkan;
    Settings::values.async_presentation = false;
    Settings::values.use_vsync = false;
    // Compiled shaders are kept on disk (in the user directory), so a game stutters the first time an
    // effect appears and not again. Asynchronous compilation stays off: it skips drawing until a
    // shader is ready, which shows as a black picture at the start of a game.
    Settings::values.use_disk_shader_cache = true;
    Settings::values.async_shader_compilation = false;
    Settings::values.filter_mode = false;

    Settings::values.audio_emulation = Settings::AudioEmulation::HLE;
    Settings::values.output_type = AudioCore::SinkType::OpenEmu;
    Settings::values.input_type = AudioCore::InputType::Null;

    Settings::values.use_cpu_jit = true;
    Settings::values.use_virtual_sd = true;
    // Bind every 3DS button and both sticks to the "openemu" factory registered in Initialize.
    auto &profile = Settings::values.current_input_profile;
    profile.touch_device = "engine:emu_window";
    for (size_t i = 0; i < kNativeButtons.size(); i++) {
        profile.buttons[kNativeButtons[i]] = "button:" + std::to_string(i) + ",engine:openemu";
    }
    profile.analogs[Settings::NativeAnalog::CirclePad] = "axis:0,engine:openemu";
    profile.analogs[Settings::NativeAnalog::CStick] = "axis:1,engine:openemu";
}

} // namespace

namespace AudioCore {
std::unique_ptr<Sink> OEHostCreateAudioSink() {
    return std::make_unique<OEAudioSink>();
}
} // namespace AudioCore

extern "C" const char *OEHostMoltenVKPath() {
    return gMoltenVKPath.empty() ? nullptr : gMoltenVKPath.c_str();
}

extern "C" void OEHostFrameRendered(u32 width, u32 height, void *metalTexture) {
    gFrameWidth = width;
    gFrameHeight = height;
    gFrameTexture = metalTexture;
    gFrameDone = true;
}

namespace AzaharHost {

bool Initialize(const Folders &folders, std::string *error) {
    if (gInitialized) {
        return true;
    }
    gMoltenVKPath = folders.moltenVKPath;
    // The engine builds each sub-folder path by appending to this one, so it needs a trailing slash.
    std::string userDir = folders.userDir;
    if (userDir.empty() || userDir.back() != '/') userDir += '/';

    // Point every Azahar folder (sdmc, nand, sysdata, shaders, logs) at OpenEmu's support folder and
    // never touch a standalone Azahar's own. This must come before anything else asks for a path
    // (the logger does): the engine fills in each sub-folder once, on first use, and keeps whatever
    // it chose then.
    FileUtil::SetUserPath(userDir);

    Common::Log::Initialize();
    Common::Log::Start();

    // The same one-time setup Azahar's libretro frontend does in retro_init.
    for (const auto &module : Service::service_module_map) {
        Settings::values.lle_modules.emplace(module.name, false);
    }
    auto &system = Core::System::GetInstance();
    Frontend::RegisterDefaultApplets(system);
    system.RegisterImageInterface(std::make_shared<Frontend::ImageInterface>());

    ::Input::RegisterFactory<::Input::ButtonDevice>("openemu", std::make_shared<OEButtonFactory>());
    ::Input::RegisterFactory<::Input::AnalogDevice>("openemu", std::make_shared<OEStickFactory>());

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

    // Age the held inputs, and let go of a touch that was released too quickly to be seen.
    for (auto &age : gButtonAge) {
        if (age < 1000) age++;
    }
    if (gTouchDown) {
        if (gTouchAge < 1000) gTouchAge++;
        if (gTouchReleaseWanted && gTouchAge >= kMinHoldFrames) {
            gTouchReleaseWanted = false;
            gTouchDown = false;
            gWindow->TouchReleased();
        }
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
    gFrameTexture = nullptr;
    {
        std::lock_guard<std::mutex> lock(gAudioLock);
        gAudio.clear();
    }
    gWindow.reset();
}

void SetButton(Button button, bool pressed) {
    if (button >= Button::Count) return;
    const size_t index = static_cast<size_t>(button);
    if (pressed && !gButtons[index]) gButtonAge[index] = 0;
    gButtons[index] = pressed;
}

void SetAxis(Axis axis, float value) {
    if (axis < Axis::Count) gAxes[static_cast<size_t>(axis)] = value < -1.0f ? -1.0f : (value > 1.0f ? 1.0f : value);
}

void TouchPressed(unsigned x, unsigned y) {
    if (!gWindow) return;
    gTouchReleaseWanted = false;
    gTouchAge = 0;
    gTouchDown = true;
    gWindow->TouchPressed(x, y);
}

void TouchMoved(unsigned x, unsigned y) {
    if (gWindow) gWindow->TouchMoved(x, y);
}

void TouchReleased() {
    if (!gWindow || !gTouchDown) return;
    // A very short tap is held to the minimum; RunFrame lets go of it.
    if (gTouchAge < kMinHoldFrames) {
        gTouchReleaseWanted = true;
    } else {
        gTouchDown = false;
        gWindow->TouchReleased();
    }
}

uint32_t FrameWidth() { return gFrameWidth; }
uint32_t FrameHeight() { return gFrameHeight; }
void *FrameTexture() { return gFrameTexture; }

size_t PullAudio(int16_t *out, size_t maxFrames) {
    std::lock_guard<std::mutex> lock(gAudioLock);
    const size_t frames = std::min(maxFrames, gAudio.size() / 2);
    std::copy_n(gAudio.begin(), frames * 2, out);
    gAudio.erase(gAudio.begin(), gAudio.begin() + frames * 2);
    return frames;
}

} // namespace AzaharHost
