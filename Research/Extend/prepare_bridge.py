#!/usr/bin/env python3
"""Prepare a single user-supplied Trip fixture; never attach or change security."""
import argparse
import hashlib
import json
import shutil
import subprocess
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / "build/research/extend-bridge"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="An exported photo from the Trip album")
    parser.add_argument("--album", required=True, choices=["Trip"])
    parser.add_argument("--control", action="store_true", help="Run in our owned process, not Photos")
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    bridge = BUILD / "SpatialExtendBridge.dylib"
    if not bridge.is_file():
        parser.error("Build first: bash Research/Extend/build_bridge.sh")
    base = (BUILD / "controls") if args.control else (
        Path.home() / "Library/Containers/com.apple.Photos/Data/Library/Caches/SpatialSlideshow-ExtendResearch"
    )
    job = base / str(uuid.uuid4())
    job.mkdir(parents=True, exist_ok=False, mode=0o700)
    shutil.copyfile(source, job / "input.heic")
    digest = hashlib.sha256((job / "input.heic").read_bytes()).hexdigest()
    shutil.copy2(bridge, job / "SpatialExtendBridge.dylib")
    request = {"schema": 1, "album": args.album, "sourceSHA256": digest,
               "bridgeSHA256": hashlib.sha256(bridge.read_bytes()).hexdigest(),
               "control": args.control, "geometry": "one-sixth-width horizontal borders"}
    (job / "request.json").write_text(json.dumps(request, indent=2) + "\n")
    (BUILD / ("last-control-job.txt" if args.control else "pending-photos-job.txt")).write_text(str(job) + "\n")
    print(f"Prepared job: {job}", flush=True)
    if args.control:
        result = subprocess.run([str(BUILD / "SpatialExtendBridgeHost"), str(job / bridge.name), str(job)],
                                capture_output=True, text=True, timeout=40)
        (job / "host.log").write_text(result.stdout + result.stderr)
        print(result.stdout or result.stderr)
        if result.returncode not in (0, 10):
            raise SystemExit(f"Control harness failed: exit {result.returncode}")
        status = json.loads((job / "result.json").read_text())
        if status.get("control") is not True or status.get("originalPhotos") is not False:
            raise SystemExit("Control host identity mismatch")
        print("Control harness completed. This is not a successful Photos-host test.")
    else:
        print("Ready for a later Photos-host test. No debugger attachment or inference was performed.")


if __name__ == "__main__":
    main()
