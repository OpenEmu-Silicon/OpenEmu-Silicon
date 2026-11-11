## v220/v24 handoff status (2026-11-07)

**Native-functional baseline: v219/v23 passed on the user's Mac.** The latest
v219 diagnostic review showed 1,280 hardware frames, no GPU readback/copy/pitch
failures, save-state serialization/file writing and clean GPU teardown.
The v220/v24 update is intentionally limited to provenance/license review,
portable tests, version reporting and documentation. Native v220/v24 build and
runtime checks are PENDING. The OpenEmu System Plugin build had no warnings;
the remaining Core Xcode warning is upstream duplicate static libraries, plus
Xcode's recommended-settings notice. Do **not** blindly apply that setting.

New read-only report: `python3 tools/workspace-report.py`. It reports Git
availability, exact HEAD SHA when present, dirty/submodule counts and toolchain
versions **without** usernames, absolute paths or remote URLs. It is not a
source lock and cannot infer commits from a source ZIP. `DEPENDENCY_REVIEW.md`
lists observed upstream licensing evidence with remaining rights questions;
it is a review aid, not redistribution approval.

**Still blocking public publication:** real Git commits and recursive
submodule lock (or review of a non-Git source tree), isolated fresh macOS build,
third-party binary and artwork provenance/rights, and OpenEmu maintainer
review of geometry, plugin install and signing.

# Release-candidate evidence and handoff — Core v220 / System v24

This is a **candidate-preparation iteration**, not an official OpenEmu
release. The user confirmed v218/v22 compile and OpenEmu gameplay on Xcode 27.2,
with a clean v218 runtime log (2,588 GPU frames, no readback/copy/pitch failures,
successful state serialization and clean teardown). Separately, v217/v21
validated Bluetooth input and resumed gameplay from a saved state. These
the v219/v23 pair subsequently compiled and passed an OpenEmu smoke test;
**the new v220/v24 pair still requires its own Mac check**.

## On the working Mac

Extract both new ZIPs to sibling folders using the normal working layout;
keep `orig_source/` intact. Build the Core and System Plugin with Xcode,
run a game and check stereo, 1x/4x/6x internal resolution, host shaders,
keyboard and wireless controller, save-state restore and clean exit.
Then, from either project folder:

```sh
python3 tools/run-source-checks.py
python3 tools/source-lock.py inspect
python3 tools/source-lock.py capture
python3 tools/source-lock.py verify
python3 tools/release-gate.py --runtime-log '/path/to/new-azahar-diagnostic.log' \
  --report '../3ds-v220-v24-release-evidence.json'
```

`--report` is optional and the tool otherwise writes no evidence files.
The report MUST be written outside the source directories and will not
overwrite an existing file. It contains checksums/paths of *development*
binaries and gate statuses; review it before sharing. The verifier returns
zero when checks pass with outstanding `PENDING` items, and returns nonzero
on a `FAIL`. Use `--strict` to also fail on any `PENDING` item. The tool does
not claim to check native Xcode compilation, signing or licensing itself.

`capture` may refuse an archive-based `orig_source` tree that has no `.git`
metadata, or a dirty tree with unknown edits. **Do not reset or delete the
working source.** Upload the command output and we will reconcile it against
the real upstream revision without risking the functional checkout. Never
invent a SHA from a branch label or ZIP filename. Source pin URLs must be
explicitly reviewed (not copied from potentially credentialed Git remotes).

## Evidence classification

| Gate | Automation | How it becomes eligible for release review |
| --- | --- | --- |
| Plugin version and critical artifacts | Portable | Correct v220/v24 metadata and the actual binaries present |
| Offline regression suite | Portable | Both projects' tests pass; this does not link on macOS |
| Exact upstream sources | Mac/Git | Two real pinned commits, recursive submodules and known Azahar patch verified |
| Fresh independent build | Human/Xcode | Clone locked source into a separate workspace; compile both from scratch |
| Runtime behavior | Mac/OpenEmu | New v220 log + controller, saving, stereo and multi-game playtest |
| Third-party redistribution | Maintainer/license | Read the **actual** license of every bundled dependency and artwork |
| Host integration/release | OpenEmu maintainer | Fullscreen logical/physical scale fix/decision, code review and signing path |

The `release-gate.py` report includes automatic SHA-256 checksums for these
**development-only, unreviewed** binaries: `azahar_libretro.dylib`,
`libMoltenVK.dylib`, `OpenEmuBase.framework`, and `OpenEmuSystem.framework`.
Checksums prove file identity, not source origin or redistribution permission.
Vulkan SDK headers, official libretro headers, additional copied resources,
and supplied controller artwork also require provenance/license review.
All ROMs, save states, personal diagnostics and user-specific build outputs
must remain outside a public repository.

## Exact remaining questions before any publication

1. Did `source-lock.py capture/verify` succeed against the Mac's *actual* sources?
2. Are the clone URLs reviewed and is a clean, independent clone/build complete?
3. Are code, SDK headers, MoltenVK, binary/framework builds and artwork
   licenses/attributions reviewed, with a decision on what should be vendored?
4. Has the OpenEmu maintainer reviewed the host fullscreen scale anomaly,
   plugin installation method, version compatibility and signing workflow?
5. Has the release candidate passed several distinct games, in-game saves,
   state restoration, Bluetooth, 2D/stereo modes, scaling and shaders?

The user-tested **v219/v23 pair is the frozen functional reference**.
If these gates pass, **v220/v24 could be the handoff candidate** without
further gameplay changes.
Any missing upstream revisions, licenses or host integration requirements
may still warrant a later housekeeping build. Do not imply GitHub release
readiness from a successful gameplay session alone.

## v219/v23 compiler warning disposition (Xcode 27.2 observed on v218/v22)

- **Fixed in plugin projects**: deprecated headermap settings on both Xcode
  targets. `ALWAYS_SEARCH_USER_PATHS=NO` and
  `ALWAYS_USE_SEPARATE_HEADERMAPS=YES` are explicitly set in Debug/Release.
- **Fixed in Core**: remove incorrect `OEAudioBuffer` protocol conformance
  from the `OEGameCore` subclass; OpenEmu supplies the actual ring-buffer.
  The audio sample/batch callbacks and their write calls have not changed.
- **Retained intentionally**: v106–v108 constant-zero Vulkan gate operands;
  suppression is restricted to this historical diagnostic block, never v187+.
- **Fixed in System Plugin**: Xcode build script explicitly runs every build
  to check the active Xcode SDK and rebuild OpenEmu frameworks on SDK changes.
- **Unmodified upstream/toolchain**: duplicate static-library references in
  Azahar's upstream link step and Xcode's AppIntents metadata extraction skip.
  Do not suppress unrelated compiler/linker warnings as proof of correctness.

This revision was source-tested and packaged away from macOS. Native Xcode
compilation, upstream source commit pins, fresh builds, signing and legal
redistribution review remain independent acceptance gates.
