#!/usr/bin/env python3
"""Run clean-checkout tests with synthetic fixtures, never personal photos/models."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
from test_support import ROOT, TEST_ROOT, REPORTS, developer_environment, ensure_fixtures

ALL = ["storage", "preparation", "motion", "cache", "persistent-cache", "video-cache",
       "playback", "displayed-playback", "navigation", "fullscreen", "music", "display-sleep", "helper-process", "native-extend-recovery", "apple-model-setup", "runtime-installer"]
CORE = ALL[:6]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--core", action="store_true", help="Skip WindowServer, audio-playback and power-assertion checks")
parser.add_argument("--only", action="append", choices=ALL, help="Run one named check (repeatable)")
args = parser.parse_args()
env = developer_environment()
fixtures = ensure_fixtures()
selected = args.only or (CORE if args.core else ALL)
logs = TEST_ROOT / "logs"
executables = TEST_ROOT / "bin"
logs.mkdir(parents=True, exist_ok=True)
executables.mkdir(parents=True, exist_ok=True)

def swift(name, sources):
    executable = executables / name
    return [["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos27.0", "-file-prefix-map", f"{ROOT}=."] +
            [str(ROOT / source) for source in sources] + ["-o", str(executable)]], str(executable)

def commands(name):
    if name == "runtime-installer":
        return [[sys.executable, str(ROOT / "Tests/run_runtime_installer_test.py")]]
    if name == "apple-model-setup":
        binary = str(executables / "AppleModelSetupTest")
        return [["xcrun", "clang", "-fobjc-arc", "-fmodules", "-framework", "Foundation", str(ROOT / "Tests/AppleModelSetupTest.m"), "-o", binary], [binary]]
    if name in ("cache", "persistent-cache", "video-cache"):
        script = {"cache": "run_clip_cache_test.py", "persistent-cache": "run_persistent_replay_cache_test.py", "video-cache": "run_video_clip_cache_test.py"}[name]
        return [[sys.executable, str(ROOT / "Tests" / script)]]
    if name == "motion":
        binary = str(executables / "ExpansionMotionTest")
        return [["xcrun", "clang++", "-O2", "-std=c++17", str(ROOT / "Tests/ExpansionMotionTest.cpp"), "-o", binary], [binary]]
    tests = {
        "helper-process": ("HelperProcessTest", ["HelperProcess"], []),
        "native-extend-recovery": ("NativeExtendRecoveryTest", ["NativeExtendRecovery"], []),
        "storage": ("StorageRecoveryTest", ["StorageRecovery", "AlbumPreparationQueue"], []),
        "preparation": ("AlbumPreparationQueueTest", ["AlbumPreparationQueue"], [str(REPORTS / "preparation.json")]),
        "playback": ("ContinuousPlaybackTest", ["ContinuousPlayback"], [str(fixtures / "playback-short.mp4")]),
        "displayed-playback": ("DisplayedPlaybackTest", ["ContinuousPlayback", "SlideshowPlayerView"], [str(fixtures / "playback-short.mp4"), str(fixtures / "playback-second.mp4"), str(REPORTS / "displayed-playback.json")]),
        "navigation": ("PhotoNavigationTest", ["ContinuousPlayback", "SlideshowPlayerView"], [str(fixtures / "playback-short.mp4"), str(fixtures / "playback-long.mp4"), str(REPORTS / "navigation.json")]),
        "fullscreen": ("FullscreenControlsTest", ["ContinuousPlayback", "SlideshowPlayerView"], [str(REPORTS / "fullscreen.json"), str(fixtures / "playback-long.mp4")]),
        "music": ("MusicPlaybackTest", ["MusicPlayback"], [str(fixtures)]),
        "display-sleep": ("DisplaySleepInhibitorTest", ["DisplaySleepInhibitor"], [str(REPORTS / "display-sleep")]),
    }
    test, sources, arguments = tests[name]
    compile_commands, binary = swift(test, [f"Sources/{source}.swift" for source in sources] + [f"Tests/{test}.swift"])
    return compile_commands + [[binary] + arguments]

results = []
for name in selected:
    started = time.monotonic()
    print(f"RUN {name}", flush=True)
    error = None
    log = logs / f"{name}.log"
    try:
        with log.open("w") as output:
            for command in commands(name):
                subprocess.run(command, cwd=ROOT, env=env, check=True, stdout=output, stderr=subprocess.STDOUT, timeout=300)
    except (subprocess.SubprocessError, OSError) as exception:
        error = str(exception)
    results.append({"test": name, "passed": error is None, "seconds": round(time.monotonic() - started, 2), "log": str(log.relative_to(ROOT)), "error": error})
    print(f"{'PASS' if error is None else 'FAIL'} {name} ({results[-1]['seconds']}s)", flush=True)
    if error:
        print(log.read_text()[-5000:], flush=True)
summary = {"passed": all(result["passed"] for result in results), "scope": "Synthetic media only; no PhotoKit library requests or private model inference.", "results": results}
(REPORTS / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(f"Reports: {REPORTS}")
sys.exit(0 if summary["passed"] else 1)
