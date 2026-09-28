#!/usr/bin/env python3
"""Compile the production cache and enum declarations without the app's SwiftUI view."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from test_support import developer_environment, ensure_fixtures, REPORTS

root = Path(__file__).resolve().parents[1]
options = (root / "Sources/SlideshowOptions.swift").read_text()
# Use the exact production enums so the test cannot diverge from the app.
declarations = "import Foundation\nimport CryptoKit\n" + options[options.index("enum MotionStyle:"):options.index("struct SlideshowOptions:")]
env = developer_environment()
fixtures = ensure_fixtures()
with tempfile.TemporaryDirectory(prefix="spatial-cache-test-") as temporary:
    temporary = Path(temporary)
    enums = temporary / "Enums.swift"
    enums.write_text(declarations)
    executable = temporary / "SceneCacheTest"
    subprocess.run(["xcrun", "swiftc", str(enums), str(root / "Sources/ClipCacheCatalog.swift"), str(root / "Sources/SceneCache.swift"), str(root / "Sources/PlaybackPipeline.swift"), str(root / "Sources/HelperProcess.swift"), str(root / "Sources/RuntimeInstaller.swift"), str(root / "Sources/NativeExtendRecovery.swift"), str(root / "Sources/PhotoExpansion.swift"), str(root / "Sources/VideoClipCache.swift"), str(root / "Sources/StorageRecovery.swift"), str(root / "Tests/SceneCacheTest.swift"), "-o", str(executable)], env=env, check=True)
    subprocess.run([str(executable)], check=True, env=env)
