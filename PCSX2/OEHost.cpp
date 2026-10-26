// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+
//
// OpenEmu host for ARMSX2. See OEHost.h.
//
// The Host:: functions are adapted from pcsx2-libretro/Main.cpp in ARMSX2 at the
// pinned commit. The CPU thread is the same state machine, minus the libretro
// rendering negotiation.

#include "OEHost.h"

#include "common/Console.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include "common/ProgressCallback.h"
#include "common/SmallString.h"
#include "common/Threading.h"
#include "pcsx2/PrecompiledHeader.h"
#include "pcsx2/Achievements.h"
#include "pcsx2/GS.h"
#include "pcsx2/GameList.h"
#include "pcsx2/Host.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/INISettingsInterface.h"
#include "pcsx2/IopThread/OwnerAsserts.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/PerformanceMetrics.h"
#include "pcsx2/SIO/Pad/Pad.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <optional>
#include <thread>

//////////////////////////////////////////////////////////////////////////
// State
//////////////////////////////////////////////////////////////////////////

static std::unique_ptr<INISettingsInterface> s_base_settings;
static std::unique_ptr<INISettingsInterface> s_secrets_settings;

static std::thread s_cpu_thread;
static std::atomic<std::thread::id> s_cpu_thread_id{};
static std::atomic<bool> s_cpu_thread_running{false};
static std::atomic<bool> s_shutdown_requested{false};

// Callbacks queued by Host::RunOnCPUThread, drained by the CPU thread loop and
// by Host::PumpMessagesOnCPUThread every vsync.
static std::mutex s_cpu_queue_lock;
static std::deque<std::function<void()>> s_cpu_queue;
static std::condition_variable s_cpu_queue_cv;

//////////////////////////////////////////////////////////////////////////
// Setup
//////////////////////////////////////////////////////////////////////////

bool OEHost::Initialize(const Folders& folders, std::string* error)
{
	auto fail = [error](const char* message) {
		if (error)
			*error = message;
		return false;
	};

	EmuFolders::AppRoot = folders.resources;
	EmuFolders::Resources = folders.resources;
	EmuFolders::DataRoot = folders.support;
	// Normally derived inside SetDataDirectory(), which this path bypasses because
	// OpenEmu dictates the root. Set it explicitly or the INI lands in the cwd.
	EmuFolders::Settings = Path::Combine(EmuFolders::DataRoot, "inis");
	FileSystem::EnsureDirectoryExists(EmuFolders::DataRoot.c_str(), false);
	FileSystem::EnsureDirectoryExists(EmuFolders::Settings.c_str(), false);

	const char* hw_check_error = nullptr;
	if (!VMManager::PerformEarlyHardwareChecks(&hw_check_error))
	{
		if (error)
			*error = hw_check_error ? hw_check_error : "Early hardware check failed.";
		return false;
	}

	const std::string ini_path = Path::Combine(EmuFolders::Settings, "PCSX2.ini");
	const bool ini_exists = FileSystem::FileExists(ini_path.c_str());
	s_base_settings = std::make_unique<INISettingsInterface>(ini_path);
	Host::Internal::SetBaseSettingsLayer(s_base_settings.get());
	if (!ini_exists || !s_base_settings->Load() || !VMManager::Internal::CheckSettingsVersion())
		VMManager::SetDefaultSettings(*s_base_settings, true, true, true, true, true);

	const std::string secrets_path = Path::Combine(EmuFolders::Settings, "secrets.ini");
	s_secrets_settings = std::make_unique<INISettingsInterface>(secrets_path);
	Host::Internal::SetSecretsSettingsLayer(s_secrets_settings.get());
	if (FileSystem::FileExists(secrets_path.c_str()))
		s_secrets_settings->Load();

	{
		auto lock = Host::GetSettingsLock();
		SettingsInterface& si = *s_base_settings;

		// Folders that OpenEmu owns.
		si.SetStringValue("Folders", "Bios", folders.bios.c_str());
		si.SetStringValue("Folders", "MemoryCards", folders.memoryCards.c_str());
		si.SetStringValue("Folders", "Savestates", folders.saveStates.c_str());
		if (!folders.biosFilename.empty())
			si.SetStringValue("Filenames", "BIOS", folders.biosFilename.c_str());

		// Metal renderer; the picture is copied to OpenEmu's texture (patch 0001).
		// Stretch fills that texture, and OpenEmu applies the 4:3 shape itself.
		si.SetIntValue("EmuCore/GS", "Renderer", static_cast<int>(GSRendererType::Metal));
		si.SetStringValue("EmuCore/GS", "AspectRatio", "Stretch");
		// No SDL input and no audio device. The Null backend keeps the mixed sound in a
		// ring, and the game core pulls it out each frame (PCSX2GameCore executeFrame).
		si.SetBoolValue("InputSources", "SDL", false);
		si.SetStringValue("SPU2/Output", "Backend", "Null");

		// All recompilers on. The persisted VU JIT cache goes under the data root.
		si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
		si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);
		si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
		si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);

		si.SetBoolValue("EmuCore", "EnablePatches", true);
		si.SetBoolValue("EmuCore", "EnableCheats", false);
		si.SetBoolValue("EmuCore", "EnablePerGameSettings", true);
	}

	Error save_error;
	if (!s_base_settings->Save(&save_error))
		Console.ErrorFmt("Failed to save config: {}", save_error.GetDescription());

	VMManager::Internal::LoadStartupSettings();
	return true;
}

INISettingsInterface& OEHost::Settings()
{
	return *s_base_settings;
}

//////////////////////////////////////////////////////////////////////////
// CPU thread
//////////////////////////////////////////////////////////////////////////

static void DrainCPUThreadQueue()
{
	for (;;)
	{
		std::function<void()> fn;
		{
			std::lock_guard<std::mutex> lock(s_cpu_queue_lock);
			if (s_cpu_queue.empty())
				return;
			fn = std::move(s_cpu_queue.front());
			s_cpu_queue.pop_front();
		}
		fn();
	}
}

static void CPUThreadMain(VMBootParameters initial_params, std::function<void(bool, const std::string&)> on_boot)
{
	Threading::SetNameOfCurrentThread("CPU Thread");
	s_cpu_thread_id.store(std::this_thread::get_id(), std::memory_order_release);
	s_cpu_thread_running.store(true, std::memory_order_release);

	if (!VMManager::Internal::CPUThreadInitialize())
	{
		Console.Error("CPU thread init failed.");
		VMManager::Internal::CPUThreadShutdown();
		s_cpu_thread_running.store(false, std::memory_order_release);
		if (on_boot)
			on_boot(false, "The engine could not start its CPU thread.");
		return;
	}

	VMManager::ApplySettings();

	std::optional<VMBootParameters> pending_boot = std::move(initial_params);

	while (!s_shutdown_requested.load(std::memory_order_acquire))
	{
		DrainCPUThreadQueue();

		const VMState state = VMManager::GetState();
		switch (state)
		{
			case VMState::Initializing:
				continue;

			case VMState::Running:
				VMManager::Execute();
				continue;

			case VMState::Resetting:
				VMManager::Reset();
				continue;

			case VMState::Stopping:
				VMManager::Shutdown(false);
				continue;

			case VMState::Paused:
			case VMState::Shutdown:
			{
				if (pending_boot.has_value())
				{
					VMBootParameters bp = std::move(pending_boot.value());
					pending_boot.reset();
					Error boot_error;
					const VMBootResult result = VMManager::Initialize(bp, &boot_error);
					if (result != VMBootResult::StartupSuccess)
					{
						Console.ErrorFmt("VMManager::Initialize failed (result {}): {}", static_cast<int>(result),
							boot_error.GetDescription());
						if (on_boot)
							on_boot(false, boot_error.GetDescription());
						s_shutdown_requested.store(true, std::memory_order_release);
						break;
					}
					VMManager::SetState(VMState::Running);
					if (on_boot)
						on_boot(true, std::string());
					continue;
				}

				if (state == VMState::Shutdown)
				{
					// The game ended on its own. Nothing more to run.
					s_shutdown_requested.store(true, std::memory_order_release);
					break;
				}

				// Paused: wait for queued work (resume, save state) or a short timeout.
				std::unique_lock<std::mutex> lock(s_cpu_queue_lock);
				s_cpu_queue_cv.wait_for(lock, std::chrono::milliseconds(16), []() { return !s_cpu_queue.empty(); });
				continue;
			}

			default:
				continue;
		}
	}

	if (VMManager::HasValidVM())
		VMManager::Shutdown(false);
	VMManager::Internal::CPUThreadShutdown();
	s_cpu_thread_running.store(false, std::memory_order_release);
}

void OEHost::StartCPUThread(VMBootParameters params, std::function<void(bool, const std::string&)> on_boot)
{
	if (s_cpu_thread.joinable())
		return;
	s_shutdown_requested.store(false, std::memory_order_release);
	s_cpu_thread = std::thread(CPUThreadMain, std::move(params), std::move(on_boot));
}

void OEHost::StopCPUThread()
{
	s_shutdown_requested.store(true, std::memory_order_release);
	s_cpu_queue_cv.notify_all();
	if (s_cpu_thread.joinable())
		s_cpu_thread.join();
}

bool OEHost::IsCPUThreadRunning()
{
	return s_cpu_thread_running.load(std::memory_order_acquire);
}

//////////////////////////////////////////////////////////////////////////
// Host:: callbacks
//////////////////////////////////////////////////////////////////////////

void Host::CommitBaseSettingChanges()
{
	if (!s_base_settings)
		return;
	Error err;
	if (!s_base_settings->Save(&err))
		Console.ErrorFmt("Failed to save settings: {}", err.GetDescription());
}

void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock)
{
}

void Host::CheckForSettingsChanges(const Pcsx2Config& old_config)
{
}

bool Host::RequestResetSettings(bool folders, bool core, bool controllers, bool hotkeys, bool ui)
{
	return false;
}

void Host::SetDefaultUISettings(SettingsInterface& si)
{
	si.SetBoolValue("UI", "StartBigPictureMode", false);
}

bool Host::LocaleCircleConfirm()
{
	return false;
}

std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback()
{
	return ProgressCallback::CreateNullProgressCallback();
}

void Host::ReportInfoAsync(const std::string_view title, const std::string_view message)
{
	if (!title.empty() && !message.empty())
		INFO_LOG("{}: {}", title, message);
	else if (!message.empty())
		INFO_LOG("{}", message);
}

void Host::ReportErrorAsync(const std::string_view title, const std::string_view message)
{
	if (!title.empty() && !message.empty())
		ERROR_LOG("{}: {}", title, message);
	else if (!message.empty())
		ERROR_LOG("{}", message);
}

void Host::OpenURL(const std::string_view url)
{
}

bool Host::CopyTextToClipboard(const std::string_view text)
{
	return false;
}

std::string Host::GetTextFromClipboard()
{
	return std::string();
}

void Host::BeginTextInput()
{
}

void Host::EndTextInput()
{
}

static std::atomic<void*> s_render_view{nullptr};
static std::atomic<u32> s_render_width{640};
static std::atomic<u32> s_render_height{448};

void OEHost::SetRenderSurface(void* view, u32 width, u32 height)
{
	s_render_width = width;
	s_render_height = height;
	s_render_view = view;
}

static std::optional<WindowInfo> BuildWindowInfo()
{
	// The engine needs a view to attach its Metal layer to, even though the picture
	// goes to OpenEmu's texture instead (see the patch). Without a view it stays
	// surfaceless and skips every frame.
	WindowInfo wi;
	void* view = s_render_view.load();
	wi.type = view ? WindowInfo::Type::MacOS : WindowInfo::Type::Surfaceless;
	wi.window_handle = view;
	wi.surface_width = s_render_width;
	wi.surface_height = s_render_height;
	wi.surface_scale = 1.0f;
	return wi;
}

std::optional<WindowInfo> Host::GetTopLevelWindowInfo()
{
	return BuildWindowInfo();
}

void Host::OnInputDeviceConnected(const std::string_view identifier, const std::string_view device_name)
{
}

void Host::OnInputDeviceDisconnected(const InputBindingKey key, const std::string_view identifier)
{
}

void Host::SetMouseMode(bool relative_mode, bool hide_cursor)
{
}

void Host::SetMouseLock(bool state)
{
}

void Host::SetPadVibration(u32 pad_index, float large_or_single_motor_intensity, float small_motor_intensity)
{
	// Item 5 forwards this to OpenEmu's rumble.
}

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window)
{
	return BuildWindowInfo();
}

void Host::ReleaseRenderWindow()
{
}

void Host::BeginPresentFrame()
{
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
}

void Host::OnVMStarting()
{
}

void Host::OnVMStarted()
{
}

void Host::OnVMDestroyed()
{
}

void Host::OnVMPaused()
{
}

void Host::OnVMResumed()
{
}

void Host::OnGameChanged(const std::string& title, const std::string& elf_override, const std::string& disc_path,
	const std::string& disc_serial, u32 disc_crc, u32 current_crc)
{
	if (!title.empty())
		INFO_LOG("Game changed: {} (serial {}, CRC {:08X})", title, disc_serial, current_crc);
}

void Host::OnPerformanceMetricsUpdated()
{
}

void Host::OnSaveStateLoading(const std::string_view filename)
{
}

void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful)
{
}

void Host::OnSaveStateSaved(const std::string_view filename)
{
}

void Host::PumpMessagesOnCPUThread()
{
	if (s_shutdown_requested.load(std::memory_order_acquire) && VMManager::HasValidVM())
		VMManager::SetState(VMState::Stopping);

	DrainCPUThreadQueue();
}

void Host::RunOnCPUThread(std::function<void()> function, bool block)
{
	BLOCKING_HOST_CALL_ASSERT(block);
	if (block)
	{
		if (s_cpu_thread_id.load(std::memory_order_acquire) == std::this_thread::get_id())
		{
			function();
			return;
		}

		std::mutex done_lock;
		std::condition_variable done_cv;
		bool done = false;
		auto wrapped = [&function, &done_lock, &done_cv, &done]() {
			function();
			std::lock_guard<std::mutex> lk(done_lock);
			done = true;
			done_cv.notify_all();
		};
		{
			std::lock_guard<std::mutex> lock(s_cpu_queue_lock);
			s_cpu_queue.emplace_back(std::move(wrapped));
		}
		s_cpu_queue_cv.notify_all();
		std::unique_lock<std::mutex> lk(done_lock);
		done_cv.wait(lk, [&done]() { return done; });
		return;
	}

	{
		std::lock_guard<std::mutex> lock(s_cpu_queue_lock);
		s_cpu_queue.emplace_back(std::move(function));
	}
	s_cpu_queue_cv.notify_all();
}

// The MTGS ring has a single producer, so a caller that is not the CPU thread has
// to arrive through it. The CPU thread drains this queue every vsync.
void Host::RunOnGSThread(std::function<void()> function)
{
	RunOnCPUThread([fn = std::move(function)]() {
		if (MTGS::IsOpen())
			MTGS::RunOnGSThread(std::move(fn));
	});
}

void Host::RefreshGameListAsync(bool invalidate_cache)
{
}

void Host::CancelGameListRefresh()
{
}

bool Host::IsFullscreen()
{
	return true;
}

void Host::SetFullscreen(bool enabled)
{
}

void Host::RequestExitApplication(bool allow_confirm)
{
	s_shutdown_requested.store(true, std::memory_order_release);
	if (VMManager::HasValidVM())
		VMManager::SetState(VMState::Stopping);
}

void Host::RequestExitBigPicture()
{
}

void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state)
{
	VMManager::SetState(VMState::Stopping);
}

void Host::OnAchievementsLoginSuccess(const char* username, u32 points, u32 sc_points, u32 unread_messages)
{
}

void Host::OnAchievementsLoginRequested(Achievements::LoginRequestReason reason)
{
}

void Host::OnAchievementsHardcoreModeChanged(bool enabled)
{
}

bool Host::HasNativeAchievementNotifications()
{
	return false;
}

void Host::OnAchievementNotification(const char*, float, const char*, const char*, const char*)
{
}

void Host::OnAchievementsRefreshed()
{
}

void Host::OnCoverDownloaderOpenRequested()
{
}

void Host::OnCreateMemoryCardOpenRequested()
{
}

bool Host::InBatchMode()
{
	return true;
}

bool Host::InNoGUIMode()
{
	return true;
}

bool Host::ShouldPreferHostFileSelector()
{
	return false;
}

void Host::OpenHostFileSelectorAsync(std::string_view title, bool select_directory, FileSelectorCallback callback,
	FileSelectorFilters filters, std::string_view initial_directory)
{
	callback(std::string());
}

int Host::LocaleSensitiveCompare(std::string_view lhs, std::string_view rhs)
{
	const int res = std::strncmp(lhs.data(), rhs.data(), std::min(lhs.size(), rhs.size()));
	if (res != 0)
		return res;
	return lhs.size() > rhs.size() ? 1 : (lhs.size() < rhs.size() ? -1 : 0);
}

s32 Host::Internal::GetTranslatedStringImpl(
	const std::string_view context, const std::string_view msg, char* tbuf, size_t tbuf_space)
{
	if (msg.size() > tbuf_space)
		return -1;
	if (msg.empty())
		return 0;

	std::memcpy(tbuf, msg.data(), msg.size());
	return static_cast<s32>(msg.size());
}

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
	TinyString count_str = TinyString::from_format("{}", count);

	std::string ret(msg);
	for (;;)
	{
		std::string::size_type pos = ret.find("%n");
		if (pos == std::string::npos)
			break;
		ret.replace(pos, 2, count_str.view());
	}
	return ret;
}

std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view str)
{
	return std::nullopt;
}

std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code)
{
	return std::nullopt;
}

const char* InputManager::ConvertHostKeyboardCodeToIcon(u32 code)
{
	return nullptr;
}

BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()
