#!/usr/bin/env python3
"""Install the optional pinned Draw Things runtime for Spatial Slideshow.

Only explicit setup downloads files. It never starts a server, changes slideshow
settings, deletes photo caches, or reads photos. Playback uses loopback only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import urllib.request
import uuid

RELEASE = "v26.0910.1"
PORT = 7863
MODEL = "flux_2_klein_4b_i8x.ckpt"
GIB = 1024 ** 3
HEADROOM = 2 * GIB
INITIAL_CONVERSION_HEADROOM = 5 * GIB
ENVIRONMENT_ALLOWANCE = GIB
ASSETS = {
    "gRPCServerCLI-macOS": (249476288, "63620975ba1a1cd7e8253bbc553aeed01650b1cccdb1b1b2bc39821e78014671"),
    "draw-things-cli": (265101616, "70f3768428d2f54daf50f32efc93a9ed3f51953afd3df49a7c5ee1f0b9982ace"),
}
WEIGHTS = {
    MODEL: (3926003712, "19985019d78456d6de025a27f048ddc6aefd4e2e28e4ea1827126841932bb645"),
    "qwen_3_4b_q8p.ckpt": (4535328768, "a24e3f832917aafe7f6186e6dfb96ab19a4a0729cdf60a875b5da20024333350"),
    "flux_2_vae_f16.ckpt": (168534016, "48369d4b1495aec3df0579591f4bf9c199a73cc288130df2359c4a173c5ae864"),
}
# The pinned server externalizes Qwen's tensors after its first load. Both files
# together are a verified representation of the same published model, not a new
# model revision. Keep WEIGHTS above unchanged for stable model identity.
MIGRATED_QWEN = {
    "qwen_3_4b_q8p.ckpt": (389120, "6c203a74336ebc7a153c95414a26a5a5745ee9656b091fff055fff21343d3f5b"),
    "qwen_3_4b_q8p.ckpt-tensordata": (4525654016, "8786ca3526c135aa2334eeb1ce20259bb0b6cd611f84de1b437b0bc3125bee39"),
}
PINNED_PACKAGES = {
    "drawthings-py": "0.4.0", "Pillow": "12.3.0", "numpy": "2.5.3",
    "flatbuffers": "25.12.19", "grpclib": "0.4.9", "betterproto": "2.0.0b7", "fpzip": "1.2.5",
}


def support_root():
    return Path.home() / "Library/Application Support/Photos Spatial Slideshow/Draw Things Runtime"


def say(message):
    print("SETUP " + message, flush=True)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verified(path, expected):
    return path.is_file() and path.stat().st_size == expected[0] and sha(path) == expected[1]


def verified_model(models, name):
    if verified(models / name, WEIGHTS[name]):
        return True
    if name == "qwen_3_4b_q8p.ckpt":
        return all(verified(models / part, expected) for part, expected in MIGRATED_QWEN.items())
    return False


def existing_parent(path):
    current = path.absolute()
    while not current.exists():
        if current == current.parent:
            raise RuntimeError(f"Cannot find the storage volume for {path}.")
        current = current.parent
    return current


def require_space(requirements, conversion_at=None):
    """Reserve working space, including Qwen's temporary first-load copy."""
    volumes = {}
    for destination, additional_bytes in requirements:
        ancestor = existing_parent(destination)
        volume = ancestor.stat().st_dev
        previous = volumes.get(volume, (ancestor, 0))
        volumes[volume] = (previous[0], previous[1] + max(0, additional_bytes))
    for path, additional_bytes in volumes.values():
        free = shutil.disk_usage(path).free
        conversion_here = conversion_at is not None and existing_parent(conversion_at).stat().st_dev == path.stat().st_dev
        headroom = INITIAL_CONVERSION_HEADROOM if conversion_here else HEADROOM
        required = additional_bytes + headroom
        if free < required:
            reason = "5 GiB for Qwen's first-load conversion" if conversion_here else "2 GiB of free space"
            raise RuntimeError(
                f"Not enough free storage on {path}: {free / GIB:.1f} GiB available; "
                f"{required / GIB:.1f} GiB needed for the remaining files and {reason}. "
                f"The complete model set is {sum(item[0] for item in WEIGHTS.values()) / GIB:.2f} GiB. "
                "Free space yourself or choose another --models-directory. No existing models or photo caches were removed.")


def locate_helper(explicit):
    base = Path(__file__).resolve().parent
    candidates = [explicit.expanduser()] if explicit else [base / "ExpandPhotoDrawThings.py", base.parent / "Sources/ExpandPhotoDrawThings.py"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError("ExpandPhotoDrawThings.py is missing. Run this installer from the Spatial Slideshow app or source checkout.")


def download_asset(name, destination):
    url = f"https://github.com/drawthingsai/draw-things-community/releases/download/{RELEASE}/{name}"
    expected = ASSETS[name]
    temporary = destination.with_name("." + name + ".download-" + uuid.uuid4().hex)
    request = urllib.request.Request(url, headers={"User-Agent": "SpatialSlideshow-Setup"})
    say(f"Downloading official Draw Things {RELEASE} · {name}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            total = 0
            last_report = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > expected[0]:
                    raise RuntimeError(f"The downloaded {name} is larger than the pinned release asset.")
                output.write(chunk)
                if total - last_report >= 64 * 1024 * 1024:
                    say(f"{name}: {total / expected[0]:.0%}")
                    last_report = total
        if not verified(temporary, expected):
            raise RuntimeError(f"The downloaded {name} did not match the pinned checksum. Try setup again.")
        temporary.chmod(0o755)
        os.replace(temporary, destination)
    finally:
        # This unique partial file belongs to this invocation only.
        temporary.unlink(missing_ok=True)


def install_asset(name, root, seed, no_download):
    destination = root / "bin" / name
    expected = ASSETS[name]
    if destination.exists():
        if not verified(destination, expected):
            raise RuntimeError(f"Existing {destination} does not match Draw Things {RELEASE}. Move it aside yourself, then run setup again.")
        if not os.access(destination, os.X_OK):
            raise RuntimeError(f"The installed {destination} is not executable. Restore its executable permission and retry.")
        say(f"Reusing verified {name}")
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    if seed:
        if not verified(seed, expected):
            raise RuntimeError(f"The supplied {name} does not match official release {RELEASE}.")
        say(f"Copying verified local {name}")
        temporary = destination.with_name("." + name + ".copy-" + uuid.uuid4().hex)
        try:
            shutil.copyfile(seed, temporary)
            if not verified(temporary, expected):
                raise RuntimeError(f"The copied {name} failed its checksum; the runtime was not registered.")
            temporary.chmod(0o755)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    elif no_download:
        raise RuntimeError(f"{name} is missing. Supply its verified local binary or run setup without --no-download.")
    else:
        download_asset(name, destination)
    return destination


def run(argv, **kwargs):
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def check_python(python):
    if not python.is_file() or not os.access(python, os.X_OK):
        raise RuntimeError("The selected Python executable is missing or is not executable.")
    result = run([python, "-c", "import sys; assert sys.version_info[:2] == (3,12), 'Python 3.12 is required'"], capture_output=True, text=True)
    return result


def check_packages(python):
    # Fail a mismatched --use-existing environment before any large download.
    code = """
import importlib.metadata as metadata, json, sys
expected = json.loads(sys.argv[1])
problems = []
for name, required in expected.items():
    try:
        installed = metadata.version(name)
    except metadata.PackageNotFoundError:
        installed = 'missing'
    if installed != required:
        problems.append(f'{name} {required} required; found {installed}')
if problems:
    raise SystemExit('Incompatible Draw Things Python runtime: ' + '; '.join(problems) + '. Run setup without --use-existing to create the pinned managed environment.')
"""
    run([python, "-c", code, json.dumps(PINNED_PACKAGES)], capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, help="Python 3.12 used to create the managed environment.")
    parser.add_argument("--use-existing", type=Path, help="Use an existing compatible Python 3.12 environment without modifying it.")
    parser.add_argument("--server-binary", type=Path, help="Copy an already downloaded official gRPCServerCLI-macOS instead of downloading it.")
    parser.add_argument("--cli-binary", type=Path, help="Copy an already downloaded official draw-things-cli instead of downloading it.")
    parser.add_argument("--models-directory", type=Path, help="Keep/reuse models here; defaults to the managed runtime's models directory.")
    parser.add_argument("--helper-script", type=Path, help="Optional explicit path to ExpandPhotoDrawThings.py.")
    parser.add_argument("--no-download", action="store_true", help="Require an existing Python environment, binaries, and all model weights; never access the network.")
    args = parser.parse_args()
    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("This Draw Things runtime requires an Apple Silicon Mac.")
        helper = locate_helper(args.helper_script)
        root = support_root()
        models = args.models_directory.expanduser().absolute() if args.models_directory else root / "models"
        if models.exists() and not models.is_dir():
            raise RuntimeError("The selected --models-directory is not a directory.")
        seeds = {"gRPCServerCLI-macOS": args.server_binary, "draw-things-cli": args.cli_binary}
        for name, seed in seeds.items():
            if seed is not None:
                seeds[name] = seed.expanduser().absolute()
                if not verified(seeds[name], ASSETS[name]):
                    raise RuntimeError(f"The supplied {name} does not match the pinned official release {RELEASE}.")
        missing_models = 0
        conversion_pending = True
        for name, expected in WEIGHTS.items():
            path = models / name
            if path.exists():
                say(f"Checking existing model · {name}")
                if not verified_model(models, name):
                    raise RuntimeError(f"Existing {path} does not match the pinned model checksum. Choose another --models-directory or move that file aside yourself. No existing file was removed.")
                if name == "qwen_3_4b_q8p.ckpt" and path.stat().st_size == MIGRATED_QWEN[name][0]:
                    conversion_pending = False
            else:
                if name == "qwen_3_4b_q8p.ckpt" and (models / (name + "-tensordata")).exists():
                    raise RuntimeError("The Qwen model has a tensor-data file but no metadata file. Choose another --models-directory or restore the matching model pair. No existing file was removed.")
                missing_models += expected[0]
        missing_binaries = sum(expected[0] for name, expected in ASSETS.items() if not (root / "bin" / name).exists())
        if args.no_download and not args.use_existing:
            raise RuntimeError("--no-download requires --use-existing /path/to/environment/bin/python.")
        if args.no_download and missing_models:
            raise RuntimeError("Some model files are missing. Supply --models-directory with all three pinned weights, or run setup without --no-download.")
        conversion_at = models if conversion_pending else None
        require_space([(models, missing_models), (root, missing_binaries + (0 if args.use_existing else ENVIRONMENT_ALLOWANCE))], conversion_at=conversion_at)
        if args.use_existing:
            # Resolving the bin/python symlink would lose the venv's packages.
            python = args.use_existing.expanduser().absolute()
            check_python(python)
        else:
            candidate = str(args.python.expanduser()) if args.python else shutil.which("python3.12")
            if candidate is None and sys.version_info[:2] == (3, 12):
                candidate = sys.executable
            if candidate is None:
                raise RuntimeError("Install Python 3.12, then retry, or pass --python /path/to/python3.12.")
            check_python(Path(candidate))
            root.mkdir(parents=True, exist_ok=True)
            environment = root / "venv"
            python = environment / "bin/python"
            if not python.exists():
                say("Creating the managed Python 3.12 environment")
                run([candidate, "-m", "venv", environment])
            check_python(python)
            say("Installing pinned Draw Things Python packages")
            run([python, "-m", "pip", "install", "--disable-pip-version-check", "--no-cache-dir",
                 *[f"{name}=={version}" for name, version in PINNED_PACKAGES.items()]])
        check_packages(python)
        root.mkdir(parents=True, exist_ok=True)
        server = install_asset("gRPCServerCLI-macOS", root, seeds["gRPCServerCLI-macOS"], args.no_download)
        cli = install_asset("draw-things-cli", root, seeds["draw-things-cli"], args.no_download)
        models.mkdir(parents=True, exist_ok=True)
        require_space([(models, missing_models)], conversion_at=conversion_at)
        if missing_models:
            say(f"Downloading FLUX.2 Klein 4B and dependencies · {missing_models / GIB:.2f} GiB remaining")
            run([cli, "models", "ensure", "--models-dir", models, "--model", MODEL])
        else:
            say("Reusing the complete verified model set, including any converted Qwen tensor pair")
        for name, expected in WEIGHTS.items():
            say(f"Verifying pinned model checksum · {name}")
            if not verified_model(models, name):
                raise RuntimeError(f"Downloaded {name} does not match the pinned checksum. Move that incomplete file aside yourself and retry setup.")
        registration = {"schema": 1, "python": str(python), "server_binary": str(server),
                        "models_directory": str(models), "port": PORT, "release": RELEASE}
        staged = root / (".runtime-" + uuid.uuid4().hex + ".json")
        try:
            staged.write_text(json.dumps(registration, indent=2, sort_keys=True) + "\n")
            say("Verifying the installed runtime without starting its server")
            checked = subprocess.run([str(python), str(helper), "--runtime-config", str(staged), "--check"],
                                     capture_output=True, text=True, timeout=300)
            if checked.returncode:
                raise RuntimeError((checked.stderr or checked.stdout).strip() or "Draw Things runtime verification failed.")
            identity = json.loads(checked.stdout)
            if not isinstance(identity, dict) or not identity:
                raise RuntimeError("The Draw Things helper returned no runtime identity.")
            os.replace(staged, root / "runtime.json")
        finally:
            staged.unlink(missing_ok=True)
        say("Complete. Choose Draw Things · FLUX.2 Klein in Spatial Slideshow → Settings → Photo Edge Expansion.")
        say("The app starts its local server only when needed, bound to 127.0.0.1 on port 7863. No server was started by setup.")
        print("Runtime registration: " + str(root / "runtime.json"), flush=True)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        detail = str(error)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail += "\n" + str(error.stderr).strip()
        print("ERROR: " + detail, file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
