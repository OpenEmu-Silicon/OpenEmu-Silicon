// SPDX-License-Identifier: GPL-3.0+
//
// OEHost: the OpenEmu side of ARMSX2's Host:: interface, plus the CPU thread that
// runs the virtual machine. Pure C++ so it can be compiled without Objective-C.
// Adapted from ARMSX2's pcsx2-libretro/Main.cpp, which is the template for a host
// that has no windowing, clipboard or file picker.

#pragma once

#include "pcsx2/VMManager.h"

#include <functional>
#include <string>

class INISettingsInterface;

namespace OEHost
{
	/// Where the engine keeps its files. All paths are absolute and need no trailing slash.
	struct Folders
	{
		std::string resources;   ///< Engine resources (fonts, GameIndex). Inside the plugin bundle.
		std::string support;     ///< Data root: inis, cache (including the persisted JIT cache), snapshots.
		std::string bios;        ///< Folder holding the user's BIOS dump.
		std::string memoryCards; ///< Folder for memory cards.
		std::string saveStates;  ///< Folder for save states.
		std::string biosFilename; ///< File name of the BIOS dump inside `bios`. Empty lets the engine choose.
	};

	/// Sets folders, loads or creates the settings file and applies the OpenEmu overrides
	/// (Metal renderer, Null audio backend until item 4, no SDL input).
	/// Call once, before StartCPUThread. Returns false and fills `error` on failure.
	bool Initialize(const Folders& folders, std::string* error);

	/// The view the engine attaches its Metal layer to, and the picture size. Call before
	/// StartCPUThread. The view is an NSView and must stay alive while the engine runs.
	void SetRenderSurface(void* view, u32 width, u32 height);

	/// Called on the CPU thread when the game sets a pad's vibration: pad index (from 0), large
	/// and small motor strength (0 to 1). Set before StartCPUThread.
	void SetVibrationCallback(std::function<void(u32 pad, float large, float small)> callback);

	/// Called on the CPU thread once per emulated frame (every vsync), while the machine runs.
	/// RetroAchievements checks its conditions here. Set before StartCPUThread.
	void SetFrameCallback(std::function<void()> callback);

	/// Called on the CPU thread right after the machine has really been reset, by RequestReset or
	/// any other reset. RetroAchievements resets its state here, so it never checks the old
	/// game's memory after its own reset. Set before StartCPUThread.
	void SetResetCallback(std::function<void()> callback);

	/// Resets the machine. Returns at once; the reset runs on the CPU thread. While the machine
	/// runs, the engine only finishes a reset on the CPU thread's next loop turn, so wait for the
	/// reset callback rather than assuming it is done.
	void RequestReset();

	/// Pauses or resumes the machine on the CPU thread. Use this instead of VMManager::SetState: a
	/// reset asked for while running is only pending until the CPU thread finishes it, and setting
	/// the state directly would cancel it. During a pending reset the new state is applied right
	/// after the reset.
	void SetPaused(bool paused);

	/// Runs exactly one frame while paused, on the CPU thread. Dropped during a pending reset,
	/// which a frame advance would otherwise cancel.
	void FrameAdvance();

	/// Turns RetroAchievements hardcore mode on or off for the engine. The engine keeps its built-in
	/// achievements off, so it asks here instead (PCSX2/patches/0002-openemu-host-hardcore.patch) and
	/// then applies its own hardcore restrictions: no EE underclocking (including auto-tune's
	/// governor), normal frame rates and speed, no cheats or cheat-like patches, no state loading
	/// or frame advance. Safe to call from any thread, before or after StartCPUThread.
	void SetHardcoreMode(bool enabled);

	/// Copies PS2 memory for RetroAchievements, in its memory map: the 32 MB of main RAM,
	/// then the 16 KB scratchpad directly above it. Returns the number of bytes copied, which
	/// is less than `num_bytes` at the end of the map and 0 when no machine is running.
	/// Call on the CPU thread.
	u32 ReadAchievementsMemory(u32 address, u8* buffer, u32 num_bytes);

	/// The base settings layer, for the game core to change values and then call
	/// VMManager::ApplySettings() on the CPU thread. Valid after Initialize().
	INISettingsInterface& Settings();

	/// Starts the CPU thread, which initializes the engine and boots `params`.
	/// `on_boot` runs on the CPU thread once the boot succeeded or failed.
	void StartCPUThread(VMBootParameters params, std::function<void(bool ok, const std::string& error)> on_boot);

	/// Asks the CPU thread to stop the machine and exit, then waits for it. Safe to call twice.
	void StopCPUThread();

	/// Whether the CPU thread is alive.
	bool IsCPUThreadRunning();
} // namespace OEHost

namespace Host
{
	/// Whether OpenEmu's RetroAchievements hardcore mode is on (see OEHost::SetHardcoreMode).
	/// Read by the engine (PCSX2/patches/0002-openemu-host-hardcore.patch); defined in OEHost.cpp.
	bool IsHostHardcoreModeActive();
} // namespace Host
