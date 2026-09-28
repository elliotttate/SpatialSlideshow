#!/usr/bin/env python3
"""Install Spatial Slideshow's optional, pinned FLUX.2 Klein runtime and models.

The app installs its own relocatable Python; no Homebrew, Xcode or separately
installed interpreter is required. About 8.7 GB of model weights are downloaded
when missing. Photos are never read by this setup script.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import uuid

# Imports must never modify the signed application bundle.
sys.dont_write_bytecode = True
from SetupSupport import (check_python, install_environment, installation_lock,
                          literal_configuration, run, say)

CONFIGURATION_NAMES = ("MODEL", "MODEL_REVISION", "ADAPTER", "ADAPTER_REVISION",
                       "ADAPTER_FILE", "BACKEND", "PINNED_PACKAGES", "WEIGHTS", "ADAPTER_WEIGHT")
GIB = 1024 ** 3


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
    # Importing the inference helper used to require its dependencies before the
    # installer could install them. Read only its literal pinned configuration.
    return literal_configuration(path, CONFIGURATION_NAMES)


def require_space(path, additional_bytes, headroom=2 * GIB):
    ancestor = Path(path).absolute()
    while not ancestor.exists():
        ancestor = ancestor.parent
    free = shutil.disk_usage(ancestor).free
    required = additional_bytes + headroom
    if free < required:
        raise RuntimeError(f"Not enough free storage: {free / GIB:.1f} GiB available; "
                           f"{required / GIB:.1f} GiB needed for this installation and working space. "
                           "Free space and retry. Existing models and photo caches were kept.")


def download_models(config):
    # This function runs only inside the newly installed, pinned environment.
    from huggingface_hub import snapshot_download, hf_hub_download, constants
    from tqdm.auto import tqdm

    class SetupProgress(tqdm):
        def __init__(self, *args, **kwargs):
            self.last_percent = -1
            kwargs["disable"] = False
            super().__init__(*args, **kwargs)

        def display(self, msg=None, pos=None):
            if self.total:
                percent = min(100, int(100 * self.n / self.total))
                if percent != self.last_percent:
                    self.last_percent = percent
                    say(f"{self.desc or 'Model download'}: {percent}%")

    say("Checking the pinned model download sizes · cached files are reused")
    model_files = snapshot_download(config.MODEL, revision=config.MODEL_REVISION, dry_run=True)
    adapter = hf_hub_download(config.ADAPTER, config.ADAPTER_FILE,
                              revision=config.ADAPTER_REVISION, dry_run=True)
    needed = sum(item.file_size or 0 for item in [*model_files, adapter] if item.will_download)
    if any(item.file_size is None for item in [*model_files, adapter] if item.will_download):
        raise RuntimeError("The model server did not provide download sizes. Retry when the connection is available.")
    # Hugging Face owns resumable .incomplete files and content-addressed blobs;
    # use its cache path so a user's relocated cache gets the correct disk check.
    require_space(Path(constants.HF_HUB_CACHE), needed)
    say(f"Downloading pinned model weights · {needed / GIB:.2f} GiB remaining")
    model = Path(snapshot_download(config.MODEL, revision=config.MODEL_REVISION,
                                   tqdm_class=SetupProgress, max_workers=2))
    hf_hub_download(config.ADAPTER, config.ADAPTER_FILE, revision=config.ADAPTER_REVISION,
                    tqdm_class=SetupProgress)
    # The capability router accepts a repository ID. Its offline main reference
    # must resolve to the same immutable snapshot whose checksums the helper uses.
    reference = model.parent.parent / "refs/main"
    reference.parent.mkdir(parents=True, exist_ok=True)
    temporary = reference.with_name("main.spatial-slideshow-" + uuid.uuid4().hex)
    try:
        temporary.write_text(config.MODEL_REVISION)
        os.replace(temporary, reference)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--use-existing", type=Path, help="Register an existing compatible Python virtual environment, without downloading anything.")
    parser.add_argument("--python", type=Path, help="Python 3.12 executable used to create the managed environment.")
    parser.add_argument("--runtime-root", type=Path, help="Override the runtime registration directory (for isolated installation/testing).")
    parser.add_argument("--helper-script", type=Path, help="Optional explicit path to ExpandPhotoKlein.py.")
    parser.add_argument("--download-models", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    setup_lock = None
    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("FLUX.2 Klein requires an Apple Silicon Mac.")
        helper = helper_script(args.helper_script)
        config = load_helper(helper)
        if args.download_models:
            download_models(config)
            return 0
        root = (args.runtime_root.expanduser().absolute() if args.runtime_root else
                Path.home() / "Library/Application Support/Photos Spatial Slideshow/Klein Runtime")
        setup_lock = installation_lock(root)
        setup_lock.__enter__()
        if args.use_existing:
            # Do not resolve symlinks: /venv/bin/python must retain its venv path.
            python = args.use_existing.expanduser().absolute()
            check_python(python)
        else:
            requested = str(args.python.expanduser()) if args.python else shutil.which("python3.12")
            if requested is None and sys.version_info[:2] == (3, 12):
                requested = sys.executable
            if not requested:
                raise RuntimeError("Use the Download Model button in Spatial Slideshow to install its portable Python 3.12 runtime.")
            # Prebuilt MLX, PyTorch and their dependencies need more room than the
            # lightweight Draw Things bridge. This leaves existing venvs intact.
            require_space(root, 2 * GIB)
            python = install_environment(root, requested, "klein")
            environment_vars = dict(os.environ, HF_HUB_DISABLE_XET="1", HF_HUB_DISABLE_TELEMETRY="1",
                                    HF_HUB_DISABLE_PROGRESS_BARS="0", PYTHONDONTWRITEBYTECODE="1")
            environment_vars.pop("HF_HUB_OFFLINE", None)
            run([python, "-u", Path(__file__).resolve(), "--download-models", "--helper-script", helper], env=environment_vars)
        say("Verifying runtime and model checksums · no GPU model is loaded")
        checked = subprocess.run([str(python), str(helper), "--check"], text=True, capture_output=True, timeout=300)
        if checked.returncode:
            raise RuntimeError((checked.stderr or checked.stdout).strip() or "Klein runtime verification failed.")
        identity = json.loads(checked.stdout)
        registration = {"schema": 1, "python": str(python), "backend": config.BACKEND,
                        "model": config.MODEL, "model_revision": config.MODEL_REVISION,
                        "adapter_revision": config.ADAPTER_REVISION,
                        "runtime_versions": identity["runtime_versions"]}
        destination = root / "runtime.json"
        temporary = destination.with_name(".runtime-" + uuid.uuid4().hex + ".json")
        try:
            temporary.write_text(json.dumps(registration, indent=2, sort_keys=True) + "\n")
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        say("Complete. Choose FLUX.2 Klein in Spatial Slideshow → Settings → Photo Edge Expansion.")
        print("Runtime registration: " + str(destination), flush=True)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        detail = str(error)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail += "\n" + str(error.stderr).strip()
        print("ERROR: " + detail, file=sys.stderr, flush=True)
        return 1
    finally:
        if setup_lock is not None:
            setup_lock.__exit__(None, None, None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
