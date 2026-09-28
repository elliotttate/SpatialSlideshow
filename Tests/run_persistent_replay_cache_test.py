#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
from test_support import developer_environment, ensure_fixtures, REPORTS

root = Path(__file__).resolve().parents[1]
options = (root / "Sources/SlideshowOptions.swift").read_text()
declarations = "import Foundation\nimport CryptoKit\n" + options[options.index("enum MotionStyle:"):options.index("struct SlideshowOptions:")]
env = developer_environment()
fixtures = ensure_fixtures()
with tempfile.TemporaryDirectory(prefix="spatial-persistent-replay-test-") as temporary:
    temporary = Path(temporary)
    enums = temporary / "Enums.swift"
    enums.write_text(declarations)
    executable = temporary / "PersistentReplayCacheTest"
    subprocess.run(["xcrun", "swiftc", "-O", str(enums), str(root / "Sources/PlaybackPipeline.swift"), str(root / "Sources/HelperProcess.swift"), str(root / "Sources/NativeExtendRecovery.swift"), str(root / "Sources/PhotoExpansion.swift"), str(root / "Sources/VideoClipCache.swift"), str(root / "Sources/StorageRecovery.swift"), str(root / "Sources/ClipCacheCatalog.swift"), str(root / "Tests/PersistentReplayCacheTest.swift"), "-o", str(executable)], env=env, check=True)
    subprocess.run([str(executable), str(fixtures / "playback-short.mp4"), str(temporary / "cache"), str(REPORTS / "persistent-replay-cache-test.json")], check=True)
