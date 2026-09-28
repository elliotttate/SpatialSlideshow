#!/usr/bin/env python3
"""Test real runtime-installation code without reading Photos or invoking a model.

The optional --bootstrap-integration downloads the pinned 25 MB portable Python
archive into a temporary root, verifies HTTPS/imports, and exercises reuse and
two repairs (up to three archive downloads). It does not install model weights
or touch the user's managed runtime. The default suite stays offline.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
from test_support import ROOT, REPORTS, developer_environment, enum_declarations

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bootstrap-integration", action="store_true")
args = parser.parse_args()
environment = developer_environment()
REPORTS.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="spatial-runtime-installer-test-") as temporary:
    temporary = Path(temporary)
    enums = temporary / "Enums.swift"
    enums.write_text(enum_declarations())
    binary = temporary / "RuntimeInstallerTest"
    # Compile actual production dependencies, as the persistent-cache suite
    # does. No mock RuntimeInstaller, HelperProcess, or runtime lookup is used.
    sources = ["PlaybackPipeline", "SceneCache", "HelperProcess", "RuntimeInstaller", "NativeExtendRecovery",
               "PhotoExpansion", "VideoClipCache", "StorageRecovery", "ClipCacheCatalog"]
    subprocess.run(["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos27.0", "-file-prefix-map", f"{ROOT}=.",
                    str(enums), *[str(ROOT / "Sources" / (name + ".swift")) for name in sources],
                    str(ROOT / "Tests/RuntimeInstallerTest.swift"), "-o", str(binary)],
                   env=environment, check=True)
    test_environment = dict(os.environ)
    for key in ("PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "VIRTUAL_ENV", "CONDA_PREFIX", "HF_HUB_OFFLINE"):
        test_environment[key] = "runtime-test-poison"
    test_environment["PATH"] = "/runtime-test-untrusted-bin"
    command = [str(binary), "--report", str(REPORTS / ("runtime-bootstrap-integration.json" if args.bootstrap_integration else "runtime-installer.json"))]
    if args.bootstrap_integration:
        command.append("--bootstrap-integration")
    subprocess.run(command, env=test_environment, check=True)
