# VICE-Core Native C64 Investigation

_Last updated: 2026-05-18_

Issue: [#542 — Commodore 64 — investigate native VICE-Core integration](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/542)

Supporting evidence:

- `docs/core-audit/vice-local-c64-context.md` — local C64 system/plugin context.
- `docs/core-audit/vice-upstream-research.md` — upstream VICE-Core research notes.

## Summary

`OpenEmu/VICE-Core` is a real native OpenEmu core candidate for Commodore 64, but it is not release-ready as-is.

The good news: the vendored VICE 3.4 headless library can be configured and built on this Apple Silicon machine with CMake, producing `liboex64sc.dylib` for the OpenEmu wrapper path.

The bad news: the Xcode plugin project is still old OpenEmu-era infrastructure. It is x86_64-only, points at old upstream appcast URLs, uses legacy framework paths, and has some unfinished keyboard/modifier handling. Integrating it into OpenEmu-Silicon should be treated as a real porting project, not a simple submodule restore.

## Upstream repository facts

Repository: `https://github.com/OpenEmu/VICE-Core`

Observed repo shape:

- `VICE.xcodeproj` — standalone OpenEmu core plugin project.
- `Info.plist` — OpenEmu core plugin metadata.
- `Core/Classes/ViceGameCore.h`
- `Core/Classes/ViceGameCore.m`
- `deps/vice/` — vendored VICE source with an OpenEmu `oeheadless` arch layer.

Upstream metadata checked through GitHub API:

| Repo | Description | Last pushed | Notes |
|---|---|---:|---|
| `OpenEmu/VICE-Core` | `OpenEmu Core plugin for VICE *WIP - not working*` | 2023-03-31 | Best native C64 lead despite WIP status. |
| `OpenEmu/VirtualC64-Core` | `OpenEmu Core plugin with VirtualC64 to support C64 emulation *WIP - not working*` | 2020-03-02 | Older, lower-priority fallback/reference only. |

## What VICE-Core supports

`Info.plist` registers one OpenEmu system:

```text
OESystemIdentifiers = [ openemu.system.c64 ]
OEGameCoreClass = ViceGameCore
OEGameCorePlayerCount = 2
CFBundleVersion = 3.4
```

The README identifies the core as:

```text
OpenEmu Core plugin for VICE 3.4
```

This is a C64/x64sc-oriented wrapper, not a broad “all VICE machines” integration. Do not assume VIC-20, C128, PET, Plus/4, etc. come along for free.

## Build findings

### 1. Headless VICE library builds on Apple Silicon

From a fresh clone of `OpenEmu/VICE-Core`, this configure command succeeded:

```bash
cd deps/vice
cmake -B cmake-build-test \
  -DUSE_OEHEADLESS=YES \
  -DUSE_ALT_CPU=YES \
  -DCMAKE_BUILD_TYPE=RELEASE
```

This build command also succeeded on Apple Silicon:

```bash
cmake --build cmake-build-test --target oex64sc --config Release -- -j4
```

Result:

```text
[100%] Linking CXX shared library liboex64sc.dylib
Copying library
[100%] Built target oex64sc
```

This is the strongest positive signal from the investigation. The emulator-side headless library is not obviously blocked by arm64 compilation.

### 2. The Xcode plugin project is not Apple Silicon-ready

`VICE.xcodeproj` has these relevant settings:

```text
ARCHS = x86_64
VALID_ARCHS = x86_64
MACOSX_DEPLOYMENT_TARGET = 10.14.4
PRODUCT_BUNDLE_IDENTIFIER = org.openemu.${PRODUCT_NAME:identifier}
SUFeedURL = https://raw.github.com/OpenEmu/OpenEmu-Update/master/vice_appcast.xml
```

An arm64 Xcode build attempt failed before compilation because the project only offered x86_64 macOS destinations:

```text
xcodebuild: error: Unable to find a destination matching the provided destination specifier:
        { platform:macOS, arch:arm64 }

Available destinations for the "VICE" scheme:
        { platform:macOS, arch:x86_64, ... }
        { platform:macOS, name:Any Mac }
```

That is fixable, but it confirms this is not drop-in ready.

### 3. The Xcode project has old local framework assumptions

The project references OpenEmu frameworks through old relative/DerivedData-style paths, including:

```text
../OpenEmu-SDK/build/Debug/OpenEmuBase.framework
../../Library/Developer/Xcode/DerivedData/OpenEmu-.../OpenEmuBase.framework
../../Library/Developer/Xcode/DerivedData/OpenEmu-.../OpenEmuSystem.framework
```

OpenEmu-Silicon integration should replace these with the current workspace/framework pattern used by the active core projects.

## Local OpenEmu-Silicon C64 context

The app already has a C64 system plugin:

```text
OpenEmu/SystemPlugins/Commodore 64/
```

Important files:

- `Commodore 64-Info.plist`
- `OEC64SystemResponderClient.h`
- `OEC64SystemResponder.m`
- `Controller-Mappings.plist`
- `Keyboard-Mappings.plist`

The local system identifier is:

```text
openemu.system.c64
```

Accepted file suffixes include:

```text
crt, d64, d71, d81, g64, p00, p64, prg, t64, tap, x64
```

There is currently no native C64 release metadata:

- no `VICE/` or `VICE-Core/` local source directory;
- no VICE project in `OpenEmu-metal.xcworkspace`;
- no `Appcasts/vice.xml`;
- no VICE entry in `oecores.xml`.

There is no C64 core at all: RetroArch core support was removed in v1.4.0, and no native VICE source tree has been ported yet (#546).

## Input and runtime risks

The local C64 responder contract expects a native core to implement `OEC64SystemResponderClient`:

- raw keyboard key down/up via `keyDown:` / `keyUp:`;
- joystick buttons via `didPushC64Button:forPlayer:` / `didReleaseC64Button:forPlayer:`;
- joystick port swapping via `swapJoysticks`;
- mouse movement and left/right mouse events.

`VICE-Core` already implements this protocol, which is good.

However, the implementation has unfinished keyboard/modifier handling:

```objc
// TODO: Fix flags, which will be sent as virtual key codes
KeyboardMod mod = flagsToMod(0);
```

The code also logs every key event:

```objc
NSLog(@"keyDown: code=%03d, flags=%08x, mod=%08lx", ...)
NSLog(@"keyUp: code=%03d, flags=%08x, mod=%08lx", ...)
```

That should be removed or gated before shipping.

Because C64 is keyboard-heavy, keyboard fidelity is likely the highest-risk runtime area. This is also relevant to the C64 keyboard crash reports filed against the removed RetroArch/VICE path (#390), which a native port needs to avoid repeating.

## Release/update requirements if ported

A native VICE core would need the same release plumbing as other shipped cores:

1. Top-level source directory, likely `VICE/` or `VICE-Core/`.
2. Workspace entry in `OpenEmu-metal.xcworkspace`.
3. Shared scheme following the active core pattern.
4. Core `Info.plist` with:
   - `OESystemIdentifiers = [ openemu.system.c64 ]`
   - `OEGameCoreClass = ViceGameCore`
   - `OEGameCorePlayerCount = 2`
   - `SUFeedURL = https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/vice.xml`
5. `Appcasts/vice.xml`.
6. `oecores.xml` entry.
7. `Scripts/install-core.sh` / `Scripts/package-core.sh` compatibility.
8. Runtime validation with C64 cartridge, disk, tape, and PRG samples if possible.

Do **not** revive the old in-tree `VICE-Bridge/` libretro binary pattern. Those bridge directories were testing-only and removed, as was the libretro bridge itself in v1.4.0.

## Recommendation

Proceed to a focused native VICE-Core port issue.

This is viable enough to continue because:

- the upstream OpenEmu wrapper exists;
- it already targets `openemu.system.c64`;
- it implements the local C64 responder protocol;
- the VICE 3.4 OpenEmu headless library built successfully on Apple Silicon with CMake.

But treat it as a real port because:

- upstream marks it WIP/not working;
- the Xcode target is x86_64-only;
- framework paths and release URLs are stale;
- keyboard/modifier handling is unfinished;
- it has no current OpenEmu-Silicon workspace, appcast, or updater integration.

Suggested next implementation issue:

> Commodore 64 — port native VICE-Core to Apple Silicon

Initial acceptance criteria should be:

- [ ] Import `OpenEmu/VICE-Core` into a top-level repo directory without reintroducing submodules.
- [ ] Build `liboex64sc.dylib` for arm64 from `deps/vice` as part of a documented/reproducible process.
- [ ] Modernize the Xcode project for `OpenEmu-metal.xcworkspace`, current SDK framework paths, and arm64 macOS.
- [ ] Update `Info.plist` to the local appcast URL pattern.
- [ ] Build `VICE.oecoreplugin` for Apple Silicon.
- [ ] Install with `./Scripts/install-core.sh VICE` or equivalent once script support exists.
- [ ] Boot at least one `.d64` and one `.prg` sample.
- [ ] Verify keyboard input does not crash and basic typing works.
- [ ] Verify joystick input and joystick port swap.
- [ ] Verify audio/video timing for NTSC and PAL display modes.
- [ ] Only after runtime validation, add `Appcasts/vice.xml` and `oecores.xml` entry.
