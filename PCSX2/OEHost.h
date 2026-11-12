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
