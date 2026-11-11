# Upstream provenance and redistribution review — v220 / v24

**Status: evidence gathered, release authorization NOT established.** This is
not legal advice or a determination of license compatibility. The checked
source archives were supplied during development. They are *not* proven to be
the exact Git revisions installed or compiled on the working Mac; a filename
like `master.zip` does not uniquely identify a commit.

## Directly observed license documents in supplied reference archives

| Component / archive | Observed file and exact SHA-256 | Interpretation and remaining check |
|---|---|---|
| Azahar, `azahar-master.zip` | `azahar-master/license.txt` — `a77e81713ddfe05f9f7f3a3c46de4147f82b5fe9d6e5e24af96e36a6de53f613` | Contains the **GNU GPL version 2** full license text. Review Azahar source headers, third-party submodules, linking and compliance against the actual pinned revision; don't infer every component has this same license. |
| Azahar artwork, same archive | `azahar-master/dist/license.md` — `fbcab68151d27cd392bc9573884192beb8cb4bdb5da09f77e0918bdaeace7b87` | Lists multiple icon-specific licenses, including CC BY-ND 3.0 and CC0. Confirm whether **any** covered files are being distributed or reused; this document alone does not license our new artwork. |
| OpenEmu-derived source, `OpenEmu-Silicon-main.zip` | `OpenEmu-Silicon-main/LICENSE` — `c5aa06065a64997d233f3fc39253d263c412acc603ad890dd4230867d113ec77` | States a derivative of OpenEmu; documents **BSD 3-Clause terms for most original OpenEmu files** and says individual file headers take precedence. It explicitly disclaims OpenEmu Team endorsement. Validate bundled frameworks, original OpenEmu source and other third-party components individually. |
| MoltenVK, `MoltenVK-1.4.2.zip` | `MoltenVK-1.4.2/LICENSE` — `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | Contains **Apache License 2.0** text. The development Core includes `azcore/AzaharCore/Vulkan/MoltenVK-LICENSE.txt`; check binary provenance and required notices/attribution for the version actually shipped. |

These SHA-256 values identify **license text bytes in the uploaded source archives**,
not binaries, commits or any verified licensed release. Do not copy an unreviewed
license declaration onto code of uncertain ownership.

## Artifacts that still need decisions before GitHub publication

| Material | Present in development ZIPs | Decision required |
|---|---|---|
| Azahar libretro `.dylib` | Core | Prefer build from pinned sources; confirm copyleft/source availability and linkage obligations before distributing binary |
| MoltenVK `.dylib`, Vulkan and libretro headers | Core | Verify origin/version of each artifact, full applicable notices, and permissible redistribution |
| OpenEmuBase / OpenEmuSystem prebuilt frameworks | System Plugin | Prefer build from pinned OpenEmu SDK; audit each framework's licenses, symbols and generated Swift modules, which depend on the Xcode SDK |
| Nintendo 3DS icon, diagrams, mapping overlays, references | System Plugin | Confirm the rights/creator and origin of each image, including reference assets; replace or omit uncertain artwork from public source if needed |
| Original Core and System Plugin source | Both | Confirm contributors' copyright and selected license(s) after evaluating combined/linked third-party obligations |
| Nintendo 3DS firmware, ROMs and saved game data | **Not included** | Keep excluded from source control and release packages; require users to supply lawful game content |

## Safe publication workflow

1. On the known-working Mac, run `python3 tools/workspace-report.py`. Share
   the sanitized output, which reports missing/available actual Git metadata.
2. Capture and **verify** the real upstream hashes (including submodules) with
   `python3 tools/source-lock.py capture` and `verify`. Do not reset the working
   Azahar tree; its guarded full-SBS patch is expected. Review URLs separately.
3. Build from a separate locked source checkout and record the outcome. Hash
   any dependency binaries actually produced. Keep the working development
   workspace intact.
4. Have the project maintainers review all license files, individual-source
   copyrights, binary notices, and artwork ownership. Only then choose the
   repository license and whether development binaries/frameworks may ship.
5. Coordinate OpenEmu compatibility, fullscreen logical/physical sizing,
   plugin placement, code signing and distribution with maintainers.

**No claim of an official OpenEmu endorsement, a completed fresh checkout, or
redistribution approval is made by this development archive.**
