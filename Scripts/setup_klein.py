#!/usr/bin/env python3
"""Install Spatial Slideshow's optional, pinned FLUX.2 Klein runtime and models.

Run once while online. About 8.7 GB of model weights plus the Python runtime are
downloaded to this Mac. Photos are never read by this setup script.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def helper_script(explicit=None):
    if explicit:
        candidates = [Path(explicit).expanduser()]
    else:
        base = Path(__file__).resolve().parent
        candidates = [base / "ExpandPhotoKlein.py", base / "Tools/ExpandPhotoKlein.py",
                      base.parent / "Sources/ExpandPhotoKlein.py"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError("ExpandPhotoKlein.py is missing. Run this script from the Spatial Slideshow app or source checkout.")


def load_helper(path):
    spec = importlib.util.spec_from_file_location("klein_setup_configuration", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(argv, **kwargs):
    print("SETUP " + str(argv[0]) + " · " + " ".join(str(arg) for arg in argv[1:3]), flush=True)
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--use-existing", type=Path, help="Register an existing compatible Python virtual environment, without downloading anything.")
    parser.add_argument("--python", type=Path, help="Python 3.12 executable used to create the managed environment.")
    parser.add_argument("--helper-script", type=Path, help="Optional explicit path to ExpandPhotoKlein.py.")
    args = parser.parse_args()
    try:
        helper = helper_script(args.helper_script)
        config = load_helper(helper)
        root = config.support_root() / "Klein Runtime"
        root.mkdir(parents=True, exist_ok=True)
        if args.use_existing:
            # Do not resolve symlinks: /venv/bin/python must retain its venv path.
            python = args.use_existing.expanduser().absolute()
            if not python.is_file() or not os.access(python, os.X_OK):
                raise RuntimeError("The selected Python executable is missing or not executable.")
        else:
            requested = str(args.python.expanduser()) if args.python else shutil.which("python3.12")
            if requested is None and sys.version_info[:2] == (3, 12):
                requested = sys.executable
            if not requested:
                raise RuntimeError("Install Python 3.12, then run this script again, or pass --python /path/to/python3.12.")
            run([requested, "-c", "import sys; assert sys.version_info[:2] == (3,12), 'Python 3.12 is required'"])
            environment = root / "venv"
            python = environment / "bin/python"
            if not python.exists():
                print("SETUP Creating the managed Python 3.12 environment", flush=True)
                run([requested, "-m", "venv", environment])
            print("SETUP Installing pinned local model packages", flush=True)
            run([python, "-m", "pip", "install", *[f"{name}=={version}" for name, version in config.PINNED_PACKAGES.items()]])
            print("SETUP Downloading pinned model weights (about 8.7 GB; existing files are reused)", flush=True)
            download = r'''
import json, os, sys
from pathlib import Path
from huggingface_hub import snapshot_download, hf_hub_download
config = json.loads(sys.argv[1])
model = Path(snapshot_download(config["model"], revision=config["model_revision"]))
hf_hub_download(config["adapter"], config["adapter_file"], revision=config["adapter_revision"])
# The capability router accepts a repository ID. Pin its local main reference to
# the same verified snapshot; inference will later run strictly offline.
reference = model.parent.parent / "refs/main"
reference.parent.mkdir(parents=True, exist_ok=True)
temporary = reference.with_name("main.spatial-slideshow-setup")
temporary.write_text(config["model_revision"])
os.replace(temporary, reference)
'''
            environment_vars = dict(os.environ, HF_HUB_DISABLE_XET="1", HF_HUB_DISABLE_TELEMETRY="1")
            environment_vars.pop("HF_HUB_OFFLINE", None)
            run([python, "-c", download, json.dumps({"model": config.MODEL, "model_revision": config.MODEL_REVISION,
                "adapter": config.ADAPTER, "adapter_file": config.ADAPTER_FILE, "adapter_revision": config.ADAPTER_REVISION})], env=environment_vars)
        print("SETUP Verifying runtime and model checksums · no GPU model is loaded", flush=True)
        checked = subprocess.run([str(python), str(helper), "--check"], text=True, capture_output=True)
        if checked.returncode:
            raise RuntimeError((checked.stderr or checked.stdout).strip() or "Klein runtime verification failed.")
        identity = json.loads(checked.stdout)
        registration = {"schema": 1, "python": str(python), "backend": config.BACKEND,
                        "model": config.MODEL, "model_revision": config.MODEL_REVISION,
                        "adapter_revision": config.ADAPTER_REVISION,
                        "runtime_versions": identity["runtime_versions"]}
        destination = root / "runtime.json"
        temporary = destination.with_name(".runtime-" + uuid.uuid4().hex + ".json")
        temporary.write_text(json.dumps(registration, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, destination)
        print("SETUP Complete. Choose FLUX.2 Klein in Spatial Slideshow → Settings → Photo Edge Expansion.", flush=True)
        print("Runtime registration: " + str(destination), flush=True)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
