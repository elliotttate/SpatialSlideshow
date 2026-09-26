#!/usr/bin/env python3
"""Optional real Apple model integration. Requires a user-supplied Trip export."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import time
from test_support import ROOT, TEST_ROOT, developer_environment, enum_declarations

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--album", required=True, choices=["Trip"], help="Confirm the supplied image belongs to Trip")
parser.add_argument("image", type=Path, help="An existing photo exported by you from Trip; it is read only")
parser.add_argument("--tools", type=Path, default=ROOT / "build/Spatial Slideshow.app/Contents/Resources")
args = parser.parse_args()
source = args.image.expanduser().resolve(strict=True)
if not source.is_file():
    parser.error("image must be a file")
for helper in ("GenerateScene", "ExpandPhoto", "RenderSlideshow"):
    if not (args.tools / helper).is_file():
        parser.error("Build the app first or supply --tools with its helper directory")
env = developer_environment()
output = TEST_ROOT / ("model-" + time.strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True)
with tempfile.TemporaryDirectory(prefix="spatial-model-test-") as scratch:
    scratch = Path(scratch)
    enums = scratch / "Enums.swift"
    enums.write_text(enum_declarations())
    binary = scratch / "ExpansionPipelineTest"
    sources = ["ClipCacheCatalog", "PlaybackPipeline", "PhotoExpansion", "VideoClipCache", "StorageRecovery"]
    subprocess.run(["xcrun", "swiftc", "-O", str(enums)] + [str(ROOT / "Sources" / f"{name}.swift") for name in sources] +
                   [str(ROOT / "Tests/ExpansionPipelineTest.swift"), "-o", str(binary)], env=env, check=True)
    subprocess.run([str(binary), str(source), str(args.tools.resolve()), str(output)], check=True, env=env)
print(f"Model test output: {output}")
print("Reports and rendered media are local/ignored; review source composition, color, and motion before sharing anything.")
