# Fresh-checkout source locking — v220/v24

This is the **upstream-source reproducibility gate** for 3DS Core for OpenEmu.
It does not clone into your working directories by default, and does **not**
compile the project. Source pins must be captured on the working Mac rather
than invented from archive filenames or upstream branch names.

## Layout and ownership

```text
workspace/
  3DS-Azahar-Core/        # the Core ZIP, with its tools/ folder
  3DS-System-Plugin/      # the System Plugin ZIP
  orig_source/
    azahar-git/           # actual full recursive Git checkout
    OpenEmu-Silicon-main/ # actual Git checkout that supplies OpenEmu-SDK
```

`source-lock.json` is a **reviewed local output**. It records full 40-digit
upstream commits, all recursive submodule commits, the SHA-256 of our local
v199 full-width SBS patch, and **explicit repository URLs**. It does not
include developer-specific paths, credentials, game ROMs or diagnostic logs.
It intentionally does not record local build binaries or hand-edited files.

## Step 1 — on the known-working Mac, capture real pins

From the `3DS-Azahar-Core` directory:

```sh
python3 tools/source-lock.py inspect
python3 tools/source-lock.py capture
python3 tools/source-lock.py verify
python3 tools/run-source-checks.py
```

`capture` accepts an Azahar checkout with **only** the exact v199 stereo patch
applied, or a pristine checkout. It refuses other tracked changes, untracked
source files (except the known v199 backup), uninitialized submodules or a
non-Git source ZIP. A source folder merely existing is **not** proof of
reproducibility. If capture refuses the current source tree, **do not reset or
delete it**: review the Git diff and preserve those changes first.

The default output is `3DS-Azahar-Core/source-lock.json`, initially ignored
by `.gitignore` until reviewed. To enable a clone-based reproduction, supply
two reviewed upstream repository URLs explicitly:

```sh
python3 tools/source-lock.py capture \
  --azahar-url 'https://EXAMPLE-REVIEWED-AZAHAR-REPO.git' \
  --openemu-url 'https://EXAMPLE-REVIEWED-OPENEMU-REPO.git'
```

These are **placeholders**, not real URLs. Replace both with the source
repositories actually used in your working checkout. The tool intentionally
doesn't silently copy the Git `origin` remote into a publishable file; it
could be private or include credentials. A lock with missing URLs is valid
for checking the current checkout but cannot bootstrap another one.

## Step 2 — create a *separate* fresh workspace

Unzip **Core v220** and **System Plugin v24** into a new directory, leaving
`orig_source/` absent. Then run from that new Core folder, with the approved
original lock file specified as `--lock`:

```sh
python3 tools/source-lock.py bootstrap \
  --lock '/path/to/reviewed/source-lock.json'
python3 tools/source-lock.py verify \
  --lock '/path/to/reviewed/source-lock.json'
python3 tools/run-source-checks.py
cd ../3DS-System-Plugin
python3 tools/run-source-checks.py
```

`bootstrap` downloads/clones the **recorded** revisions and recursively
initializes/pins the upstream submodules. It checks all inputs before making
both checkout directories visible. It **refuses to overwrite** either
upstream folder, and failures leave the existing projects untouched. Network
access and Git credentials, if needed for private repositories, are handled
by Git on the developer's computer; this tool does not provide them. Review
URLs before cloning. No Xcode build occurs during bootstrap.

## Step 3 — verify the actual macOS build

On an Apple Silicon Mac with Xcode and CMake installed, open and build
`3DS-Azahar-Core/azcore/Azahar.xcodeproj` and
`3DS-System-Plugin/Nintendo3DSSystemPlugin.xcodeproj`. The existing Xcode
phases will compile Azahar libretro with the active SDK, apply our guarded
full-SBS patch idempotently, and regenerate Swift SDK frameworks as needed.
The bundled libretro dylib and OpenEmu frameworks in the development ZIPs
are **not** proof of a fresh build. Do not publish these artifacts without
checking third-party licensing and integration with the OpenEmu maintainer.

For the cleanest compiler test, use the **new workspace on the Mac**, rather
than copying a previously built plugin into it. The Core's existing CMake
build currently caches under `$HOME/.azahar-openemu-build`; to avoid reusing
objects from a prior workspace, use a separate test user or explicitly
remove only that private build cache after backing up anything important.
The project scripts do **not** automatically delete it just because this is
a fresh-workspace test. The System Plugin regenerates its OpenEmu frameworks
using the active local Xcode SDK.

Run a game and inspect the diagnostic log for `V218 BUILD_ID`, the existing
`V213 RELEASE_HEALTH` pass check, zero host-pitch errors, and clean Vulkan
teardown. Verify 1×–6× resolution, stereo, windowed sizing, controls,
Bluetooth gamepad, Save States and a few games. Fullscreen Scale 1× at higher
internal resolution remains a known OpenEmu integration issue.

## What is NOT yet proven

- The actual `azahar-git` and `OpenEmu-Silicon-main` commits and clone URLs
  are unknown until the working Mac runs the capture step.
- No native macOS or Xcode build can be performed in the source packaging
  environment. A successful bootstrap alone is not an executable plugin.
- An untracked/ignored custom dependency or a manually changed framework
  outside Git is **not** captured by these pins. Audit all third-party
  artifacts before GitHub publication.
- Official signing, notarization, compatible OpenEmu runtime version,
  redistribution licenses, and host fullscreen scaling need maintainer review.
