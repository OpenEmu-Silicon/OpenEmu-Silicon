#!/usr/bin/env python3
"""Guardrail against a flattened core submodule losing its vendored source.

Background: several cores pulled their third-party code in as nested git
submodules. When those were flattened into plain tracked files, it was possible
to commit a core without some external's actual upstream source. The Xcode
build then dies on the first missing file, but CI never built those cores, so
the break stayed invisible for months. This happened to Dolphin, Flycast and
PPSSPP, each found a different way.

This check is generic. For every tracked .gitmodules inside a core directory,
it decides for each listed external whether the core's Xcode project actually
*uses* it, and if so asserts its source is on disk. "Used" means at least one
of:

  - a file in a build phase (compiled, copied or linked) lives inside it, or
  - a header / library / framework search path points inside it.

A plain entry in the Xcode file sidebar does not count: it is never compiled.
picodrive's old libpicofe/cyclone groups were exactly that, and Windows-only or
optional externals are often present as sidebar entries too.

A used external fails the check if its directory is missing or empty, or if any
build-phase file inside it is missing.

Runs in seconds with no Xcode (plain Python, no dependencies), so CI runs it on
ubuntu on every PR:

    python3 Scripts/check-core-sources.py          # or Scripts/check-core-sources.sh
    python3 Scripts/check-core-sources.py --verbose  # also list unused externals
"""
import argparse
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# --- pbxproj reader --------------------------------------------------------
# project.pbxproj is an old-style (OpenStep) property list. plutil can convert
# it, but only on macOS; this tiny reader keeps the check runnable anywhere.

_TOKEN = re.compile(
    r"""
      (?P<ws>\s+)
    | (?P<comment>/\*.*?\*/|//[^\n]*)
    | "(?P<quoted>(?:[^"\\]|\\.)*)"
    | (?P<punct>[{}()=;,])
    | (?P<bare>[^\s{}()=;,"]+)
    """,
    re.VERBOSE | re.DOTALL,
)
_ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}


def _tokens(text):
    pos = 0
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise ValueError(f"unexpected character at offset {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "comment"):
            continue
        if kind == "quoted":
            yield ("str", re.sub(r"\\(.)", lambda e: _ESCAPES.get(e.group(1), e.group(1)), m.group(kind)))
        elif kind == "bare":
            yield ("str", m.group(kind))
        else:
            yield ("punct", m.group(kind))


def parse_pbxproj(text):
    if text.startswith("// !$*UTF8*$!"):
        text = text[text.index("\n") + 1:]
    toks = list(_tokens(text))
    pos = 0

    def value():
        nonlocal pos
        kind, tok = toks[pos]
        pos += 1
        if kind == "str":
            return tok
        if tok == "{":
            d = {}
            while toks[pos] != ("punct", "}"):
                key = value()
                assert toks[pos] == ("punct", "="), f"expected '=' after {key!r}"
                pos += 1
                d[key] = value()
                assert toks[pos] == ("punct", ";"), f"expected ';' after value of {key!r}"
                pos += 1
            pos += 1
            return d
        if tok == "(":
            items = []
            while toks[pos] != ("punct", ")"):
                items.append(value())
                if toks[pos] == ("punct", ","):
                    pos += 1
            pos += 1
            return items
        raise ValueError(f"unexpected token {tok!r}")

    return value()


# --- what a project actually uses -----------------------------------------

_SOURCE_ROOT_VARS = re.compile(r"\$(?:\((?:SRCROOT|PROJECT_DIR|SOURCE_ROOT)\)|\{(?:SRCROOT|PROJECT_DIR|SOURCE_ROOT)\}|(?:SRCROOT|PROJECT_DIR|SOURCE_ROOT)\b)")
_FLAG_PATH = re.compile(r"^-(?:I|L|F|iquote|isystem|idirafter)(.+)$")
_FLAG_SETTINGS = {"OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "OTHER_LDFLAGS", "WARNING_CFLAGS"}


def _norm(path):
    return os.path.normpath(path).replace(os.sep, "/")


def _resolve_setting_path(raw, project_dir, repo_root):
    """Turn one build-setting path into a repo-relative path, or None."""
    p = raw.replace('"', "").replace("'", "").strip()
    if p.endswith("/**"):
        p = p[:-3]
    p = _SOURCE_ROOT_VARS.sub(project_dir.replace("\\", "/"), p)
    if not p or "$" in p or os.path.isabs(p) and not p.startswith(repo_root):
        return None
    full = p if os.path.isabs(p) else os.path.join(project_dir, p)
    return _norm(os.path.relpath(full, repo_root))


def _setting_paths(key, val, project_dir, repo_root):
    values = val if isinstance(val, list) else [val]
    out = []
    for v in values:
        if not isinstance(v, str):
            continue
        if key.endswith("SEARCH_PATHS") or key == "GCC_PREFIX_HEADER":
            candidates = v.split() if key.endswith("SEARCH_PATHS") else [v]
        elif key in _FLAG_SETTINGS:
            candidates = [m.group(1) for m in map(_FLAG_PATH.match, v.split()) if m]
        else:
            continue
        for c in candidates:
            r = _resolve_setting_path(c, project_dir, repo_root)
            if r:
                out.append(r)
    return out


def _file_type(obj):
    return obj.get("lastKnownFileType") or obj.get("explicitFileType") or ""


def project_usage(pbxproj_path, repo_root=REPO_ROOT):
    """Return (build_files, build_folders, setting_paths, subprojects), repo-relative.

    build_files    files and folder references that appear in a target build phase
    build_folders  the subset of build_files that are folder references
    setting_paths  header/library/framework search paths and similar
    subprojects    other .xcodeproj bundles this project embeds
    """
    with open(pbxproj_path, encoding="utf-8", errors="replace") as f:
        data = parse_pbxproj(f.read())
    objects = data["objects"]
    root = objects[data["rootObject"]]
    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(pbxproj_path)))
    project_dir = os.path.normpath(os.path.join(project_dir, root.get("projectDirPath", "")))

    paths = {}

    def walk(oid, parent_dir):
        obj = objects.get(oid, {})
        tree = obj.get("sourceTree", "<group>")
        rel = obj.get("path", "")
        if tree == "<group>":
            here = os.path.join(parent_dir, rel) if parent_dir is not None else None
        elif tree == "SOURCE_ROOT":
            here = os.path.join(project_dir, rel)
        elif tree == "<absolute>":
            here = rel
        else:  # BUILT_PRODUCTS_DIR, SDKROOT, DEVELOPER_DIR, ...
            here = None
        if here is not None:
            paths[oid] = _norm(os.path.relpath(os.path.normpath(here), repo_root))
        for child in obj.get("children", []):
            walk(child, here)

    walk(root["mainGroup"], project_dir)
    # References outside the sidebar tree can still be resolved when their
    # path does not depend on a parent group.
    for oid, obj in objects.items():
        if oid not in paths and obj.get("sourceTree") in ("SOURCE_ROOT", "<absolute>") and "path" in obj:
            base = project_dir if obj["sourceTree"] == "SOURCE_ROOT" else ""
            paths[oid] = _norm(os.path.relpath(os.path.normpath(os.path.join(base, obj["path"])), repo_root))

    build_files, build_folders = set(), set()
    for obj in objects.values():
        if obj.get("isa", "").endswith("BuildPhase"):
            for bf in obj.get("files", []):
                ref = objects.get(bf, {}).get("fileRef")
                target = objects.get(ref, {})
                # A localized file (e.g. InfoPlist.strings) is a group with no
                # path of its own; the real files are its children.
                refs = target.get("children", []) if "Group" in target.get("isa", "") else [ref]
                for r in refs:
                    if r in paths:
                        build_files.add(paths[r])
                        if _file_type(objects[r]).startswith("folder"):
                            build_folders.add(paths[r])

    subprojects = {paths[oid] for oid, obj in objects.items()
                   if oid in paths and _file_type(obj) == "wrapper.pb-project"}

    setting_paths = set()
    for obj in objects.values():
        if obj.get("isa") == "XCBuildConfiguration":
            for key, val in obj.get("buildSettings", {}).items():
                setting_paths.update(_setting_paths(key, val, project_dir, repo_root))

    return build_files, build_folders, setting_paths, subprojects


def built_projects(repo_root=REPO_ROOT, workspace="OpenEmu-metal.xcworkspace"):
    """Map each .xcodeproj OpenEmu builds to its project_usage().

    That is every project listed in the workspace, plus the subprojects they
    embed. Projects that merely sit in the tree (e.g. an upstream SDL.xcodeproj
    inside a vendored external) are never built, so they are not read.
    """
    with open(os.path.join(repo_root, workspace, "contents.xcworkspacedata"), encoding="utf-8") as f:
        todo = [m.group(1) for m in re.finditer(r'location\s*=\s*"(?:group|container):([^"]+\.xcodeproj)"', f.read())]
    seen, usage = set(), {}
    while todo:
        proj = _norm(todo.pop())
        pbx = os.path.join(repo_root, proj, "project.pbxproj")
        if proj in seen or not os.path.isfile(pbx):
            continue
        seen.add(proj)
        usage[proj] = project_usage(pbx, repo_root)
        todo.extend(usage[proj][3])
    return usage


# --- the check -------------------------------------------------------------

def _inside(path, directory):
    return path == directory or path.startswith(directory + "/")


def _git_ls(pattern, cwd):
    out = subprocess.run(["git", "ls-files", "-z", pattern], cwd=cwd, check=True,
                         capture_output=True, text=True).stdout
    return sorted(p for p in out.split("\0") if p)


def _submodule_paths(gitmodules_path):
    with open(gitmodules_path, encoding="utf-8") as f:
        return [m.group(1).strip() for m in re.finditer(r"^\s*path\s*=\s*(.+)$", f.read(), re.M)]


def check(repo_root=REPO_ROOT, verbose=False, out=sys.stdout, err=sys.stderr):
    """Return the number of failures (0 means the check passed)."""
    gitmodules = [p for p in _git_ls("*.gitmodules", repo_root) if "/" in p]
    try:
        usage = built_projects(repo_root)
    except (OSError, ValueError, KeyError, AssertionError, IndexError) as e:
        print(f"ERROR: could not read the workspace's Xcode projects: {e!r}", file=err)
        return 1
    failures = checked = unused = 0

    for gm in gitmodules:
        core = gm.split("/", 1)[0]
        srcroot = os.path.dirname(gm)
        core_usage = [u for proj, u in usage.items() if proj.startswith(core + "/")]
        if not core_usage:
            continue
        build_files = set().union(*(u[0] for u in core_usage))
        build_folders = set().union(*(u[1] for u in core_usage))
        setting_paths = set().union(*(u[2] for u in core_usage))

        exts = [_norm(os.path.join(srcroot, rel)) for rel in _submodule_paths(os.path.join(repo_root, gm))]
        parents = [os.path.dirname(e) for e in exts]
        for ext in exts:
            used_files = sorted(f for f in build_files if _inside(f, ext))
            # A search path pointing at the external's own wrapper folder
            # (Externals/foo for Externals/foo/foo) reaches into it via
            # #include "foo/...". Only a folder that holds this one external
            # counts; a shared one (Externals/, ext/) or the source root would
            # otherwise make every external in it look used.
            parent = os.path.dirname(ext)
            wrapper = parent if parent != _norm(srcroot) and parents.count(parent) == 1 else None
            used_settings = sorted(s for s in setting_paths if _inside(s, ext) or s == wrapper)
            # A build-phase folder reference that contains the external also uses it.
            used_files += sorted(f for f in build_folders if _inside(ext, f) and f != ext)
            if not used_files and not used_settings:
                unused += 1
                if verbose:
                    print(f"skip: [{core}] {ext} is not used by any Xcode build", file=out)
                continue

            checked += 1
            full = os.path.join(repo_root, ext)
            if not os.path.isdir(full) or not os.listdir(full):
                print(f"ERROR: [{core}] external '{ext}' is used by the Xcode build", file=err)
                print("       but its source tree is missing or empty.", file=err)
                print(f"       e.g. {(used_files or used_settings)[0]}", file=err)
                print("       The flattened submodule was committed without its upstream source.", file=err)
                print(f"       Re-vendor it as plain files at the pinned commit ({gm} has the URL).", file=err)
                failures += 1
                continue

            missing = [f for f in used_files if not os.path.exists(os.path.join(repo_root, f))]
            if missing:
                print(f"ERROR: [{core}] external '{ext}' is missing {len(missing)} file(s) the Xcode build needs:", file=err)
                for f in missing[:10]:
                    print(f"       {f}", file=err)
                if len(missing) > 10:
                    print(f"       ... and {len(missing) - 10} more", file=err)
                failures += 1

    if failures == 0:
        print(f"OK: all core externals used by an Xcode build are populated "
              f"({checked} checked, {unused} unused and skipped).", file=out)
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true", help="list externals skipped as unused")
    args = ap.parse_args()
    sys.exit(1 if check(verbose=args.verbose) else 0)


if __name__ == "__main__":
    main()
