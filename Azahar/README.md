# Nintendo 3DS core (Azahar.oecoreplugin)

OpenEmu wrapper around the [Azahar](https://github.com/azahar-emu/azahar) engine (GPL-2.0-or-later, a Citra successor). Work is tracked in [#814](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/814). Read [`docs/3ds-azahar-port.md`](../docs/3ds-azahar-port.md) and [ADR-0007](../docs/adr/0007-3ds-core-from-azahar.md) first.

**Status: engine build only.** There is no core plugin yet. Item 2 of #814 is in: the engine source is pinned and the engine libraries build from a clean clone with one script. Items 3 onward (the core plugin, the picture, audio, input, saves) are not started.

## Source dependency

The engine source is not committed here (about 560 MB with its submodules). It is fetched from the fork `OpenEmu-Silicon/azahar` at the commit pinned in `deps-azahar-revision.txt`:

```sh
./Scripts/prepare-azahar-core.sh
```

That puts it in `Azahar/deps/azahar` (gitignored). Our changes to the engine are patches in `Azahar/patches/*.patch`, applied in name order. The fork itself stays an untouched snapshot of the Azahar 2126.2 release. Updating means merging upstream Azahar into the fork and bumping the revision in the script and in `deps-azahar-revision.txt`.

Azahar's CMake refuses to configure unless every submodule is present, so the script fetches all of them. It ignores your global git config while it does so (a global "LFS required" setting breaks teakra's checkout on a Mac without `git-lfs`).

## Build

```sh
brew install cmake
./Scripts/build-azahar-core.sh
```

This fetches the source, installs a MoltenVK copy checked against a pinned SHA-256 (`Scripts/build-azahar-deps.sh`; Azahar's own CMake would download it with no check), then configures the engine with no Qt, no desktop frontends and **`ENABLE_LIBRETRO` off**, and builds the engine libraries (`citra_core`, `video_core`, `audio_core`, `input_common`, `citra_common`, `network`) into `Azahar/build/engine`. It writes the built commit to `Azahar/build/ENGINE_COMMIT`. The first run takes a while.

## Files

| File | What it does |
|---|---|
| `deps-azahar-revision.txt` | The pinned fork commit |
| `patches/` | Our engine patches (none yet) |
| `../Scripts/prepare-azahar-core.sh` | Fetches the pinned commit, all submodules, applies patches |
| `../Scripts/build-azahar-deps.sh` | Installs the pinned MoltenVK |
| `../Scripts/build-azahar-core.sh` | Configures and builds the engine libraries |
