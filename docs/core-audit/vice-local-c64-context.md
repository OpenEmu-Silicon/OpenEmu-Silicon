# Code Context

## Files Retrieved
1. `OpenEmu/SystemPlugins/Commodore 64/Commodore 64-Info.plist` (lines 1-126) - C64 system plugin metadata: UI system ID, supported file extensions, controls, responder class.
2. `OpenEmu/SystemPlugins/Commodore 64/OEC64SystemResponderClient.h` (lines 1-51) - local C64 core-facing input protocol and button enum.
3. `OpenEmu/SystemPlugins/Commodore 64/OEC64SystemResponder.m` (lines 1-76) - how OpenEmu forwards keyboard, joystick, and mouse events to a C64 core.
4. `OpenEmu/SystemPlugins/Commodore 64/OEC64SystemController.m` (lines 1-44) - permissive file acceptance and system icon lookup.
5. `OpenEmu/SystemPlugins/Commodore 64/Controller-Mappings.plist` (lines 1-290) - default controller mappings for C64 controls.
6. `OpenEmu/SystemPlugins/Commodore 64/Controller-Preferences.plist` (lines 1-29) - controller UI uses generic computer artwork and placeholder `{0, 0}` key positions.
7. `OpenEmu/SystemPlugins/Commodore 64/Keyboard-Mappings.plist` (lines 1-5) - empty keyboard mapping file.
8. `docs/core-audit/core-support-audit.md` (lines 1-224) - current audit state for C64 and native VICE-Core recommendation.
9. `docs/core-audit/local-inventory.md` (lines 1-84) - local inventory noting C64 as system-plugin-only with no source/workspace/appcast.
10. `.gitmodules` (lines 1-96) - stale historical C64 entries for Frodo-Core and VirtualC64-Core; no VICE-Core entry.
11. `oecores.xml` (lines 1-343) - downloadable core registry; contains no C64/VICE/Frodo/VirtualC64 entry.
12. `Appcasts/` listing - no VICE/Frodo/VirtualC64 appcast file exists; appcasts are only for current native cores.
13. `OpenEmu-metal.xcworkspace/contents.xcworkspacedata` (lines 1-97) - workspace project list; no VICE/Frodo/VirtualC64 project reference.
14. `OpenEmu/OpenEmu.xcodeproj/project.pbxproj` (grep around lines 351, 361, 1479-1483, 2656, 3323-3339, 4202) - C64 system plugin is wired into app build, but only as a system plugin.
15. `Scripts/check-core-feed-urls.sh` (lines 1-89) - any future native core plist with `OEGameCoreClass` must include a valid local `SUFeedURL`.
16. `Scripts/package-core.sh` (lines 1-125), `Scripts/install-core.sh` (lines 1-140), `Scripts/update_core_appcast.py` (lines 1-180) - native-core release/install mechanics and appcast version/signing checks.
17. `README.md` (lines 50-59) and root `appcast.xml` (grep lines 141-143, 176, 310-312) - public release notes from before v1.4.0 describe C64 working via VICE-libretro; that path has since been removed.

## Key Code

### C64 system plugin exists
`Commodore 64-Info.plist` defines the UI/system layer only:

```xml
<key>OESystemIdentifier</key>
<string>openemu.system.c64</string>
<key>OESystemName</key>
<string>Commodore 64</string>
<key>OESystemType</key>
<string>OESystemTypeComputer</string>
```

It accepts C64 media suffixes `crt`, `d64`, `d71`, `d81`, `g64`, `p00`, `p64`, `prg`, `t64`, `tap`, `x64` and declares two players, computer/cartridge/cassette/floppy media, and responder class `OEC64SystemResponder`.

### Local responder/input shape
`OEC64SystemResponderClient.h` defines the core-facing enum/protocol:

```objc
typedef enum
{
    OEC64JoystickUp,
    OEC64JoystickDown,
    OEC64JoystickLeft,
    OEC64JoystickRight,
    OEC64ButtonFire,
    OEC64ButtonJump,
    OEC64SwapJoysticks,
    OEC64ButtonCount
} OEC64Button;

@protocol OEC64SystemResponderClient <OESystemResponderClient, NSObject>
- (oneway void)mouseMovedAtPoint:(OEIntPoint)point;
- (oneway void)leftMouseDownAtPoint:(OEIntPoint)point;
- (oneway void)leftMouseUp;
- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point;
- (oneway void)rightMouseUp;
- (oneway void)keyDown:(NSUInteger)keyCode;
- (oneway void)keyUp:(NSUInteger)keyCode;
- (oneway void)didPushC64Button:(OEC64Button)button forPlayer:(NSUInteger)player;
- (oneway void)didReleaseC64Button:(OEC64Button)button forPlayer:(NSUInteger)player;
- (oneway void)swapJoysticks;
@end
```

`OEC64SystemResponder.m` forwards:
- raw `OEHIDEvent.keycode` through `keyDown:` / `keyUp:`
- mapped controls through `didPushC64Button:forPlayer:` / `didReleaseC64Button:forPlayer:`
- `OEC64SwapJoysticks` as a separate command
- mouse movement and left/right button events

`Keyboard-Mappings.plist` is empty, so a future native VICE core should expect raw keyboard keycodes from the responder rather than a populated OE keyboard mapping table.

### Current support path: none

RetroArch core support was removed in v1.4.0. Until a native VICE core lands (#546),
Commodore 64 ships as a system plugin with no core, the same as PlayStation 2 and
Sega VMU: the system appears in the library and its controls are configurable, but
no core is available to run a game.

### Release metadata absence
Confirmed absent locally:
- no `VICE/`, `VICE-Core/`, `Frodo-Core/`, or `VirtualC64-Core/` directory from `find`
- no `VICE`/`Frodo`/`VirtualC64` project in `OpenEmu-metal.xcworkspace/contents.xcworkspacedata`
- no `openemu.system.c64`, VICE, Frodo, or VirtualC64 entry in `oecores.xml`
- no `Appcasts/vice.xml`, `Appcasts/frodo.xml`, or `Appcasts/virtualc64.xml`

`.gitmodules` still lists stale historical upstream C64 candidates:

```ini
[submodule "Frodo-Core"]
	path = Frodo-Core
	url = ../../OpenEmu/Frodo-Core.git
[submodule "VirtualC64-Core"]
	path = VirtualC64-Core
	url = ../../OpenEmu/VirtualC64-Core.git
```

There is no `.gitmodules` entry for `VICE-Core`.

## Architecture

OpenEmu separates:
1. **System plugin** (`OpenEmu/SystemPlugins/Commodore 64`) - makes C64 visible in the UI and defines controls/file types.
2. **Native core plugin** (missing for C64) - would subclass `OEGameCore`, implement `OEC64SystemResponderClient`, ship as `<Core>.oecoreplugin`, and carry `Info.plist` metadata including `OEGameCoreClass`, `OESystemIdentifiers`, and `SUFeedURL`.
3. **Updater/install metadata** (missing for C64 native) - native cores need `oecores.xml` registry entry plus matching `Appcasts/<core>.xml` and per-core `SUFeedURL`.
4. **Core** (missing entirely) - RetroArch core support was removed in v1.4.0, so there is no interim path. A native port is the only route (#546).

Do not reintroduce in-tree libretro binaries or a per-core bridge directory. A native VICE core should be a real source tree like every other core this fork ships.

## Integration constraints for future native VICE-Core

- A native VICE core should be a real top-level source tree/project, not a bundled libretro dylib or revived `VICE-Bridge/`.
- It must implement `OEC64SystemResponderClient` exactly, including raw keycodes, two-player C64 buttons, joystick swapping, and mouse events.
- It must register `openemu.system.c64` in its core `Info.plist` (`OESystemIdentifiers`) and provide `OEGameCorePlayerCount` compatible with two players.
- It needs release metadata before users can download/update it: `oecores.xml` entry, `Appcasts/vice.xml` (or chosen core name), and a `SUFeedURL` in the core plist pointing at `https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/<core>.xml`.
- `Scripts/check-core-feed-urls.sh` will fail if a native core plist has `OEGameCoreClass` but no `SUFeedURL`, or if the feed URL points to a missing Appcasts file.
- Release packaging assumes a build product named `<CoreName>.oecoreplugin` in DerivedData and validates `CFBundleVersion`; appcast updates can enforce zip version match and Sparkle EdDSA signing.
- Workspace/project wiring is required (`OpenEmu-metal.xcworkspace` and likely Xcode schemes). Current workspace has no VICE/Frodo/VirtualC64 project.
- C64 has computer-style input beyond simple gamepad controls; keyboard model and any VICE runtime/ROM needs need investigation in upstream `OpenEmu/VICE-Core` before issue #542 can become an implementation PR.

## Start Here

Open `OpenEmu/SystemPlugins/Commodore 64/OEC64SystemResponderClient.h` first. It is the contract a future native VICE-Core must satisfy; then compare upstream `OpenEmu/VICE-Core` against this protocol and the release metadata requirements above.
