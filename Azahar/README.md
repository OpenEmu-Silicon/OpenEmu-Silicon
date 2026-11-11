## v220 / v24 — release handoff and evidence preparation

**Functional code freeze:** Core v219 / System Plugin v23 compiled and worked
in OpenEmu on the tested Xcode 27.2 Mac. The v219 diagnostic session contained
1,280 hardware frames, zero GPU readback/copy/pitch failures, successful
save-state writing, and clean teardown. The System Plugin produced no Xcode
warnings; the Core still displayed a nonfatal upstream duplicate-static-library
linker warning and a generic recommended-settings notice. These are not
proof of a clean independent build.

**This update changes no emulation behavior.** v220/v24 adds the read-only
`tools/workspace-report.py` report, `DEPENDENCY_REVIEW.md` (license evidence
and unresolved rights/provenance questions) and updated handoff instructions.
No framebuffer/Metal/Vulkan, input, controller artwork, shader, save, audio,
patching, dependency binaries or Xcode build phases were changed. v220/v24
still require a Mac build and validation before being accepted.

From the Core folder, run `python3 tools/workspace-report.py` to see whether
your *real* upstream folders are Git checkouts. This prints a sanitized JSON
report without local absolute paths, remote URLs, or user names. If revisions
are available, use `tools/source-lock.py capture/verify`; if not, preserve the
working trees and report the missing provenance. Read `RELEASE_READINESS.md`
and `DEPENDENCY_REVIEW.md` before publishing anything.

## Release-candidate build-warning cleanup (v219/v23)

**v219/v23 update:** Xcode header-map settings have been modernized, the System
Plugin explicitly rechecks OpenEmu Swift frameworks on each build, and the
Core no longer declares itself to be an `OEAudioBuffer`. Only historical
v106–v108 constant-zero Vulkan safety-gate warnings are locally suppressed;
those safety gates and the live renderer are unchanged. The Azahar upstream
static-library duplicate warning and Xcode's App Intents metadata notice are
unmodified and documented for future upstream/toolchain review. The v218/v22
pair successfully compiled and ran on the user's Mac; the subsequent
v219/v23 pair also compiled and ran successfully, with a clean 1,280-frame
Core session. The new v220/v24 pair still needs native Mac testing.


See [`RELEASE_READINESS.md`](RELEASE_READINESS.md) for source locking,
third-party artifact inventory and the macOS fresh-build checklist.
Run `python3 tools/release-gate.py` for a **read-only** readiness report;
PENDING gates are expected until real Git pins, fresh Xcode compilation,
and maintainer/license approval. Working runtime code remains unchanged.
Paired project: System Plugin v24.

# 3DS-Azahar-Core for OpenEmu

**Core version:** v220 · **Platform:** Apple Silicon macOS · **Rendering:** Azahar Vulkan through MoltenVK → stock OpenEmu bitmap renderer.

An experimental, source-distributed Nintendo 3DS emulation core for OpenEmu. It is designed to work with the separate **3DS-System-Plugin v24**. OpenEmu.app itself does not need modification.

## What is working

- Real Azahar Vulkan hardware rendering, controlled through a guarded libretro frontend and MoltenVK.
- User-verified high-resolution 2D and Side-by-Side Full images in windowed and fullscreen OpenEmu. **Known limitation:** Fullscreen Scale 1x may enlarge at 2x+ internal resolution (see below).
- Original-size **windowed** game geometry at OpenEmu Scale 1x, even when physical Retina pixels are presented; fullscreen Scale 1x is a host-size limitation under investigation.
- Resolution options **1x through 6x**, stereo Off / Side-by-Side Half / Side-by-Side Full / Anaglyph, and stereo depth from 10% to 100%.
- Automatic output: 1x internal shows native visible pixels; 2x–6x internal uses **2x physical output**. There is no manual physical-resolution menu.
- Gameplay, controls, audio, OpenEmu shaders, and game restarts. In-game save-directory availability is logged; in-game saving and OpenEmu disk-icon state restoration were manually verified in earlier Mac sessions; broader game compatibility remains unverified.

**Limits:** The v218/v22 pair compiled on the user's Apple Silicon Mac using Xcode 27.2 and passed a gameplay smoke test, with zero GPU/copy/pitch failures in the recorded v218 session. Bluetooth input and save-state restoration were separately confirmed on v217/v21. The v219/v23 pair then passed a Mac build/gameplay test, and the new v220/v24 candidate is source-tested only; cross-game compatibility and a clean independent checkout remain pending. 7x and 8x were removed because earlier Mac tests found little visible improvement and poor performance at 8x.

## Architecture for code reviewers

```text
3DS-System-Plugin v24  ──(OpenEmu control IDs)──► AzaharGameCore.mm
                                                    │
OpenEmu OEGameCore ◄──(native window geometry)─────┤
                                                    │ libretro environment/options
                       azahar_libretro.dylib ◄───────┤
                              │                     │
                              └── Vulkan/MoltenVK ──┤ readback of genuine game frames
                                                    │
                                  compact BGRA frame│
                                        ↓           │
                          pitched fixed-2x bitmap ─┘
                                        ↓
                          OpenEmu's existing bitmap renderer
```

**The critical Retina/window workaround:** At game initialization the core reserves the largest 2x bitmap and locks the host row pitch. It initially reports a native-sized `screenRect`, allowing OpenEmu's window controller to choose its traditional window size. After 180 delivered frames, it can publish the 2x visible `screenRect` without reallocating the bitmap or changing its pointer. The host uses `bufferSize` for physical pitch and `screenRect` for visible texture size; each compact frame is copied row-by-row into the padded host buffer. This design was confirmed by Mac testing in v208 and audited in v209 and v210. Relevant source: `Az197LockSessionGeometry`, `Az208AdvanceScreenRect`, `Az208CopyRowsToHost`, `Az209AuditHostPitch`.

**Fullscreen Scale 1x known issue (v214 audit, not yet fixed):** The tested OpenEmu source (`OpenEmu/GameViewController.swift`, `OpenEmu/GameWindowController.swift`) computes `defaultScreenSize` from the core-visible `screenRect` and then multiplies it by the fullscreen integral scaling selection. Once the core exposes real 2x Retina pixels, fullscreen Scale 1x can therefore become 2x *logical* size. The user confirmed this: internal 2x–6x followed by Fullscreen Scale Fill → 1x expands the display; temporarily returning to internal 1x resets it. Keeping a native screenRect would conceal the extra 2x Retina pixels, undoing the quality milestone. A public integration should separate logical 1x game geometry from physical texture pixels in OpenEmu's fullscreen scale calculation, ideally with the OpenEmu maintainer. **Do not try to fix this by altering the System Plugin, modifying OpenEmu preferences globally or disabling Retina output.** v214 reports `V214 FULLSCREEN_SCALE_CONTRACT` to establish the intended logical/physical pixel sizes; it does *not* claim a UI fix.

**Host geometry vs. emulated resolution:** An internal factor of 6x is rendered by Azahar, then resampled to a physical 2x image for OpenEmu. High-resolution output remains real (not merely enlarging a 1x bitmap), but the extra internal samples do not imply 6x independent display pixels. SBS Full requires a wider logical game geometry. A restart after selecting/deselecting full-width SBS may be needed to establish the appropriate host window width.

**Vulkan lifecycle:** The adapter uses real core-negotiated Vulkan resources. It requires valid handles, a completed GPU warmup, a frame consumer and a verified bitmap handoff before promoting the hardware session. If that cannot be established, it preserves the software fallback. The optional v202–v206 Metal diagnostics are asynchronous, bounded, and separate from OpenEmu's visible bitmap presenter. Avoid activating Metal2 or introducing synchronous Metal completion waits.

**Persistence and v211 migration:** `AzaharDisplayPreferences-v193.plist` lives in the core's writable support directory; `displayModeInfo` is also read when available. Values 7x/8x saved by v210 are clamped to 6x on load; invalid values are rejected. Historical physical-output scale preferences are ignored. The core does not edit OpenEmu's stored window zoom.

**Source layout**

- `azcore/Azahar.xcodeproj` — OpenEmu core plugin Xcode target.
- `azcore/AzaharCore/AzaharGameCore.mm` — libretro frontend, rendering, menu/settings, and runtime lifecycle. Historical `AzV###` names and diagnostic markers are retained for test compatibility.
- `azcore/AzaharCore/AzaharOfficialVulkanABI.mm` — official libretro Vulkan ABI helpers and private validation gates; intentionally separate from the minimal local libretro header.
- `azcore/AzaharCore/Vulkan/` — MoltenVK runtime and its license.
- `azcore/AzaharCore/VulkanSDK/include/` — bundled Vulkan headers; third-party code is unmodified.
- `azcore/patch-azahar-full-stereo-v199.py` — idempotent patch for the upstream libretro side-by-side full geometry.
- `azcore/build-azahar-libretro.sh` — checks upstream submodules and builds the arm64 Azahar dylib from source.
- `azcore/tests/` — active source-contract, geometry, host-pitch and Objective-C++ compatibility tests. `azcore/tests/historical/` preserves version-specific legacy assertions; they are **not** expected to pass against v211 because they explicitly require old menus or bundle versions.
- `CHANGELOG.txt` — cumulative version history, newest first.

## Building and installing

1. Keep the full recursive **Azahar** git checkout, including submodules, in `orig_source/azahar-git` beside `3DS-Azahar-Core` (not inside `azcore`). Keep any other checkouts used by the Xcode project as currently configured. Install CMake and use the Apple Silicon Xcode toolchain.
2. Open `azcore/Azahar.xcodeproj` and build using the same target and signing/build configuration as the previous working core. The build script checks the Azahar submodules, applies the full-stereo patch and builds its `azahar_libretro.dylib` for arm64. Starting with v215, it uses the active Xcode macOS SDK for the upstream Dynarmic MIG step and safely resets its **private** `~/.azahar-openemu-build` CMake directory on an Xcode/SDK change. The first build after upgrading Xcode may therefore fully recompile Azahar; this is expected. **The dylib already included in this ZIP is a seed, not proof that the modified upstream sources were rebuilt.**
3. Install the built `.oecoreplugin` in `~/Library/Application Support/OpenEmu/Cores/`. Keep **3DS-System-Plugin v24** separately installed in the working `OpenEmu.app/Contents/PlugIns/Systems/` location. Do not modify OpenEmu's source or binaries.
4. Open a game. Choose Azahar rendering quality via OpenEmu's **Select Display Mode → Resolution** submenu, and choose OpenEmu's **Select Scale** menu to adjust the window zoom separately.

## Testing, diagnostics and known limitations

- Suggested regression: change 1x → 6x → 1x; verify sharpness and window size, fullscreen/windowed transitions, SBS Full restart and return to 2D, controls/audio and clean game quit.
- Check `V214 BUILD_ID` and `V214 FULLSCREEN_SCALE_CONTRACT` (on physical scale changes), `V210 AUTO_OUTPUT`, `V208 RECT_PUBLISH`, `V209 SESSION_AUDIT` (expect `rowfail=0`) and `V188 LIVE_HARDWARE_TEARDOWN` (`status=PASS`). Inspect `V219 BUILD_ID` and `V214 FULLSCREEN_SCALE_CONTRACT` in the new session. The runtime log is written separately from this ZIP; do not commit a player's diagnostic log to the source tree.
- The 180-frame transition is an empirical compatibility technique for the tested OpenEmu implementation, not a guaranteed API contract on all versions of OpenEmu. Window Scale and external-display lag remain host behavior. The fullscreen 1x size issue needs coordination with OpenEmu; geometry audit `status=HOST_LOGICAL_SIZE_REVIEW` is a **known limitation**, not a rendering failure.
- If a prior experimental build left the window enlarged, first relaunch in native mode and use OpenEmu’s in-game gear menu → **Select Scale → 1×**. OpenEmu persists this zoom separately from the core, and the core does not silently overwrite it.
- Xcode/macOS runtime compilation is not available in the release-packaging environment. If a newer OpenEmu version changes bitmap pitch or screenRect semantics, the host geometry assumptions need revalidation.
- All first-party source changes should retain comments explaining ownership, mode transitions, bounded waits, failure fallback and surprising host assumptions. Third-party Vulkan headers and binary dependencies should remain upstream/unmodified and retain their licenses.

## Community review status

The project has been functional on the tested Mac configuration but remains an independent community integration effort. The code includes many historical integration diagnostics; passing a preflight or private Vulkan gate does not by itself prove live graphics. Runtime claims should be supported by the latest Mac logs. Licensing obligations for the OpenEmu/Azahar/libretro/MoltenVK components should be reviewed before public redistribution.

## v212 diagnostics and save-state verification

- Standard logging is concise. It retains versioned active runtime checkpoints (v187+), failure/error reports, frame profile, current build identification and shutdown summaries. Set `AZAHAR_DIAG_VERBOSE=1` in the emulator process environment *before opening OpenEmu* to retain the complete historical v100–v186 diagnostic trace. This changes logging only, **not which tests run**. The log is still written to `/tmp/azahar-openemu-diagnostic.log` with the existing bounded rotation.
- `V212 SESSION_PROFILE` reports time observed inside the core's `retro_run` call and between frame starts, plus bitmap row-copy costs. These are observational measurements; they cannot attribute individual frame stalls entirely to the GPU or host.
- `V212 SAVE_AUDIT` records that the serialization API is available, not that saves are proven reliable. `V212 SAVE_FILE_WRITE` and `V212 SAVE_FILE_READ` only appear after an OpenEmu user-initiated save/load. Validate an actual in-game save by exiting and reopening a game; validate a save state by saving, advancing in-game, and restoring. A `status=PASS` confirms the API call succeeded, not that every game will resume identically.
- The core's visible output behavior and system-plugin input mapping were **not changed** for v212. Third-party sources, MoltenVK, Vulkan SDK, and stereo patch are retained.

## v213 release audit and repeatable source layout

- `V213 RELEASE_HEALTH` is a single end-of-session summary of the **existing** GPU-readback, video-copy, frame-format and nine-point framebuffer integrity counters. `status=PASS` means those specific counters agree; it cannot prove correct game logic, all controller devices, or cross-game save behavior. There is **no additional frame processing** in this revision.
- To check the exact `orig_source` directory structure used by Xcode, run `python3 azcore/verify-source-layout.py` **from anywhere** (the script resolves its own location). This is read-only, reports missing inputs, and does not clone upstream code. GitHub clones will need the pinned upstream checkouts/submodules in this layout until the final source-dependency setup is completed.
- Existing `.gitignore` rules exclude local build outputs, Xcode user-state files and diagnostic logs, not the bundled Vulkan header/runtime dependencies. Before public release, review upstream licenses and ensure a fresh checkout can build with only documented dependencies.
- Core v212 Mac result: 8,840/8,840 frame-copy audits, zero readback failures, valid atomic OpenEmu state-file write, clean hardware teardown and the default quiet logger. Separately, the user has confirmed in-game saving and OpenEmu disk-icon save/restore functionality on prior versions.
- Core v213 and System Plugin v17 are separate packages and require an actual Mac/Xcode and visual test. Removing the System Plugin Home UI key may require rebinding any legacy user-configured analog keys if OpenEmu stored raw numeric indices instead of names.

## v215 Xcode 27.2 compatibility repair

On 2026-11-04, Xcode 27.2 used `MacOSX27.2.sdk`, but an Azahar CMake cache retained the removed `MacOSX27.0.sdk`, causing Dynarmic's exception-handler MIG step to fail reading `mach/mach_exc.defs`. The v215 build helper now selects the SDK from Xcode's `SDKROOT` (or `xcrun --sdk macosx --show-sdk-path` when used directly), checks that the MIG header exists, passes `CMAKE_OSX_SYSROOT` explicitly, and invalidates the private CMake build tree when the toolchain fingerprint changes. It **never deletes** the upstream `orig_source` checkout or any player's saved games. If Xcode is upgraded again, the next build will rebuild only the necessary local artifacts. This release changes build scripts and the build identity only; its Core video/audio/input code remains from v214.

## v216 GitHub handoff and source provenance

- `DEVELOPER_HANDOFF.md` contains code-review order, plugin boundaries, known
  integration limitations, licensing review and a fresh-checkout checklist.
- Run `python3 tools/run-source-checks.py` from the project root for all
  maintained portable tests. It does not compile the full macOS plugins.
- Run `python3 tools/capture-source-revisions.py --strict --output source-revisions.json`
  once the two real Git upstream checkouts are available. This records exact
  upstream commit/submodule hashes and reports local modifications (the v199
  stereo patch intentionally changes an upstream source tree). Source revision
  information is currently **not pinned** in the ZIP; obtain actual hashes
  before the public GitHub handoff. The generated manifest is developer-local
  and ignored by Git until reviewed.
- Core code and the existing Xcode/CMake build pipeline are inherited from v215.
  v216 only adds build identity/policy traces, docs and read-only checks.

## v217 pinned-upstream workflow (developer handoff)

See **`FRESH_CHECKOUT.md`** for the supported source-lock workflow. Run
`python3 tools/source-lock.py capture` on the *working Mac* to record real
upstream commits and recursive submodules, then `verify` before release.
Use explicitly reviewed upstream URLs to `bootstrap` both checkouts in a
separate workspace; the tool will never silently overwrite existing trees.
A GitHub-ready reproducible release still requires a clean native Xcode build
and a reviewed, complete source lock. **No commit pins were invented for v217.**
