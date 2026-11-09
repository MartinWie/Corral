#!/usr/bin/env python3
"""Fails when shipped files contain this Mac's home path, user, full or host name, the git email, an extra
needle, or extended attributes.

Usage: leak-scan.py [--skip-xattrs] <file or folder>...
Matches ASCII/UTF-8 and UTF-16 text, case-insensitively. Extra needles (one per line, e.g. an employer's
name) come from ~/.config/corral/leak-needles, which stays outside the repo on purpose.
Run it before signing: a Developer ID signature carries the developer's name. com.apple.provenance is
allowed: macOS tags every file written from a downloaded app's shell with it, and it names no one.
"""
import getpass
import os
import subprocess
import sys


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


args = sys.argv[1:]
skip_xattrs = "--skip-xattrs" in args
roots = [arg for arg in args if arg != "--skip-xattrs"]
if not roots:
    sys.exit(__doc__)

home = os.path.expanduser("~")
needles = {home, f"/Users/{getpass.getuser()}", getpass.getuser(), run("git", "config", "user.email"),
           run("scutil", "--get", "LocalHostName"), run("scutil", "--get", "ComputerName")}
full_name = run("id", "-F")
if full_name:
    needles.add(full_name)
    # Surnames are distinctive; short or common first names would match license texts.
    needles.update(part for part in full_name.split() if len(part) >= 7)
extra = os.path.expanduser("~/.config/corral/leak-needles")
if os.path.isfile(extra):
    needles.update(line.strip() for line in open(extra, encoding="utf-8") if line.strip() and not line.startswith("#"))
needles.discard("")
patterns = {needle.lower().encode(encoding) for needle in needles for encoding in ("utf-8", "utf-16-le", "utf-16-be")}

found, files = [], 0
for root in roots:
    if not skip_xattrs:
        found += [f"extended attribute: {line}" for line in run("xattr", "-r", root).splitlines()
                  if not line.endswith(": com.apple.provenance")]
    paths = [root] if os.path.isfile(root) else [os.path.join(d, n) for d, _, names in os.walk(root) for n in names]
    for path in paths:
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        files += 1
        with open(path, "rb") as handle:
            data = handle.read().lower()
        if any(pattern in data for pattern in patterns):
            found.append(f"{path}: contains a home path, user, host or full name, the git email or an extra needle")

if files == 0:
    sys.exit(f"leak-scan: no files under {' '.join(roots)}")
if found:
    sys.exit("leak-scan:\n  " + "\n  ".join(found[:20]))
print(f"leak-scan: {files} files clean")
