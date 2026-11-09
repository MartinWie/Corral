#!/usr/bin/env python3
"""Writes Resources/app/THIRD_PARTY_NOTICES.txt: the licenses of everything Corral.app ships (the Ghostty
engine, the libraries and fonts it links, the bundled themes, Zig's standard library).

License texts come from the Zig packages scripts/build-ghostty.sh fetched (vendor/ghostty/zig-pkg, else
Zig's global cache), found through the hashes in vendor/ghostty's build.zig.zon files. Rerun after
changing the Ghostty version or its build options:  scripts/notices.py

  scripts/notices.py --check <Corral binary>   fails when the binary links a known library family the
                                               notices don't cover, or libintl / Sentry, when it isn't a
                                               symbolized Corral binary, or when THIRD_PARTY_NOTICES.txt
                                               is out of date
"""
import glob
import os
import re
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GHOSTTY = os.path.join(ROOT, "vendor", "ghostty")
PKG = os.path.join(GHOSTTY, "zig-pkg")
CACHE = os.path.join(os.environ.get("ZIG_GLOBAL_CACHE_DIR")
                     or os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "zig"), "p")
OUT = os.path.join(ROOT, "Resources", "app", "THIRD_PARTY_NOTICES.txt")

# (title, license, homepage, zon dependency name or None, license files to try in order, or inline text)
MIT_SIMDUTF = """Copyright 2021 The simdutf authors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""

MIT_BODY = """Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial
portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""

COMPONENTS = [
    ("Ghostty (terminal engine)", "MIT", "https://ghostty.org", None, ["file:LICENSE"]),
    ("Zig standard library", "MIT", "https://ziglang.org", None, ["zig:LICENSE"]),
    ("libxev", "MIT", "https://github.com/mitchellh/libxev", "libxev", ["LICENSE"]),
    ("z2d", "MPL-2.0 (source: https://github.com/vancluever/z2d)", "https://github.com/vancluever/z2d", "z2d",
     ["LICENSE+COPYING"]),
    ("zig-objc", "MIT", "https://github.com/mitchellh/zig-objc", "zig_objc", ["LICENSE"]),
    ("uucode", "MIT", "https://github.com/jacobsandlund/uucode", "uucode", ["LICENSE.md", "LICENSE"]),
    ("libvaxis", "MIT", "https://github.com/rockorager/libvaxis", "vaxis", ["LICENSE"]),
    ("zf", "MIT", "https://github.com/natecraddock/zf", "zf", ["LICENSE"]),
    ("Dear ImGui", "MIT", "https://github.com/ocornut/imgui", "imgui", ["LICENSE.txt"]),
    ("Dear Bindings (dcimgui)", "MIT", "https://github.com/dearimgui/dear_bindings", "bindings",
     ["LICENSE.txt", "LICENSE", "inline:Generated C bindings for Dear ImGui, made with Dear Bindings (MIT). Dear "
      "ImGui's license above applies to the bound code."]),
    ("glslang", "BSD-3-Clause and others (see text)", "https://github.com/KhronosGroup/glslang", "glslang", ["LICENSE.txt"]),
    ("SPIRV-Cross", "Apache-2.0", "https://github.com/KhronosGroup/SPIRV-Cross", "spirv_cross", ["LICENSE"]),
    ("Oniguruma", "BSD-2-Clause", "https://github.com/kkos/oniguruma", "oniguruma", ["COPYING"]),
    ("FreeType", "FreeType License (FTL); BDF/PCF drivers under their own notices",
     "https://freetype.org", "freetype", ["LICENSE.TXT+docs/FTL.TXT+src/bdf/README+src/pcf/README"]),
    ("Unicode Character Database (tables in uucode and Oniguruma)", "Unicode License v3",
     "https://www.unicode.org/license.txt", None, ["pkg:aro-*/LICENSE-UNICODE"]),
    ("bash-preexec (in Resources/ghostty/shell-integration/bash)", "MIT", "https://github.com/rcaloras/bash-preexec",
     None, ["inline:Copyright (c) 2017 Ryan Caloras and contributors (see https://github.com/rcaloras/bash-preexec)\n\n"
            + MIT_BODY]),
    ("libpng", "libpng License", "http://www.libpng.org", "libpng", ["LICENSE"]),
    ("zlib", "Zlib", "https://zlib.net", "zlib", ["LICENSE"]),
    ("Highway", "BSD-3-Clause (dual Apache-2.0)", "https://github.com/google/highway", "highway", ["LICENSE-BSD3", "LICENSE"]),
    ("Wuffs", "MIT (dual Apache-2.0)", "https://github.com/google/wuffs", "wuffs", ["LICENSE-MIT", "LICENSE"]),
    ("simdutf", "MIT (dual Apache-2.0)", "https://github.com/simdutf/simdutf", None, ["inline:" + MIT_SIMDUTF]),
    ("JetBrains Mono (embedded font)", "SIL Open Font License 1.1", "https://www.jetbrains.com/lp/mono/",
     "jetbrains_mono", ["OFL.txt"]),
    ("Symbols Nerd Font (embedded font)", "MIT / SIL OFL 1.1", "https://www.nerdfonts.com",
     "nerd_fonts_symbols_only", ["LICENSE"]),
    ("Sparkle (updates, in Frameworks/Sparkle.framework)", "MIT and others (see text)", "https://sparkle-project.org",
     None, ["spm:Sparkle/LICENSE"]),
    ("Color themes (iTerm2-Color-Schemes, in Resources/ghostty/themes)", "MIT; individual themes by their authors",
     "https://github.com/mbadolato/iTerm2-Color-Schemes", None,
     ["inline:Copyright (c) Mark Badolato and the iTerm2-Color-Schemes contributors; each theme is credited to "
      "its author in the upstream repository.\n\n" + MIT_BODY]),
]


# Symbol families in the linked binary -> the component that covers them (None: must not be linked).
FAMILIES = [
    (r"_FT_Init_FreeType|_FT_New_Memory_Face", "FreeType"),
    (r"_png_create_read_struct", "libpng"),
    (r"_inflateInit|_deflateInit", "zlib"),
    (r"_onig_new", "Oniguruma"),
    (r"_spvc_context_create", "SPIRV-Cross"),
    (r"glslang", "glslang"),
    (r"ImGui", "Dear ImGui"),
    (r"simdutf", "simdutf"),
    (r"_wuffs_", "Wuffs"),
    (r"3hwy", "Highway"),
    (r"_hb_buffer_create", None),
    (r"_FcInit", None),
    (r"_libintl_|_bindtextdomain", None),
    (r"_sentry_init|_sentry_capture", None),
]


def zon_hashes():
    """Dependency name -> package hash; the root manifest first, then Ghostty's own packages."""
    hashes = {}
    root = os.path.join(GHOSTTY, "build.zig.zon")
    others = sorted(p for p in glob.glob(os.path.join(GHOSTTY, "pkg", "**", "build.zig.zon"), recursive=True))
    for path in [root] + others:
        text = open(path, encoding="utf-8").read()
        for name, block in re.findall(r"\.(\w+)\s*=\s*\.\{([^{}]*)\}", text):
            m = re.search(r'\.hash\s*=\s*"([^"]+)"', block)
            if not m:
                continue
            if name in hashes and hashes[name] != m.group(1) and name in {c[3] for c in COMPONENTS}:
                print(f"warning: {name} has two hashes; using {hashes[name]}", file=sys.stderr)
            hashes.setdefault(name, m.group(1))
    return hashes


def from_package(pkg_hash, candidates):
    for name in candidates:
        for base in (PKG, CACHE):
            path = os.path.join(base, pkg_hash, name)
            if os.path.isfile(path):
                return open(path, encoding="utf-8", errors="replace").read()
    extracted = os.path.join(CACHE, pkg_hash)
    tarball = extracted + ".tar.gz"
    if os.path.isfile(tarball):
        with tarfile.open(tarball) as t:
            members = {m.name: m for m in t.getmembers()}
            for name in candidates:
                m = members.get(f"{pkg_hash}/{name}")
                f = t.extractfile(m) if m else None
                if f:
                    return f.read().decode("utf-8", errors="replace")
    return None


def check(binary):
    """Fails when the binary links a family the notices don't cover, or one that must not be there."""
    symbols = subprocess.run(["nm", binary], capture_output=True, text=True, check=True).stdout
    # A stripped binary would match nothing and pass: Ghostty's own entry point must be there.
    if "_ghostty_init" not in symbols:
        sys.exit(f"{binary}: no Ghostty symbols (stripped, or not Corral): can't check what it links")
    current = open(OUT, encoding="utf-8").read() if os.path.isfile(OUT) else ""
    if current != render(zon_hashes()):
        sys.exit(f"{os.path.relpath(OUT, ROOT)} is out of date: run scripts/notices.py")
    titles = [c[0] for c in COMPONENTS]
    problems = []
    for pattern, component in FAMILIES:
        if not re.search(pattern, symbols):
            continue
        if component is None:
            problems.append(f"links {pattern} (not allowed / not in the notices)")
        elif not any(t.startswith(component) for t in titles):
            problems.append(f"links {component} without a notice")
    if problems:
        sys.exit(f"{binary}: " + "; ".join(problems))
    print(f"{os.path.basename(binary)}: every linked library family is covered")


def render(hashes):
    sections, missing = [], []
    for title, license, url, dep, sources in COMPONENTS:
        text = None
        for src in sources:
            if src.startswith("inline:"):
                text = src[len("inline:"):]
            elif src.startswith("file:"):
                text = open(os.path.join(GHOSTTY, src[5:]), encoding="utf-8").read()
            elif src.startswith("pkg:"):
                found = sorted(glob.glob(os.path.join(PKG, src[4:])))
                text = open(found[0], encoding="utf-8").read() if found else None
            elif src.startswith("spm:"):
                # SwiftPM checkout (resolved by the app build).
                path = os.path.join(ROOT, ".build", "checkouts", src[4:])
                text = open(path, encoding="utf-8").read() if os.path.isfile(path) else None
            elif src.startswith("zig:"):
                zig = glob.glob(os.path.join(ROOT, "vendor", "zig-*", src[4:]))
                text = open(zig[0], encoding="utf-8").read() if zig else None
            elif dep and dep in hashes:
                # "A+B": both files, one after the other (a notice and the full license text).
                parts = [from_package(hashes[dep], [name]) for name in src.split("+")]
                text = "\n\n".join(parts) if all(parts) else None
            if text:
                break
        if not text:
            missing.append(title)
            continue
        sections.append(f"{'=' * 78}\n{title}\nLicense: {license}\n{url}\n{'=' * 78}\n\n{text.strip()}\n")
    if missing:
        sys.exit("no license text found for: " + ", ".join(missing) + " (run scripts/build-ghostty.sh first)")
    return HEADER + "\n".join(sections)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        return check(sys.argv[2])
    text = render(zon_hashes())
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({text.count(chr(10) + 'License: ')} components)")


HEADER = ("Corral includes the following third-party software. Their licenses follow.\n"
          "The terminal engine is Ghostty's libghostty, built without its translations (GNU\n"
          "gettext) and crash reporter (Sentry), so neither is included.\n\n")



if __name__ == "__main__":
    main()
