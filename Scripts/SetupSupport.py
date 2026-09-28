"""Standard-library-only support for model installation on a stock Mac.

The native app bootstraps a checksum-pinned relocatable CPython first. Setup then
uses wheel-only, hash-locked dependencies; no compiler or package manager is
needed. Runtime registration is the final atomic operation in each installer.
"""
from __future__ import annotations

import ast
from contextlib import contextmanager
import fcntl
import hashlib
import json
from http.client import HTTPException
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
import urllib.error
import urllib.request
import uuid

sys.dont_write_bytecode = True
# The app may safely cancel this process group, including pip and HF workers.
# Consume the flag so child installer invocations remain in this same group.
if os.environ.pop("SPATIAL_MANAGED_SETUP", None) == "1" and os.getpgrp() != os.getpid():
    os.setpgid(0, 0)


def say(message):
    print("SETUP " + message, flush=True)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verified(path, expected):
    path = Path(path)
    return path.is_file() and path.stat().st_size == expected[0] and sha(path) == expected[1]


def literal_configuration(path, names):
    """Read pinned constants without importing NumPy/Pillow before installation."""
    values = {}
    for node in ast.parse(Path(path).read_text()).body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in names:
                    values[target.id] = ast.literal_eval(node.value)
    missing = set(names) - values.keys()
    if missing:
        raise RuntimeError("The bundled model helper is missing configuration: " + ", ".join(sorted(missing)))
    return SimpleNamespace(**values)


@contextmanager
def installation_lock(root):
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".setup.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("This model is already being installed. Wait for that installation or cancel it before retrying.") from None
        yield


def run(argv, **kwargs):
    # Children inherit the native installer's process group so cancellation can
    # stop pip/download workers as well as this parent. Never start a new session.
    return subprocess.run([str(arg) for arg in argv], check=True, **kwargs)


def check_python(python):
    if not Path(python).is_file() or not os.access(python, os.X_OK):
        raise RuntimeError("The selected Python executable is missing or is not executable.")
    run([python, "-I", "-c", "import sys; assert sys.version_info[:2] == (3,12), 'Python 3.12 is required'"],
        capture_output=True, text=True)


def validate_environment(python, backend):
    lockfile = Path(__file__).with_name(backend + "-requirements.lock")
    expected = {}
    for line in lockfile.read_text().splitlines():
        if line and not line.startswith("#"):
            name, remote = line.split(" @ ", 1)
            expected[name] = remote.split(" --hash=", 1)[0].rsplit("/", 1)[1].split("-")[1]
    # Pip's dependency check alone cannot detect changed versions with satisfied
    # requirements, or a truncated .py/.so left by disk/network failure.
    verify = """
import base64, hashlib, importlib.metadata as metadata, json, sys
for name, expected in json.loads(sys.argv[1]).items():
    package = metadata.distribution(name)
    if package.version != expected:
        raise SystemExit(f'{name}: expected {expected}; found {package.version}')
    if package.files is None:
        raise SystemExit(f'{name}: missing installed file record')
    for item in package.files:
        if item.hash is not None and item.hash.mode == 'sha256':
            with package.locate_file(item).open('rb') as stream:
                digest = base64.urlsafe_b64encode(hashlib.file_digest(stream, 'sha256').digest()).rstrip(b'=').decode()
            if digest != item.hash.value:
                raise SystemExit(f'{name}: damaged installed file {item}')
"""
    run([python, "-I", "-c", verify, json.dumps(expected)], capture_output=True, text=True)
    run([python, "-I", "-m", "pip", "--isolated", "check"], capture_output=True, text=True)
    modules = {
        "drawthings": "import numpy, PIL.Image, fpzip, grpclib, flatbuffers; import drawthings_py.request_builder",
        "klein": "import numpy, PIL.Image, mlx.core, torch, tokenizers, transformers, safetensors, huggingface_hub",
    }
    run([python, "-I", "-c", modules[backend]], capture_output=True, text=True)


def install_environment(root, requested, backend):
    """Create a versioned environment, leaving any registered runtime untouched."""
    lockfile = Path(__file__).with_name(backend + "-requirements.lock")
    if not lockfile.is_file():
        raise RuntimeError("The bundled model dependency lock is missing. Reinstall Spatial Slideshow.")
    lock_hash = sha(lockfile)
    environment = root / ("venv-" + lock_hash[:16])
    python = environment / "bin/python"
    check_python(requested)
    environment_was_present = environment.exists()
    if python.exists():
        try:
            check_python(python)
            run([python, "-I", "-c",
                 "import os,sys; assert os.path.realpath(sys.prefix)==os.path.realpath(sys.argv[1]), 'Incomplete virtual environment'",
                 environment], capture_output=True, text=True)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            # An interrupted venv creation must never redirect pip into the
            # shared base Python. Retain that damaged environment for recovery.
            saved = environment.with_name(environment.name + ".invalid-" + uuid.uuid4().hex)
            os.replace(environment, saved)
            say("Kept the incomplete Python environment · creating a complete replacement")
    if not python.exists():
        say("Creating the managed Python 3.12 environment")
        run([requested, "-I", "-m", "venv", environment])
    check_python(python)
    complete = environment / ".spatial-packages.json"
    try:
        ready = json.loads(complete.read_text()).get("lock_sha256") == lock_hash
    except (OSError, ValueError, AttributeError):
        ready = False
    repair = environment_was_present and not ready
    if ready:
        try:
            validate_environment(python, backend)
        except (OSError, subprocess.SubprocessError):
            ready = False
            repair = True
            say("Repairing incomplete managed model dependencies")
    if not ready:
        say("Installing verified model dependencies · prebuilt Apple Silicon wheels")
        run([python, "-I", "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
             "--no-cache-dir", "--only-binary=:all:", "--require-hashes", "--no-deps",
             *(["--force-reinstall"] if repair else []), "-r", lockfile])
        validate_environment(python, backend)
        complete.write_text(json.dumps({"lock_sha256": lock_hash}) + "\n")
    else:
        say("Reusing verified managed model dependencies")
    return python


def partial_path(destination, expected):
    destination = Path(destination)
    return destination.with_name("." + destination.name + "." + expected[1][:16] + ".partial")


def remaining_bytes(destination, expected):
    partial = partial_path(destination, expected)
    count = partial.stat().st_size if partial.is_file() else 0
    return max(0, expected[0] - count) if count <= expected[0] else expected[0]


def download_verified(url, destination, expected, executable=False):
    """Resume only installer-owned partials; publish after exact size and hash."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = partial_path(destination, expected)
    for attempt in range(3):
        offset = partial.stat().st_size if partial.is_file() else 0
        if offset > expected[0]:
            # Only our incomplete scratch file may be discarded, never a model.
            partial.unlink()
            offset = 0
        if offset == expected[0]:
            if verified(partial, expected):
                if executable:
                    partial.chmod(0o755)
                os.replace(partial, destination)
                say(f"{destination.name}: 100% · verified")
                return
            partial.unlink()
            offset = 0
        headers = {"User-Agent": "SpatialSlideshow-Setup", "Accept-Encoding": "identity"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        request = urllib.request.Request(url, headers=headers)
        say(f"{destination.name}: {offset / expected[0]:.0%}" + (" · resuming" if offset else " · downloading"))
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                status = response.status
                if status == 206:
                    content_range = response.headers.get("Content-Range", "")
                    wanted = f"bytes {offset}-"
                    if not content_range.startswith(wanted) or not content_range.endswith(f"/{expected[0]}"):
                        raise RuntimeError("The download server returned an unexpected byte range; retry setup.")
                elif status == 200:
                    # Servers may ignore Range. Restart our scratch file safely.
                    offset = 0
                else:
                    raise RuntimeError(f"The download server returned HTTP {status}.")
                total = offset
                last_percent = int(100 * total / expected[0])
                with partial.open("ab" if offset else "wb") as output:
                    while chunk := response.read(1024 * 1024):
                        total += len(chunk)
                        if total > expected[0]:
                            raise RuntimeError(f"The downloaded {destination.name} exceeds its pinned size.")
                        output.write(chunk)
                        percent = int(100 * total / expected[0])
                        if percent != last_percent:
                            say(f"{destination.name}: {percent}%")
                            last_percent = percent
            if total != expected[0]:
                raise OSError(f"Download interrupted at {total} of {expected[0]} bytes")
            say(f"Verifying {destination.name}")
            if not verified(partial, expected):
                partial.unlink()
                raise RuntimeError(f"The downloaded {destination.name} failed its pinned checksum. Retry setup; existing models were kept.")
            if executable:
                partial.chmod(0o755)
            os.replace(partial, destination)
            return
        except (urllib.error.URLError, OSError, HTTPException) as error:
            if attempt == 2:
                raise RuntimeError(f"Could not finish downloading {destination.name}: {error}. Check your connection and retry; completed data will resume.") from error
            say(f"Connection interrupted · retrying {destination.name} ({attempt + 1}/2)")
            time.sleep(1 + attempt)
