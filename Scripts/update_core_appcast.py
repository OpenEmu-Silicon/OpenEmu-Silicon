#!/usr/bin/env python3
# update_core_appcast.py — Prepend a new release entry to a per-core appcast
#
# Usage:
#   python3 Scripts/update_core_appcast.py <appcast.xml> <core_name> <version> \
#       <download_url> <length> [--sign-zip <path/to/core.zip>]
#
# Arguments:
#   appcast.xml    Path to the core's appcast file (e.g. Appcasts/flycast.xml)
#   core_name      Display name of the core (e.g. Flycast)
#   version        Version string — also used as sparkle:version (e.g. 2.5)
#   download_url   Full URL to the .oecoreplugin.zip on GitHub Releases
#   length         Byte size of the zip file (overridden when --sign-zip parses one)
#
# Options:
#   --sign-zip <path>   Run Sparkle's sign_update against the local zip and embed
#                       sparkle:edSignature on the new <enclosure>. The host app's
#                       Sparkle keypair (already in keychain for the host appcast)
#                       is reused — no new keypair is generated.
#   --sign-update <bin> Path to sign_update. Defaults to release.sh's lookup
#                       (DerivedData → repo SPM cache).

import argparse
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))


def verify_zip_version(zip_path, expected_version):
    """Open the zip's Info.plist and confirm CFBundleVersion matches.

    This is the mechanical enforcement of release-core.md Step 7b. It exists
    because cores-v1.2.0 (Apr 30, 2026) shipped 5 cores whose appcast advertised
    bumped versions but whose zipped binaries' Info.plist still reported the
    previous version. Sparkle entered an infinite "update available" loop and
    the May 6 revert (98141d56) had to roll the appcasts back, leaving every
    user on the older binary. The release-core skill grew a documented Step 7b
    after that, but a human or agent could still skip it. This function makes
    it impossible to skip when --sign-zip is in play.

    Refuses (sys.exit(1)) on mismatch. Returns silently on match.
    """
    if not os.path.isfile(zip_path):
        print(f'ERROR: --sign-zip path does not exist: {zip_path}',
              file=sys.stderr)
        sys.exit(1)

    try:
        with zipfile.ZipFile(zip_path) as zf:
            # The bundle root inside the zip is e.g. "Foo.oecoreplugin/".
            # Find the Info.plist at the top of any *.oecoreplugin/Contents/.
            info_plist_paths = [
                n for n in zf.namelist()
                if n.endswith('.oecoreplugin/Contents/Info.plist')
            ]
            if not info_plist_paths:
                print(f'ERROR: no .oecoreplugin/Contents/Info.plist found '
                      f'inside {zip_path}', file=sys.stderr)
                sys.exit(1)
            if len(info_plist_paths) > 1:
                print(f'ERROR: multiple .oecoreplugin bundles inside '
                      f'{zip_path}: {info_plist_paths}', file=sys.stderr)
                sys.exit(1)
            with zf.open(info_plist_paths[0]) as plist_f:
                info = plistlib.load(plist_f)
    except (zipfile.BadZipFile, plistlib.InvalidFileException) as exc:
        print(f'ERROR: could not read Info.plist from {zip_path}: {exc}',
              file=sys.stderr)
        sys.exit(1)

    bundle_version = info.get('CFBundleVersion')
    short_version = info.get('CFBundleShortVersionString')

    # The appcast's sparkle:version is what Sparkle compares against the
    # installed bundle's CFBundleVersion. CFBundleVersion is the authoritative
    # check. CFBundleShortVersionString is a softer match — when present, it
    # should also agree, but some cores omit it entirely.
    if bundle_version != expected_version:
        print(f'ERROR: version mismatch — refusing to write appcast.\n'
              f'  Appcast about to advertise: sparkle:version="{expected_version}"\n'
              f'  Zip\'s Info.plist reports:   CFBundleVersion="{bundle_version}"\n'
              f'\n'
              f'This is the cores-v1.2.0 class of bug. If we write the appcast\n'
              f'as requested, every user already on "{bundle_version}" will see\n'
              f'an update prompt, download this zip, install it, still report\n'
              f'"{bundle_version}" internally, and loop on the same prompt forever.\n'
              f'\n'
              f'Likely causes:\n'
              f'  - The Info.plist version bump was saved to the wrong path.\n'
              f'  - The build cached an old binary; clean and rebuild.\n'
              f'  - Info.plist uses $(CURRENT_PROJECT_VERSION); also bump\n'
              f'    CURRENT_PROJECT_VERSION in the .xcodeproj/project.pbxproj.\n'
              f'\n'
              f'Fix the bundle, rebuild, then re-run this script. Do not edit\n'
              f'the appcast to match the wrong zip.',
              file=sys.stderr)
        sys.exit(1)

    if short_version is not None and short_version != expected_version:
        print(f'WARNING: CFBundleShortVersionString="{short_version}" inside '
              f'the zip does not match the version about to be advertised '
              f'("{expected_version}"). Proceeding because CFBundleVersion '
              f'matches, but consider aligning both fields.',
              file=sys.stderr)

    print(f'Verified: zip\'s CFBundleVersion="{bundle_version}" matches '
          f'requested sparkle:version="{expected_version}".')


def find_sign_update():
    derived = os.path.expanduser('~/Library/Developer/Xcode/DerivedData')
    candidates = []
    for root in (derived, REPO_ROOT):
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            if 'old_dsa_scripts' in dirpath:
                continue
            if 'sign_update' in filenames and dirpath.endswith('Sparkle/bin'):
                candidates.append(os.path.join(dirpath, 'sign_update'))
    return candidates[0] if candidates else None


def sign_zip(sign_update_bin, zip_path):
    if not sign_update_bin:
        sign_update_bin = find_sign_update()
    if not sign_update_bin or not os.path.isfile(sign_update_bin):
        print(
            'ERROR: sign_update not found. Build the project in Xcode first to '
            'resolve the Sparkle SPM package, or pass --sign-update <path>.',
            file=sys.stderr,
        )
        sys.exit(1)

    out = subprocess.run(
        [sign_update_bin, zip_path], capture_output=True, text=True, check=False
    )
    combined = (out.stdout or '') + (out.stderr or '')
    if out.returncode != 0:
        print(f'ERROR: sign_update failed:\n{combined}', file=sys.stderr)
        sys.exit(1)

    sig_match = re.search(r'sparkle:edSignature="([^"]+)"', combined)
    len_match = re.search(r'length="([0-9]+)"', combined)
    if not sig_match or not len_match:
        print(
            f'ERROR: could not parse sign_update output:\n{combined}',
            file=sys.stderr,
        )
        sys.exit(1)
    return sig_match.group(1), len_match.group(1)


def main():
    parser = argparse.ArgumentParser(
        description='Prepend a new release entry to a per-core Sparkle appcast.'
    )
    parser.add_argument('appcast_path')
    parser.add_argument('core_name')
    parser.add_argument('version')
    parser.add_argument('download_url')
    parser.add_argument('length')
    parser.add_argument('--sign-zip', default=None,
                        help='Local zip to sign with Sparkle EdDSA.')
    parser.add_argument('--sign-update', default=None,
                        help='Path to sign_update binary.')
    args = parser.parse_args()

    ed_sig = None
    length = args.length
    if args.sign_zip:
        # Enforce the cores-v1.2.0 class of bug at the script level. Refuses
        # to continue if the zip's CFBundleVersion does not match the version
        # we're about to advertise in the appcast. See verify_zip_version().
        verify_zip_version(args.sign_zip, args.version)
        ed_sig, length = sign_zip(args.sign_update, args.sign_zip)

    sig_attr = f'\n        sparkle:edSignature="{ed_sig}"' if ed_sig else ''
    new_item = f"""    <item>
      <title>{args.core_name} {args.version}</title>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure
        url="{args.download_url}"
        sparkle:version="{args.version}"
        sparkle:shortVersionString="{args.version}"
        length="{length}"{sig_attr}
        type="application/octet-stream" />
    </item>"""

    with open(args.appcast_path, 'r') as f:
        content = f.read()

    insert_after = re.search(r'(<title>[^<]*</title>\s*)', content)
    if not insert_after:
        print(f'ERROR: could not find insertion point in {args.appcast_path}',
              file=sys.stderr)
        sys.exit(1)

    pos = insert_after.end()
    content = content[:pos] + new_item + '\n' + content[pos:]

    with open(args.appcast_path, 'w') as f:
        f.write(content)

    suffix = ' (signed)' if ed_sig else ''
    print(f'Prepended {args.core_name} {args.version} entry to '
          f'{args.appcast_path}{suffix}')


if __name__ == '__main__':
    main()
