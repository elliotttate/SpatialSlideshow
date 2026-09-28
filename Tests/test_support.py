"""Local test utilities. Fixtures are generated; no Photos library is accessed."""
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = ROOT / "build/tests"
REPORTS = TEST_ROOT / "reports"

def developer_environment():
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = subprocess.check_output(
        ["bash", str(ROOT / "Scripts/common.sh")], text=True, env=env).strip()
    return env

def ensure_fixtures():
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise SystemExit("Tests require ffmpeg and ffprobe on PATH; app builds do not.")
    directory = TEST_ROOT / "fixtures"
    directory.mkdir(parents=True, exist_ok=True)
    REPORTS.mkdir(parents=True, exist_ok=True)
    videos = {
        "playback-short.mp4": ("testsrc2=size=640x360:rate=30", "1"),
        "playback-second.mp4": ("color=c=royalblue:size=640x360:rate=30", "1"),
        "playback-long.mp4": ("testsrc2=size=640x360:rate=30", "32"),
        "playback-screen-saver.mp4": ("testsrc2=size=640x360:rate=30", "6"),
    }
    for filename, (source, duration) in videos.items():
        target = directory / filename
        if not target.is_file():
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", source,
                            "-t", duration, "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                            "-movflags", "+faststart", str(target)], check=True)
    for name, frequency in (("tone1.wav", 440), ("tone2.wav", 660)):
        target = directory / name
        if not target.is_file():
            rate = 44100
            with wave.open(str(target), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(rate)
                samples = [int(3000 * math.sin(2 * math.pi * frequency * frame / rate)) for frame in range(rate // 4)]
                output.writeframes(struct.pack("<" + "h" * len(samples), *samples))
    (directory / "invalid.mp3").write_text("Intentionally invalid synthetic audio fixture.\n")
    (directory / "provenance.json").write_text(json.dumps({
        "source": "Generated test patterns, solid colors, and sine waves. No user media.",
        "video": list(videos), "audio": ["tone1.wav", "tone2.wav", "invalid.mp3"],
    }, indent=2) + "\n")
    return directory

def enum_declarations():
    options = (ROOT / "Sources/SlideshowOptions.swift").read_text()
    return "import Foundation\nimport CryptoKit\n" + options[options.index("enum MotionStyle:"):options.index("struct SlideshowOptions:")]
