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
#include <cmath>
#include <chrono>
#include <fstream>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <tuple>
#include <vector>

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

// V2 diagnosis only: one small, flushed record per lifecycle milestone. The trace is stored
// alongside this core's user data, not in OpenEmu's application or any other core directory.
std::mutex gTraceLock;
std::string gTracePath;

void WriteCoreTrace(const char *event) {
    std::lock_guard<std::mutex> lock(gTraceLock);
    if (gTracePath.empty()) return;
    std::ofstream file(gTracePath, std::ios::app);
    if (!file) return;
    const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    file << millis << " thread=" << std::this_thread::get_id() << " " << event << '\n';
    file.flush();
}

// Diagnostic 4: Azahar's DSP produces stereo PCM at approximately 32,728 frames/sec.
// Passing this irregular rate directly into AVAudioEngine appeared to leave its
// real-time resampler busy when OpenEmu tried to pause audio. Produce 48-kHz PCM
// at the core boundary, without changing emulation timing, pitch, or the host app.
constexpr double kAzaharDSPRate = 32728.0;
constexpr unsigned int kOpenEmuPCMRate = 48000;

// Performance candidate 2: fixed-capacity stereo FIFO. The previous std::deque
// inserted and erased individual samples for every DSP batch and every pull.
// Retain the exact one-second limit and oldest-sample-drop behavior, but use
// contiguous copies and no queue allocations on the emulation hot path.
constexpr size_t kAudioCapacitySamples = static_cast<size_t>(kOpenEmuPCMRate) * 2;
std::mutex gAudioLock;
std::array<int16_t, kAudioCapacitySamples> gAudio{};
size_t gAudioRead = 0;
size_t gAudioSize = 0;

void AppendAudioLocked(const int16_t* samples, size_t count) {
    if (count >= kAudioCapacitySamples) {
        // Whole FIFO replaced by the most recent second, matching old behavior.
        samples += count - kAudioCapacitySamples;
        count = kAudioCapacitySamples;
        gAudioRead = 0;
        gAudioSize = 0;
    } else if (gAudioSize + count > kAudioCapacitySamples) {
        const size_t dropped = gAudioSize + count - kAudioCapacitySamples;
        gAudioRead = (gAudioRead + dropped) % kAudioCapacitySamples;
        gAudioSize -= dropped;
    }
    const size_t write = (gAudioRead + gAudioSize) % kAudioCapacitySamples;
    const size_t first = std::min(count, kAudioCapacitySamples - write);
    std::memcpy(gAudio.data() + write, samples, first * sizeof(int16_t));
    if (count > first) {
        std::memcpy(gAudio.data(), samples + first, (count - first) * sizeof(int16_t));
    }
    gAudioSize += count;
}

class OEAudioSink final : public AudioCore::Sink {
public:
    unsigned int GetNativeSampleRate() const override { return kOpenEmuPCMRate; }
    void SetCallback(std::function<void(s16 *, std::size_t)>) override {}
    bool ImmediateSubmission() override { return true; }
    void PushSamples(const void *data, std::size_t numSamples) override {
        // ImmediateSubmission delivers native DSP samples. GetNativeSampleRate is
        // also used for Azahar's optional time stretcher; it does not resample
        // these direct submissions. Resample explicitly to keep pitch correct.
        const int16_t *samples = static_cast<const int16_t *>(data);
        if (samples == nullptr || numSamples == 0) return;

        // Reuse storage across DSP batches instead of allocating a new vector
        // on every call. This does not change interpolation or sample timing.
        converted_.clear();
        const size_t needed = static_cast<size_t>(numSamples *
            (kOpenEmuPCMRate / kAzaharDSPRate) * 2 + 8);
        if (converted_.capacity() < needed) converted_.reserve(needed);
        constexpr double step = kAzaharDSPRate / kOpenEmuPCMRate;
        for (std::size_t i = 0; i < numSamples; ++i) {
            const std::array<int16_t, 2> current{samples[i * 2], samples[i * 2 + 1]};
            const double currentPosition = static_cast<double>(sourceFramesSeen_++);
            if (!hasPrevious_) {
                previous_ = current;
                hasPrevious_ = true;
            }
            const double previousPosition = currentPosition > 0 ? currentPosition - 1.0 : 0.0;
            while (nextOutputPosition_ <= currentPosition) {
                const double blend = (currentPosition == 0)
                    ? 1.0 : std::clamp(nextOutputPosition_ - previousPosition, 0.0, 1.0);
                for (std::size_t channel = 0; channel < 2; ++channel) {
                    const double value = (1.0 - blend) * previous_[channel] + blend * current[channel];
                    const long rounded = std::lround(value);
                    converted_.push_back(static_cast<int16_t>(std::clamp(rounded, -32768L, 32767L)));
                }
                nextOutputPosition_ += step;
            }
            previous_ = current;
        }
        // The producer and PullAudio agree on interleaved 16-bit stereo samples.
        std::lock_guard<std::mutex> lock(gAudioLock);
        AppendAudioLocked(converted_.data(), converted_.size());
    }

private:
    std::vector<int16_t> converted_;
    bool hasPrevious_ = false;
    std::array<int16_t, 2> previous_{};
    uint64_t sourceFramesSeen_ = 0;
    double nextOutputPosition_ = 0;
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

AzaharHost::Layout gLayout = AzaharHost::Layout::Stacked;
unsigned gScale = 1;
AzaharHost::StereoMode gStereo = AzaharHost::StereoMode::Off;
unsigned gStereoDepth = 100;

/// SBS Full contains two complete eye images, doubling the *output* width.
/// Half SBS and anaglyph keep the same output dimensions as ordinary 2D.
unsigned StereoWidthMultiplier() {
    return gStereo == AzaharHost::StereoMode::SideBySideFull ? 2u : 1u;
}

/// Size of the picture for a layout at 1x. The engine fits its screens into this size.
void LayoutSize(AzaharHost::Layout layout, unsigned *w, unsigned *h) {
    using L = AzaharHost::Layout;
    switch (layout) {
    case L::TopOnly:    *w = Core::kScreenTopWidth;    *h = Core::kScreenTopHeight; break;
    case L::BottomOnly: *w = Core::kScreenBottomWidth; *h = Core::kScreenBottomHeight; break;
    case L::SideBySide: *w = Core::kScreenTopWidth + Core::kScreenBottomWidth; *h = Core::kScreenTopHeight; break;
    case L::LargeTop:   *w = Core::kScreenTopWidth + Core::kScreenTopWidth / 4; *h = Core::kScreenTopHeight; break;
    case L::Stacked:
    default:            *w = Core::kScreenTopWidth; *h = Core::kScreenTopHeight + Core::kScreenBottomHeight; break;
    }
}

void ApplyDisplay(bool running) {
    using L = AzaharHost::Layout;
    {
        const std::string message = "DISPLAY4: ApplyDisplay layoutIndex=" +
            std::to_string(static_cast<unsigned>(gLayout)) + " scale=" +
            std::to_string(gScale) + " stereo=" + std::to_string(static_cast<unsigned>(gStereo)) +
            " depth=" + std::to_string(gStereoDepth) + " running=" + std::to_string(running);
        WriteCoreTrace(message.c_str());
    }
    auto &v = Settings::values;
    switch (gLayout) {
    case L::TopOnly:    v.layout_option = Settings::LayoutOption::SingleScreen; v.swap_screen = false; break;
    case L::BottomOnly: v.layout_option = Settings::LayoutOption::SingleScreen; v.swap_screen = true; break;
    case L::SideBySide: v.layout_option = Settings::LayoutOption::SideScreen; v.swap_screen = false; break;
    case L::LargeTop:   v.layout_option = Settings::LayoutOption::LargeScreen; v.swap_screen = false; break;
    case L::Stacked:
    default:            v.layout_option = Settings::LayoutOption::Default; v.swap_screen = false; break;
    }
    v.resolution_factor = gScale;
    // Let Azahar's existing Vulkan composition produce both eyes, or the red/cyan
    // anaglyph, *before* the final MTLTexture is handed to OpenEmu.
    switch (gStereo) {
    case AzaharHost::StereoMode::SideBySideHalf:
        v.render_3d = Settings::StereoRenderOption::SideBySide; break;
    case AzaharHost::StereoMode::SideBySideFull:
        v.render_3d = Settings::StereoRenderOption::SideBySideFull; break;
    case AzaharHost::StereoMode::Anaglyph:
        v.render_3d = Settings::StereoRenderOption::Anaglyph; break;
    default:
        v.render_3d = Settings::StereoRenderOption::Off; break;
    }
    v.factor_3d = gStereoDepth;
    if (gWindow) {
        unsigned w, h;
        LayoutSize(gLayout, &w, &h);
        // Azahar halves the requested width internally while composing SBS Full,
        // then doubles the final layout width. Supply 2x width so each eye retains
        // its full resolution (e.g. Stacked 1x 800x480, 6x 4800x2880).
        const unsigned framebufferWidth = w * gScale * StereoWidthMultiplier();
        const unsigned framebufferHeight = h * gScale;
        const std::string dimensions = "DISPLAY4: framebuffer request=" +
            std::to_string(framebufferWidth) + "x" + std::to_string(framebufferHeight) +
            " native=" + std::to_string(w) + "x" + std::to_string(h) +
            " stereo=" + std::to_string(static_cast<unsigned>(gStereo));
        WriteCoreTrace(dimensions.c_str());
        gWindow->SetLayoutSize(framebufferWidth, framebufferHeight);
        WriteCoreTrace("DISPLAY1: framebuffer layout updated");
    }
    if (running) {
        WriteCoreTrace("DISPLAY1: before System::ApplySettings");
        Core::System::GetInstance().ApplySettings();
        WriteCoreTrace("DISPLAY1: after System::ApplySettings");
    }
    WriteCoreTrace("DISPLAY1: ApplyDisplay complete");
}

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

void TraceEvent(const char *event) { WriteCoreTrace(event); }

bool Initialize(const Folders &folders, std::string *error) {
    // Set the trace path before the early return so repeated loads can be distinguished.
    gTracePath = folders.userDir + "/3DS-Core-V2-shutdown-trace.log";
    TraceEvent("SESSION: Initialize requested");
    TraceEvent("DIAG4: core-side 32728-to-48000 stereo resampler and audio counters");
    if (gInitialized) {
        TraceEvent("INIT: already initialized");
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
    TraceEvent("INIT: complete");
    (void)error;
    return true;
}

void SetRenderSurface(void *metalLayer) {
    gMetalLayer = metalLayer;
}

bool Load(const std::string &path, std::string *error) {
    TraceEvent("LOAD: enter");
    if (!gInitialized || gMetalLayer == nullptr) {
        if (error) *error = "The Azahar host was not set up.";
        return false;
    }
    gWindow = std::make_unique<OEEmuWindow>(gMetalLayer);
    ApplyDisplay(false);

    auto &system = Core::System::GetInstance();
    system.ApplySettings();
    TraceEvent("LOAD: before engine System::Load");
    const Core::System::ResultStatus result = system.Load(*gWindow, path);
    TraceEvent("LOAD: after engine System::Load");
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
    TraceEvent("LOAD: complete");
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

void SetDisplay(Layout layout, unsigned scale, StereoMode stereo, unsigned depthPercent) {
    gLayout = layout;
    gScale = scale < 1 ? 1 : (scale > 6 ? 6 : scale);
    gStereo = stereo;
    gStereoDepth = std::min(depthPercent, 100u);
    ApplyDisplay(gLoaded);
}

void ExpectedFrameSize(uint32_t *width, uint32_t *height) {
    unsigned w, h;
    LayoutSize(gLayout, &w, &h);
    *width = w * gScale * StereoWidthMultiplier();
    *height = h * gScale;
}

// A state saved while the kernel has asynchronous work in flight would lose that work, so let it
// finish first. Same approach as Azahar's libretro frontend.
static bool DrainAsyncOperations(Core::System &system) {
    if (!system.KernelRunning()) {
        TraceEvent("SAVE: kernel not running; no async drain needed");
        return true;
    }
    const auto start = std::chrono::steady_clock::now();
    const bool hadPending = system.Kernel().AreAsyncOperationsPending();
    if (hadPending) TraceEvent("SAVE: async drain begin");
    bool firstIteration = true;
    while (system.Kernel().AreAsyncOperationsPending()) {
        if (std::chrono::steady_clock::now() - start > std::chrono::seconds(5)) {
            TraceEvent("SAVE: async drain timeout");
            return false;
        }
        if (firstIteration) TraceEvent("SAVE: before first async RunLoop");
        if (system.RunLoop() != Core::System::ResultStatus::Success) {
            TraceEvent("SAVE: async RunLoop failed");
            return false;
        }
        if (firstIteration) TraceEvent("SAVE: after first async RunLoop");
        firstIteration = false;
    }
    TraceEvent("SAVE: async drain complete");
    return true;
}

bool SaveState(const std::string &path, std::string *error) {
    TraceEvent("SAVE: enter engine SaveState");
    auto &system = Core::System::GetInstance();
    if (!gLoaded || !system.IsPoweredOn()) {
        TraceEvent("SAVE: no active game");
        if (error) *error = "No game is running";
        return false;
    }
    TraceEvent("SAVE: before async drain");
    if (!DrainAsyncOperations(system)) {
        TraceEvent("SAVE: async drain failed");
        if (error) *error = "The game was busy and could not be saved right now";
        return false;
    }
    try {
        TraceEvent("SAVE: before engine SaveStateBuffer");
        const std::vector<u8> buffer = system.SaveStateBuffer();
        TraceEvent("SAVE: after engine SaveStateBuffer");
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        out.write(reinterpret_cast<const char *>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        out.close();
        if (!out) {
            TraceEvent("SAVE: could not write state file");
            if (error) *error = "Could not write the state file";
            return false;
        }
        TraceEvent("SAVE: complete");
        return true;
    } catch (const std::exception &e) {
        TraceEvent("SAVE: exception");
        if (error) *error = e.what();
        return false;
    }
}

bool LoadState(const std::string &path, std::string *error) {
    auto &system = Core::System::GetInstance();
    if (!gLoaded || !system.IsPoweredOn()) {
        if (error) *error = "No game is running";
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        if (error) *error = "Could not read the state file";
        return false;
    }
    std::vector<u8> buffer((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (!DrainAsyncOperations(system)) {
        if (error) *error = "The game was busy and could not be loaded right now";
        return false;
    }
    try {
        if (!system.LoadStateBuffer(std::move(buffer))) {
            if (error) *error = "The state does not match this game";
            return false;
        }
        return true;
    } catch (const std::exception &e) {
        if (error) *error = e.what();
        return false;
    }
}

void Reset() {
    if (gLoaded) {
        Core::System::GetInstance().Reset();
    }
}

void Shutdown() {
    TraceEvent("SHUTDOWN: enter host Shutdown");
    if (gLoaded || Core::System::GetInstance().IsPoweredOn()) {
        TraceEvent("SHUTDOWN: before engine System::Shutdown");
        Core::System::GetInstance().Shutdown();
        TraceEvent("SHUTDOWN: after engine System::Shutdown");
    } else {
        TraceEvent("SHUTDOWN: engine not loaded/powered");
    }
    gLoaded = false;
    gFrameTexture = nullptr;
    TraceEvent("SHUTDOWN: before audio queue clear");
    {
        std::lock_guard<std::mutex> lock(gAudioLock);
        gAudioRead = 0;
        gAudioSize = 0;
    }
    TraceEvent("SHUTDOWN: before render-window release");
    gWindow.reset();
    TraceEvent("SHUTDOWN: host Shutdown complete");
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
    if (out == nullptr || maxFrames == 0) return 0;
    std::lock_guard<std::mutex> lock(gAudioLock);
    const size_t frames = std::min(maxFrames, gAudioSize / 2);
    const size_t count = frames * 2;
    const size_t first = std::min(count, kAudioCapacitySamples - gAudioRead);
    std::memcpy(out, gAudio.data() + gAudioRead, first * sizeof(int16_t));
    if (count > first) {
        std::memcpy(out + first, gAudio.data(), (count - first) * sizeof(int16_t));
    }
    gAudioRead = (gAudioRead + count) % kAudioCapacitySamples;
    gAudioSize -= count;
    return frames;
}

} // namespace AzaharHost
