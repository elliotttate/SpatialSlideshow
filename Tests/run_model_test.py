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
parser.add_argument("--backend", choices=["appleCleanup", "fluxKlein", "drawThingsFlux", "applePhotosExtend"], default="appleCleanup")
parser.add_argument("--percent", type=int, choices=range(1, 21), default=5)
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
    sources = ["ClipCacheCatalog", "PlaybackPipeline", "HelperProcess", "RuntimeInstaller", "NativeExtendRecovery", "PhotoExpansion", "VideoClipCache", "StorageRecovery"]
    subprocess.run(["xcrun", "swiftc", "-O", str(enums)] + [str(ROOT / "Sources" / f"{name}.swift") for name in sources] +
                   [str(ROOT / "Tests/ExpansionPipelineTest.swift"), "-o", str(binary)], env=env, check=True)
    subprocess.run([str(binary), str(source), str(args.tools.resolve()), str(output), args.backend, str(args.percent)], check=True, env=env)
    # Imported Python helpers must never leave bytecode inside a sealed bundle.
    bundle = args.tools.resolve().parent.parent
    if bundle.suffix == ".app" and (bundle / "Contents/_CodeSignature/CodeResources").is_file():
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
print(f"Model test output: {output}")
print("Reports and rendered media are local/ignored; review source composition, color, and motion before sharing anything.")
