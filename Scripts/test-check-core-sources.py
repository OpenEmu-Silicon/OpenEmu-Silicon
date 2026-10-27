#!/usr/bin/env python3
"""Checks for check-core-sources.py, against small fixture repos and the real one.

    python3 Scripts/test-check-core-sources.py
"""
import importlib.util
import io
import os
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ccs", os.path.join(HERE, "check-core-sources.py"))
ccs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ccs)


def pbxproj(build_paths=(), sidebar_paths=(), header_search=(), variant=False, folder_paths=(), subprojects=()):
    """A minimal project: one target whose Sources phase compiles build_paths.

    All paths are relative to the project directory (SOURCE_ROOT).
    """
    objs, children, phase = [], [], []
    for i, p in enumerate(build_paths):
        objs.append(f'F{i} = {{isa = PBXFileReference; path = "{p}"; sourceTree = SOURCE_ROOT; }};')
        objs.append(f'B{i} = {{isa = PBXBuildFile; fileRef = F{i}; }};')
        children.append(f"F{i}")
        phase.append(f"B{i}")
    for i, p in enumerate(sidebar_paths):
        objs.append(f'S{i} = {{isa = PBXGroup; children = (); path = "{p}"; sourceTree = "<group>"; }};')
        children.append(f"S{i}")
    for i, p in enumerate(folder_paths):
        objs.append(f'D{i} = {{isa = PBXFileReference; lastKnownFileType = folder; path = "{p}"; sourceTree = SOURCE_ROOT; }};')
        objs.append(f'DB{i} = {{isa = PBXBuildFile; fileRef = D{i}; }};')
        children.append(f"D{i}")
        phase.append(f"DB{i}")
    for i, p in enumerate(subprojects):
        objs.append(f'P{i} = {{isa = PBXFileReference; lastKnownFileType = "wrapper.pb-project"; path = "{p}"; sourceTree = SOURCE_ROOT; }};')
        children.append(f"P{i}")
    if variant:
        objs.append('V0 = {isa = PBXVariantGroup; children = (V1); name = InfoPlist.strings; sourceTree = "<group>"; };')
        objs.append('V1 = {isa = PBXFileReference; name = en; path = en.lproj/InfoPlist.strings; sourceTree = "<group>"; };')
        objs.append("VB = {isa = PBXBuildFile; fileRef = V0; };")
        children.append("V0")
        phase.append("VB")
    search = ", ".join(f'"\\"$(SRCROOT)/{p}\\""' for p in header_search)
    return textwrap.dedent("""\
        // !$*UTF8*$!
        {
        \tobjects = {
        \t\t%s
        \t\tMAIN = {isa = PBXGroup; children = (%s); sourceTree = "<group>"; };
        \t\tPHASE = {isa = PBXSourcesBuildPhase; files = (%s); };
        \t\tCFG = {isa = XCBuildConfiguration; buildSettings = {HEADER_SEARCH_PATHS = (%s); }; name = Debug; };
        \t\tPROJ = {isa = PBXProject; mainGroup = MAIN; projectDirPath = ""; };
        \t};
        \trootObject = PROJ /* Project object */;
        }
        """) % ("\n\t\t".join(objs), ", ".join(children), ", ".join(phase), search)


class Fixture:
    """A throwaway git repo with one core, Core/, built by the workspace."""

    def __init__(self, test, submodules, files=(), workspace=("Core/Core.xcodeproj",), **pbx):
        self._tmp = tempfile.TemporaryDirectory()
        test.addCleanup(self._tmp.cleanup)
        self.root = os.path.realpath(self._tmp.name)
        self.write("OpenEmu-metal.xcworkspace/contents.xcworkspacedata",
                   "".join(f'<FileRef location = "group:{w}"></FileRef>\n' for w in workspace))
        self.write("Core/Core.xcodeproj/project.pbxproj", pbxproj(**pbx))
        self.write("Core/.gitmodules", "".join(
            f'[submodule "{s}"]\n\tpath = {s}\n\turl = https://example.invalid/{s}.git\n' for s in submodules))
        for f in files:
            self.write(os.path.join("Core", f), "x")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)

    def write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def run(self):
        out, err = io.StringIO(), io.StringIO()
        failures = ccs.check(self.root, verbose=True, out=out, err=err)
        return failures, out.getvalue(), err.getvalue()


class CheckCoreSources(unittest.TestCase):
    def test_compiled_file_in_missing_external_fails(self):
        failures, _, err = Fixture(self, ["ext/foo"], build_paths=["ext/foo/foo.c"]).run()
        self.assertEqual(failures, 1)
        self.assertIn("Core/ext/foo", err)
        self.assertIn("missing or empty", err)

    def test_sidebar_only_reference_is_not_used(self):
        # picodrive's old libpicofe/cyclone: listed in the sidebar, never compiled.
        failures, out, _ = Fixture(self, ["ext/foo"], sidebar_paths=["ext/foo"]).run()
        self.assertEqual(failures, 0)
        self.assertIn("skip: [Core] Core/ext/foo is not used", out)

    def test_header_search_path_into_missing_external_fails(self):
        failures, _, _ = Fixture(self, ["ext/foo"], header_search=["ext/foo/include"]).run()
        self.assertEqual(failures, 1)

    def test_wrapper_folder_search_path_counts_as_used(self):
        # Externals/foo/foo with a search path on Externals/foo (#include "foo/x.h").
        failures, _, _ = Fixture(self, ["Externals/foo/foo", "Externals/bar/bar"],
                                 header_search=["Externals/foo"], files=["Externals/bar/bar/x.c"]).run()
        self.assertEqual(failures, 1)

    def test_shared_folder_or_root_search_path_does_not_use_every_external(self):
        failures, out, _ = Fixture(self, ["Externals/foo", "Externals/bar", "baz"],
                                   header_search=["Externals", "."]).run()
        self.assertEqual(failures, 0)
        self.assertEqual(out.count("skip:"), 3)

    def test_missing_single_compiled_file_fails(self):
        failures, _, err = Fixture(self, ["ext/foo"], build_paths=["ext/foo/a.c", "ext/foo/b.c"],
                                   files=["ext/foo/a.c"]).run()
        self.assertEqual(failures, 1)
        self.assertIn("Core/ext/foo/b.c", err)

    def test_populated_external_passes(self):
        failures, out, _ = Fixture(self, ["ext/foo"], build_paths=["ext/foo/a.c"], files=["ext/foo/a.c"]).run()
        self.assertEqual(failures, 0)
        self.assertIn("1 checked", out)

    def test_localized_group_does_not_mark_whole_core_used(self):
        failures, _, _ = Fixture(self, ["ext/foo"], variant=True).run()
        self.assertEqual(failures, 0)

    def test_projects_not_in_the_workspace_are_ignored(self):
        fx = Fixture(self, ["ext/foo"], workspace=())
        fx.write("Core/Core.xcodeproj/project.pbxproj", pbxproj(build_paths=["ext/foo/a.c"]))
        self.assertEqual(fx.run()[0], 0)

    def test_folder_reference_containing_external_counts_as_used(self):
        failures, _, err = Fixture(self, ["data/ext/foo"], folder_paths=["data"]).run()
        self.assertEqual(failures, 1)
        self.assertIn("Core/data/ext/foo", err)

    def test_embedded_subproject_is_read(self):
        fx = Fixture(self, ["ext/foo"], subprojects=["Sub/Sub.xcodeproj"])
        fx.write("Core/Sub/Sub.xcodeproj/project.pbxproj", pbxproj(build_paths=["../ext/foo/a.c"]))
        self.assertEqual(fx.run()[0], 1)

    def test_missing_workspace_project_fails(self):
        fx = Fixture(self, ["ext/foo"], workspace=("Core/Core.xcodeproj", "Gone/Gone.xcodeproj"))
        failures, _, err = fx.run()
        self.assertEqual(failures, 1)
        self.assertIn("Gone/Gone.xcodeproj", err)

    def test_parser_handles_comments_escapes_and_lists(self):
        data = ccs.parse_pbxproj('// !$*UTF8*$!\n{ a = "x \\"y\\""; /* c */ b = (1, 2,); c = {d = e;}; }')
        self.assertEqual(data, {"a": 'x "y"', "b": ["1", "2"], "c": {"d": "e"}})

    def test_real_repo_passes(self):
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(ccs.check(verbose=True, out=out, err=err), 0, err.getvalue())
        # picodrive builds without its old upstream frontends (#673).
        self.assertNotIn("picodrive", err.getvalue())


if __name__ == "__main__":
    unittest.main()
