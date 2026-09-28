#!/usr/bin/env python3
"""Exercise production video caching with SDR/audio/orientation, HLG and edits."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from test_support import developer_environment, ensure_fixtures, REPORTS

root = Path(__file__).resolve().parents[1]
env = developer_environment()
fixtures = ensure_fixtures()

def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)

def probe(path):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))

with tempfile.TemporaryDirectory(prefix="spatial-video-cache-test-") as temporary:
    temp = Path(temporary)
    raw = temp / "sdr-raw.mov"
    sdr = temp / "sdr-rotated.mov"
    hdr = temp / "hlg.mov"
    run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-c:a", "aac", str(raw)])
    run(["ffmpeg", "-v", "error", "-i", str(raw), "-c", "copy", "-metadata:s:v:0", "rotate=90", str(sdr)])
    run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-t", "0.5", "-c:v", "libx265", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", "-tag:v", "hvc1", str(hdr)])
    options = (root / "Sources/SlideshowOptions.swift").read_text()
    enums = temp / "Enums.swift"
    enums.write_text("import Foundation\nimport CryptoKit\n" + options[options.index("enum MotionStyle:"):options.index("struct SlideshowOptions:")])
    executable = temp / "VideoClipCacheTest"
    run(["xcrun", "swiftc", str(enums), str(root / "Sources/ClipCacheCatalog.swift"), str(root / "Sources/PlaybackPipeline.swift"), str(root / "Sources/HelperProcess.swift"), str(root / "Sources/RuntimeInstaller.swift"), str(root / "Sources/NativeExtendRecovery.swift"), str(root / "Sources/PhotoExpansion.swift"), str(root / "Sources/VideoClipCache.swift"), str(root / "Sources/StorageRecovery.swift"), str(root / "Tests/VideoClipCacheTest.swift"), "-o", str(executable)], env=env)
    cache = temp / "cache"
    cache.mkdir()
    run([str(executable), str(cache), str(sdr), str(hdr)])
    run([str(executable), str(cache), "--lookup"])
    result = json.loads((cache / "result.json").read_text())
    result["checks"].append("A new process finds the persistent video cache")
    for label, source in (("sdr", sdr), ("hdr", hdr)):
        before, after = probe(source), probe(result[label])
        src = next(track for track in before["streams"] if track["codec_type"] == "video")
        dst = next(track for track in after["streams"] if track["codec_type"] == "video")
        for field in ("codec_name", "width", "height", "pix_fmt", "color_space", "color_transfer", "color_primaries"):
            assert src.get(field) == dst.get(field), (label, field, src.get(field), dst.get(field))
        assert abs(float(before["format"]["duration"]) - float(after["format"]["duration"])) < 0.05
        assert [s["codec_type"] for s in before["streams"]] == [s["codec_type"] for s in after["streams"]]
        rotations = lambda track: [entry.get("rotation") for entry in track.get("side_data_list", []) if "rotation" in entry]
        assert rotations(src) == rotations(dst)
        result["checks"].append(f"{label.upper()} passthrough preserves codec, resolution, pixel format, color tags, duration, orientation and audio track presence")
    edited = probe(result["edited"])
    assert any(track["codec_type"] == "audio" for track in edited["streams"])
    result["checks"].append("Edited composition export preserves its audio track")
    result["scope"] = "Actual production export/cache code using generated AV assets; includes HDR, SDR, native rotation, audio, edited composition, active cancellation and process restart. Photos/iCloud permission request is covered by app integration."
    for field in ("sdr", "hdr", "edited"):
        del result[field]
    evidence = REPORTS / "video-clip-cache-test.json"
    evidence.write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS {len(result['checks'])} video cache checks")
