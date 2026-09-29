#!/usr/bin/env python3
"""Fail closed when the built app's sandbox or dependency boundary changes."""
import pathlib
import os
import plistlib
import shlex
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1]).resolve()
expected = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-only": True,
    "com.apple.security.files.bookmarks.app-scope": True,
}
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                        check=True, capture_output=True).stdout
if plistlib.loads(signed) != expected:
    sys.exit("FAIL: signed entitlements differ from the read-only, offline sandbox policy")
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if any(k.startswith("SU") for k in info):
    sys.exit("FAIL: updater metadata present")
if info.get("CFBundleIdentifier") != "io.github.radmirmoore.codenotch.local":
    sys.exit("FAIL: unexpected app identity")
executable = app / "Contents/MacOS" / info.get("CFBundleExecutable", "")
if not executable.is_file() or not os.access(executable, os.X_OK):
    sys.exit("FAIL: bundle executable is absent or not executable")
if info.get("LSUIElement", False):
    sys.exit("FAIL: app must be discoverable in the Dock, not a hidden UI agent")
package = subprocess.run(["swift", "package", *shlex.split(os.environ.get("SWIFT_FLAGS", "")), "dump-package"], cwd=root,
                         check=True, capture_output=True).stdout
import json
if json.loads(package)["dependencies"]:
    sys.exit("FAIL: third-party package dependencies present")
for source in (root / "Sources").rglob("*.swift"):
    text = source.read_text()
    for forbidden in ("URLSession", "NWConnection", "NWListener", "import Network", "import WebKit",
                      "SecItem", "Process(", "Sparkle", "auth.json", "NSAppleScript"):
        if forbidden in text:
            sys.exit(f"FAIL: prohibited API or credential path {forbidden!r} in {source.name}")
linked = subprocess.run(["otool", "-L", str(app / "Contents/MacOS/CodenotchLocal")],
                        check=True, capture_output=True, text=True).stdout
for line in linked.splitlines()[1:]:
    library = line.strip().split(" (", 1)[0]
    if not library.startswith(("/System/Library/", "/usr/lib/")):
        sys.exit(f"FAIL: non-system dynamic library: {library}")
print("PASS: signed App Sandbox, user-selected read-only folders, no network entitlement,")
print("      no updater metadata, no package dependencies, system dynamic libraries only.")
