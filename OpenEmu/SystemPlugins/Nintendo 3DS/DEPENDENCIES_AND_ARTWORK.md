# Third-party dependency and artwork audit

## Source and binary provenance

| Component | Where used | Candidate disposition | Publication decision |
|---|---|---|---|
| Azahar/libretro | `orig_source/azahar-git`, Core dylib | Pinned external Git checkout; no binary included | Verify exact pinned license and linking obligations |
| OpenEmu-Silicon SDK | `orig_source/OpenEmu-Silicon-main`, framework build | Pinned Git checkout; compiled frameworks excluded | Preserve file-specific OpenEmu copyright/BSD terms |
| MoltenVK | `azcore/AzaharCore/Vulkan/` | Development binary **excluded**; notice file retained | Pin and document provenance, source/build or approved binary inclusion, Apache-2.0 notices |
| Vulkan headers | `azcore/AzaharCore/VulkanSDK/include/` | Third-party **source headers retained** | Audit exact version and Apache-2.0/MIT file notices |
| Official libretro headers | `azcore/AzaharCore/OfficialABI/` | Third-party **source headers retained** | Audit exact provenance and MIT notices |
| Active 3DS graphics | System Plugin `Resources/` | **Updated and tested in private repository**, public rights review pending | CC BY 4.0 selected for original licensable artwork rights; ChatGPT-assisted mask provenance documented; earlier stock-photo tracing and other third-party rights still require public-release review |
| SDK prebuilt frameworks | System Plugin `Frameworks/` | Entire directory **excluded** | Build from pinned OpenEmu source on Mac |
| Artwork-References directory | System Plugin | **Excluded** | Keep off public repository unless fully reviewed and genuinely required |
| Unused NDS controller images | System Plugin `Resources/controller_nds*.png` | **Excluded** (not in v24 Xcode resource references) | Do not carry unrelated imagery |

## Known upstream references (informational, not proof of permission)

- OpenEmu-Silicon: https://github.com/OpenEmu-Silicon/OpenEmu-Silicon
- Azahar: https://github.com/azahar-emu/azahar
- MoltenVK: https://github.com/KhronosGroup/MoltenVK
- Vulkan-Headers: https://github.com/KhronosGroup/Vulkan-Headers
- libretro: https://github.com/libretro/libretro-common

**Pinned-revision correction:** The verified `LICENSE.txt` collected from
Azahar commit `a5c3d4f8` contains GNU GPL **Version 3**. An older development
archive contained GPLv2 license text and is **not** authoritative for the pinned
build. This identifies the pinned root license document, **not** the entire
linked binary's file-by-file licensing. See `THIRD_PARTY_NOTICES.md`,
`docs/LICENSING_AUDIT-v220-v24.md`, and `docs/licensing/` for primary evidence.
The OpenEmu-Silicon README says most app/SDK source retains OpenEmu BSD-3-Clause
notices; linked cores and borrowed artwork may have different licenses.

## Review files retained exactly from the developer ZIP

The Core still contains the original `Vulkan/MoltenVK-LICENSE.txt`, upstream
libretro headers and Khronos header sources. No new blanket license was assigned
to them. Confirm that each license and NOTICE obligation is satisfied before
publishing.

This document is a review queue, not legal counsel or clearance to redistribute.

## Artist-provided provenance

The controller illustration and pixel-art icon are credited to **Derek Hugger**.
The original Illustrator controller image used an external product photograph
as a partial tracing reference, with original shading and graphical treatment.
On November 8, 2026, the artist refined control positions based on photographs
he took of his own console; the revised artwork was built and tested in OpenEmu.
The external reference photograph is not shipped. The controller-selection
mask was generated with ChatGPT assistance from Derek Hugger's artwork and the
red-dot control-position reference he supplied, without an independent third-party
mask image. The asset-catalog image was confirmed byte-identical to `icon.png`
in the latest reviewed repository ZIP.

**License choice:** CC BY 4.0 for the licensable original artwork rights Derek
Hugger controls in the four assets named in [ARTWORK_LICENSE.md](ARTWORK_LICENSE.md).
See [ARTWORK_CREDITS.md](ARTWORK_CREDITS.md) for the complete provenance.
This license does not convey rights in third-party photographic expression,
Nintendo's intellectual property, or any rights Derek does not control.
The earlier stock-photo tracing remains a specific source-publication review
question; declaring CC BY 4.0 does **not** establish complete legal clearance.
