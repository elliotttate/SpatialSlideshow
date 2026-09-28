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
    executable = temporary / "ClipCacheTest"
    subprocess.run(["xcrun", "swiftc", str(enums), str(root / "Sources/ClipCacheCatalog.swift"), str(root / "Sources/PlaybackPipeline.swift"), str(root / "Sources/HelperProcess.swift"), str(root / "Sources/RuntimeInstaller.swift"), str(root / "Sources/NativeExtendRecovery.swift"), str(root / "Sources/PhotoExpansion.swift"), str(root / "Sources/VideoClipCache.swift"), str(root / "Sources/StorageRecovery.swift"), str(root / "Tests/ClipCacheTest.swift"), "-o", str(executable)], env=env, check=True)
    evidence = REPORTS / "clip-cache-test.json"
    first = temporary / "first-run.json"
    for output in (first, evidence):
        subprocess.run([str(executable), str(fixtures / "playback-short.mp4"), str(output)], check=True)
    result = json.loads(evidence.read_text())
    assert result["patterns"] == json.loads(first.read_text())["patterns"], "Movement assignment must survive process restarts"
    result["checks"].append("Varied movement assignment survives process restarts")
    evidence.write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS {len(result['checks'])} cache checks including process restart")
