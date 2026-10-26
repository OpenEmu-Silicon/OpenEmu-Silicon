#!/usr/bin/env python3
"""Checks for detect-core-changes.py, run against the real Xcode projects.

    python3 Scripts/test-detect-core-changes.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("dcc", os.path.join(HERE, "detect-core-changes.py"))
dcc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dcc)

KIT_MAP = dcc.build_map(dcc.ALL_CORES)


def pick(*paths):
    return dcc.select(list(paths), kit_map=KIT_MAP)[0]


class DetectCoreChanges(unittest.TestCase):
    def test_every_core_name_has_a_directory(self):
        for core in dcc.ALL_CORES:
            self.assertTrue(os.path.isdir(os.path.join(dcc.REPO_ROOT, dcc.core_dir(core))), core)

    def test_core_dir_change_selects_only_that_core(self):
        self.assertEqual(pick("Gambatte/GBGameCore.mm"), ["Gambatte"])
        self.assertEqual(pick("Potator-Core/x.c"), ["Potator"])

    def test_scripts_select_nothing(self):
        self.assertEqual(pick("Scripts/verify.sh"), [])

    def test_sdk_and_workspace_select_everything(self):
        self.assertEqual(pick("OpenEmu-SDK/x.m"), dcc.ALL_CORES)
        self.assertEqual(pick("OpenEmu-metal.xcworkspace/contents.xcworkspacedata"), dcc.ALL_CORES)

    def test_referenced_kit_file_selects_cores_that_compile_it(self):
        got = pick("OpenEmuKit/Source/OERetroAchievementsBridge.m")
        self.assertIn("Gambatte", got)
        self.assertNotIn("4DO", got)

    def test_search_path_with_trailing_backslash_still_matches(self):
        # Mednafen and Mupen64Plus write the search path with a trailing "\".
        got = pick("OpenEmuKit/Source/KeyValueScanner.h")
        self.assertIn("Mednafen", got)
        self.assertIn("Mupen64Plus", got)

    def test_swift_in_kit_selects_nothing(self):
        self.assertEqual(pick("OpenEmuKit/Source/GameAudio.swift"), [])

    def test_unknown_kit_change_selects_everything(self):
        self.assertEqual(pick("OpenEmuKit/OpenEmuKit.xcodeproj/project.pbxproj"), dcc.ALL_CORES)
        self.assertEqual(pick("OpenEmuKit/Config.xcconfig"), dcc.ALL_CORES)

    def test_vendor_change_selects_everything(self):
        self.assertEqual(pick("Vendor/rcheevos/src/a.c"), dcc.ALL_CORES)

    def test_nested_and_other_cores_are_mapped(self):
        got = pick("OpenEmuKit/Source/OERetroAchievementsBridge.m")
        for core in ("PPSSPP", "Stella", "O2EM"):
            self.assertIn(core, got)

    def test_empty_change_list_selects_nothing(self):
        self.assertEqual(pick(), [])

    def test_script_reads_paths_from_stdin(self):
        out = subprocess.run(
            [sys.executable, os.path.join(HERE, "detect-core-changes.py"), "--files", "-"],
            input="Gambatte/GBGameCore.mm\n", capture_output=True, text=True, check=True,
        ).stdout
        self.assertEqual(json.loads(out)["cores"], ["Gambatte"])

    def test_new_unreferenced_c_file_in_unmapped_dir_selects_everything(self):
        self.assertEqual(pick("OpenEmuKit/NewDir/new.m"), dcc.ALL_CORES)


if __name__ == "__main__":
    unittest.main()
