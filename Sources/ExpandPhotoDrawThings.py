#!/usr/bin/env python3
"""Offline Draw Things FLUX expansion with verified weights and persistent caching.

Setup alone downloads files. Requests stay on loopback, and the original photo
is restored at full resolution after a masked, model-resolution expansion.
"""
from __future__ import annotations

import argparse
import asyncio
from contextlib import contextmanager
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
import ExpandPhotoKlein as common

MODEL = "flux_2_klein_4b_i8x.ckpt"
BACKEND = "Draw Things FLUX.2 Klein 4B (8-bit S)"
SERVER_RELEASE = "v26.0910.1"
SERVER_SIZE = 249476288
SERVER_SHA256 = "63620975ba1a1cd7e8253bbc553aeed01650b1cccdb1b1b2bc39821e78014671"
PINNED_PACKAGES = {"drawthings-py": "0.4.0", "Pillow": "12.3.0", "numpy": "2.5.3",
                   "flatbuffers": "25.12.19", "grpclib": "0.4.9",
                   "betterproto": "2.0.0b7", "fpzip": "1.2.5"}
WEIGHTS = {
    MODEL: (3926003712, "19985019d78456d6de025a27f048ddc6aefd4e2e28e4ea1827126841932bb645"),
    "qwen_3_4b_q8p.ckpt": (4535328768, "a24e3f832917aafe7f6186e6dfb96ab19a4a0729cdf60a875b5da20024333350"),
    "flux_2_vae_f16.ckpt": (168534016, "48369d4b1495aec3df0579591f4bf9c199a73cc288130df2359c4a173c5ae864"),
}
# The pinned server extracts this encoder into external tensor storage on first
# use. Both forms are verified, but share the published model identity/cache key.
MIGRATED_QWEN = {
    "qwen_3_4b_q8p.ckpt": (389120, "6c203a74336ebc7a153c95414a26a5a5745ee9656b091fff055fff21343d3f5b"),
    "qwen_3_4b_q8p.ckpt-tensordata": (4525654016, "8786ca3526c135aa2334eeb1ce20259bb0b6cd611f84de1b437b0bc3125bee39"),
}
SETTINGS = {"pipeline": 3, "steps": 4, "guidance": 1.0, "seed": 8612,
            "model_long_edge": 768, "alignment": 64, "mask_blur": 2.5,
            "mask_blur_outset": 0, "canvas_fill": [128, 128, 128],
            "mask_overlap_model_pixels": 12, "feather_model_pixels": 18,
            "seam_blend": "multiband-generated-overlap",
            "prompt": "Expand the canvas to reveal more of the exact same scene, as if it had originally been photographed with a wider field of view. Continue every object and surface across the image boundary, preserving the same camera position, perspective, lighting, color, texture, and focus. The added area should join seamlessly with the original, with no visible boundary or change in photographic style. Keep the original photograph unchanged. Extend subjects only where they cross the edge; do not add or repeat people. No frame or border."}


def support_root():
    return common.support_root()


def default_runtime_config():
    return support_root() / "Draw Things Runtime/runtime.json"


def progress(message):
    print("PROGRESS " + message, flush=True)


def load_runtime(path=None):
    path = Path(path or default_runtime_config()).expanduser().absolute()
    try:
        config = json.loads(path.read_text())
        if not isinstance(config, dict):
            raise ValueError("runtime registration must be an object")
        if config.get("schema") != 1 or config.get("release") != SERVER_RELEASE:
            raise ValueError("unsupported runtime version")
        for name in ("server_binary", "models_directory"):
            if not isinstance(config.get(name), str) or not Path(config[name]).is_absolute():
                raise ValueError(f"{name} must be an absolute path")
        if type(config.get("port")) is not int or not 1024 <= config["port"] <= 65535:
            raise ValueError("port must be between 1024 and 65535")
        if config.get("host", "127.0.0.1") != "127.0.0.1" or config.get("tls", True) is not True:
            raise ValueError("only local loopback with TLS is supported")
    except (OSError, ValueError, TypeError) as error:
        raise RuntimeError(f"Draw Things is not configured correctly ({error}). Run Scripts/setup_drawthings.py, then try again.") from None
    return {**config, "config_path": str(path), "runtime_root": str(path.parent)}


def check_runtime(prepare_helper=None, runtime_config=None):
    """Verify without loading GPU models, starting a server, or printing progress."""
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("Draw Things FLUX requires an Apple Silicon Mac.")
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError("Draw Things needs its managed Python 3.12 runtime. Run Scripts/setup_drawthings.py.")
    config = load_runtime(runtime_config)
    versions = {}
    for name, required in PINNED_PACKAGES.items():
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            raise RuntimeError(f"Draw Things is missing {name}. Run Scripts/setup_drawthings.py.") from None
        if versions[name] != required:
            raise RuntimeError(f"Draw Things needs {name} {required}; found {versions[name]}. Run Scripts/setup_drawthings.py.")
    server = Path(config["server_binary"])
    models = Path(config["models_directory"])
    if not os.access(server, os.X_OK):
        raise RuntimeError("The Draw Things server is missing or not executable. Run Scripts/setup_drawthings.py.")
    validation_path = Path(config["runtime_root"]) / "model-validation.json"
    try:
        previous = json.loads(validation_path.read_text())
    except (OSError, ValueError):
        previous = {}
    if not isinstance(previous, dict):
        previous = {}
    files = runtime_weight_files(models)
    files["server"] = (server, (SERVER_SIZE, SERVER_SHA256))
    receipts = {}
    for name, (path, (size, expected)) in files.items():
        if not path.is_file() or path.stat().st_size != size:
            raise RuntimeError(f"Draw Things file {name} is missing or incomplete. Run Scripts/setup_drawthings.py to repair it.")
        signature = common.file_signature(path)
        receipt = previous.get(str(path.resolve()), {})
        if receipt.get("signature") != signature or receipt.get("sha256") != expected:
            if common.sha(path) != expected:
                raise RuntimeError(f"Draw Things file {name} failed checksum verification. Run Scripts/setup_drawthings.py to repair it.")
        receipts[str(path.resolve())] = {"signature": signature, "sha256": expected}
    common.write_json(validation_path, receipts)
    package = Path(importlib.metadata.distribution("drawthings-py").locate_file("drawthings_py"))
    package_hashes = {str(p.relative_to(package)): common.sha(p) for p in sorted(package.rglob("*"))
                      if p.is_file() and p.suffix in (".py", ".json", ".yaml", ".crt")}
    model_metadata = {str(p.relative_to(models)): common.sha(p) for p in sorted(models.rglob("*.json")) if p.is_file()}
    dependencies = [Path(__file__), Path(common.__file__), Path(__file__).with_name("KleinColorMatch.py")]
    if prepare_helper:
        helper = Path(prepare_helper)
        if not helper.is_file() or not os.access(helper, os.X_OK):
            raise RuntimeError("The native photo preparation helper is missing. Rebuild or reinstall Spatial Slideshow.")
        dependencies.append(helper)
    for path in dependencies:
        if not path.is_file():
            raise RuntimeError(f"The expansion helper {path.name} is missing. Rebuild or reinstall Spatial Slideshow.")
    identity = {"schema": 1, "backend": BACKEND, "model": MODEL, "server_release": SERVER_RELEASE,
                "server_sha256": SERVER_SHA256, "weights_sha256": {name: value[1] for name, value in WEIGHTS.items()},
                "runtime_versions": versions, "runtime_source_sha256": common.digest(package_hashes),
                "model_metadata_sha256": common.digest(model_metadata),
                "python_version": platform.python_version(), "settings": SETTINGS,
                "helpers_sha256": {path.name: common.sha(path) for path in dependencies}}
    identity["fingerprint"] = common.digest(identity)
    config["model_metadata_sha256"] = identity["model_metadata_sha256"]
    return identity, config


def runtime_weight_files(models):
    files = {name: (models / name, expected) for name, expected in WEIGHTS.items()}
    encoder = models / "qwen_3_4b_q8p.ckpt"
    if encoder.is_file() and encoder.stat().st_size == MIGRATED_QWEN[encoder.name][0]:
        files.update({name: (models / name, expected) for name, expected in MIGRATED_QWEN.items()})
    return files


@contextmanager
def lock_file(path, *, wait=True, timeout=900):
    import fcntl
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        started = time.monotonic()
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not wait:
                    yield False
                    return
                if time.monotonic() - started > timeout:
                    raise RuntimeError("Another Draw Things request did not finish. Stop playback and try again.")
                time.sleep(.1)
        try:
            yield True
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def process_snapshot(pid):
    """PID alone never establishes ownership: verify uid, start time and argv."""
    if type(pid) is not int or pid <= 1:
        return None
    try:
        result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "uid=,lstart=,command="],
                                capture_output=True, text=True, timeout=3)
        fields = result.stdout.strip().split(None, 6)
        if result.returncode or len(fields) != 7:
            return None
        return {"pid": pid, "uid": int(fields[0]), "start": " ".join(fields[1:6]), "command": fields[6]}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def read_state(config):
    try:
        state = json.loads((Path(config["runtime_root"]) / "server-state.json").read_text())
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def owns_server(state):
    snapshot = process_snapshot(state.get("pid"))
    token = state.get("launch_token")
    return bool(snapshot and snapshot == state.get("process") and snapshot["uid"] == os.getuid()
                and isinstance(token, str) and len(token) == 32
                and "SpatialSlideshow-" + token in snapshot["command"]
                and state.get("binary") and snapshot["command"].startswith(state["binary"] + " "))


def stop_owned_server(config, state=None):
    state = state if state is not None else read_state(config)
    if not owns_server(state):
        return False
    try:
        os.kill(state["pid"], signal.SIGTERM)
        deadline = time.monotonic() + .35
        while owns_server(state) and time.monotonic() < deadline:
            time.sleep(.03)
        if owns_server(state):
            os.kill(state["pid"], signal.SIGKILL)
    except ProcessLookupError:
        pass
    (Path(config["runtime_root"]) / "server-state.json").unlink(missing_ok=True)
    return True


def stop_server(config, idle_seconds=0):
    with lock_file(Path(config["runtime_root"]) / "server-operation.lock", wait=False) as locked:
        if not locked:
            return False
        state = read_state(config)
        if time.time() - state.get("last_used_at", 0) < idle_seconds:
            return False
        return stop_owned_server(config, state)


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=.15):
            return True
    except OSError:
        return False


def available_loopback_port():
    """Ask the OS for an unused local port; never displace another service."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            return listener.getsockname()[1]
    except OSError as error:
        raise RuntimeError(f"Could not reserve a local Draw Things port: {error}. Try playback again.") from None


def persist_runtime_port(config, port):
    """Caller holds server-operation.lock. Do not overwrite changed registrations.

    A staged setup file, symlink, foreign-owned file, or registration changed
    since it was loaded can still use the selected port for this request, but
    must not be rewritten by playback.
    """
    path = Path(config["config_path"])
    try:
        info = path.lstat()
        if (path.name != "runtime.json" or path.parent != Path(config["runtime_root"])
                or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()):
            return False
        registration = json.loads(path.read_text())
        loaded = {key: value for key, value in config.items()
                  if key not in ("config_path", "runtime_root", "model_metadata_sha256")}
        if registration != loaded:
            return False
        # Avoid replacing a registration which changed while it was read.
        current = path.lstat()
        if (current.st_ino, current.st_mtime_ns, current.st_size) != (info.st_ino, info.st_mtime_ns, info.st_size):
            return False
        common.write_json(path, {**registration, "port": port})
        return True
    except (OSError, ValueError, TypeError):
        return False


def ensure_server(config):
    """Start/reuse our server while the caller holds server-operation.lock."""
    root = Path(config["runtime_root"])
    root.mkdir(parents=True, exist_ok=True)
    state_path = root / "server-state.json"
    identity = common.digest({key: config.get(key) for key in ("server_binary", "models_directory", "port", "release", "model_metadata_sha256")})
    state = read_state(config)
    if owns_server(state):
        if state.get("server_identity") == identity and port_open(config["port"]):
            state["last_used_at"] = time.time()
            common.write_json(state_path, state)
            return state
        stop_owned_server(config, state)
    if port_open(config["port"]):
        port = available_loopback_port()
        persist_runtime_port(config, port)
        config["port"] = port
        # Transport changes require a new server, not a new model/render key.
        identity = common.digest({key: config.get(key) for key in ("server_binary", "models_directory", "port", "release", "model_metadata_sha256")})
        progress("Using another available local port for Draw Things")
    token = uuid.uuid4().hex
    cache = root / "server-cache"
    cache.mkdir(exist_ok=True)
    command = [config["server_binary"], config["models_directory"], "--address", "127.0.0.1",
               "--port", str(config["port"]), "--name", "SpatialSlideshow-" + token,
               "--cache-uri", str(cache), "--cancellation-warning-timeout", "3",
               "--cancellation-crash-timeout", "5"]
    log_path = root / "server.log"
    if log_path.exists() and log_path.stat().st_size > 4 * 1024 * 1024:
        os.replace(log_path, root / "server-previous.log")
    progress("Starting the local Draw Things renderer")
    child = None
    state = {}
    try:
        with log_path.open("ab", buffering=0) as log:
            log.write(f"\nSpatial Slideshow server started {time.ctime()}\n".encode())
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     start_new_session=True, close_fds=True)
        state = {"pid": child.pid, "process": process_snapshot(child.pid), "launch_token": token,
                 "binary": config["server_binary"], "server_identity": identity,
                 "port": config["port"],
                 "last_used_at": time.time(), "log": str(log_path)}
        deadline = time.monotonic() + 30
        if not owns_server(state):
            raise RuntimeError(f"Could not establish Draw Things server ownership. See {log_path}.")
        common.write_json(state_path, state)
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError(f"Draw Things server exited ({child.returncode}) during startup. See {log_path}; rerun setup if model files are incomplete.")
            if port_open(config["port"]):
                return state
            time.sleep(.1)
        raise RuntimeError(f"Draw Things server did not become ready in 30 seconds. See {log_path}.")
    except BaseException:
        if not stop_owned_server(config, state) and child is not None and child.poll() is None:
            # A freshly spawned Popen is also an ownership proof if publishing
            # its persistent state failed before we could write it.
            child.terminate()
            try:
                child.wait(timeout=.35)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        raise


def build_request(small, dimensions, work):
    from PIL import Image
    from drawthings_py import Configs, RequestBuilder
    mx, _, my, _ = dimensions["requested_model_padding_lrtb"]
    width = math.ceil((small.width + 2 * mx) / 64) * 64
    height = math.ceil((small.height + 2 * my) / 64) * 64
    canvas = Image.new("RGB", (width, height), tuple(SETTINGS["canvas_fill"]))
    canvas.paste(small.convert("RGB"), (mx, my))
    mask = Image.new("L", canvas.size, 255)
    # Let the generated surfaces cross the join. A hard restoration right at
    # this boundary exposes a rectangle whenever their texture/focus differs.
    overlap = min(SETTINGS["mask_overlap_model_pixels"], (min(small.size) - 1) // 4)
    mask.paste(0, (mx + overlap, my + overlap, mx + small.width - overlap, my + small.height - overlap))
    canvas.save(work / "canvas.png")
    mask.save(work / "mask.png")
    config = Configs.from_preset("flux_2_klein_4b")
    config.set(model=MODEL, width=width, height=height, seed=SETTINGS["seed"], steps=SETTINGS["steps"],
               guidance=SETTINGS["guidance"], strength=1.0, batch_count=1, batch_size=1,
               mask_blur=SETTINGS["mask_blur"], mask_blur_outset=SETTINGS["mask_blur_outset"],
               preserve_original_after_inpaint=False)
    request = RequestBuilder(config, SETTINGS["prompt"])
    request.init_image(work / "canvas.png")
    request.mask(work / "mask.png")
    metadata = {"source_image_width": small.width, "source_image_height": small.height,
                "outpaint_target_width": width, "outpaint_target_height": height,
                "outpaint_source_paste_left": mx, "outpaint_source_paste_top": my,
                "outpaint_mask_overlap_pixels": overlap}
    return request, metadata


def prepare_photo(helper, input_path, work):
    # A whole-operation deadline or cancellation must also reap the decoder.
    child = subprocess.Popen([str(helper), str(input_path), str(work), str(SETTINGS["model_long_edge"])])
    try:
        if child.wait(timeout=120):
            raise RuntimeError("Could not decode or color-manage this photo. See the preparation error above.")
    except BaseException:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=.35)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        raise


async def generate_request(request, config, raw, timeout):
    from drawthings_py import DrawThings
    from drawthings_py.grpc.grpc_service import format_signpost
    def on_progress(signpost, preview):
        if signpost:
            stage = format_signpost(signpost)
            if stage:
                progress("Draw Things · " + stage)
    request.on_progress(on_progress)
    async with asyncio.timeout(timeout):
        async with DrawThings.grpc(host="127.0.0.1", port=config["port"], progressbar=False, disable_messages=True) as service:
            result = await service.generate(request)
            if len(result) != 1:
                raise RuntimeError("Draw Things returned an unexpected image count.")
            result[0].to_file(raw)


def infer(small_path, raw, config, dimensions, timeout=300):
    from PIL import Image
    with Image.open(small_path) as small:
        small.load()
        request, metadata = build_request(small, dimensions, raw.parent)
        with lock_file(Path(config["runtime_root"]) / "server-operation.lock", timeout=timeout):
            state = ensure_server(config)
            try:
                asyncio.run(generate_request(request, config, raw, timeout))
            except BaseException as error:
                stop_owned_server(config, state)
                if isinstance(error, TimeoutError):
                    raise RuntimeError(f"Draw Things did not finish within {timeout:g} seconds and was stopped. See {state['log']}.") from None
                if isinstance(error, Exception):
                    raise RuntimeError(f"Draw Things could not expand this photo: {error}. Its renderer was stopped; see {state['log']}.") from None
                raise
            finally:
                if owns_server(state):
                    state["last_used_at"] = time.time()
                    common.write_json(Path(config["runtime_root"]) / "server-state.json", state)
        with Image.open(raw) as result:
            if result.size != (metadata["outpaint_target_width"], metadata["outpaint_target_height"]):
                raise RuntimeError("Draw Things returned an unexpected canvas size; the image was not cached.")
            restored = result.convert("RGB")
        # Preserve a small generated overlap for the full-resolution feather.
        # Everything farther inside the photograph is restored immediately.
        inset = min(SETTINGS["feather_model_pixels"], (min(small.size) - 1) // 4)
        restored.paste(small.convert("RGB").crop((inset, inset, small.width - inset, small.height - inset)),
                       (metadata["outpaint_source_paste_left"] + inset, metadata["outpaint_source_paste_top"] + inset))
        restored.save(raw)
        metadata["outpaint_source_restore_applied"] = True
        metadata["outpaint_source_restore_inset_pixels"] = inset
        return metadata


def expand(input_path, output, percent, helper, cache, runtime_config=None, timeout=300):
    from PIL import Image
    started = time.monotonic()
    if not input_path.is_file():
        raise RuntimeError("The input photo is missing or unreadable.")
    if any((output / name).exists() for name in ("expanded.png", "expansion.json")):
        raise RuntimeError("The expansion destination already contains a result; refusing to overwrite it.")
    progress("Checking local Draw Things FLUX models")
    identity, config = check_runtime(helper, runtime_config)
    cache.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".drawthings-working-", dir=output.parent) as temporary:
        work = Path(temporary)
        progress("Decoding and color-managing the original photo")
        prepare_photo(helper, input_path, work)
        with Image.open(work / "original-srgb.png") as original, Image.open(work / "model-input.png") as small:
            original.load()
            small.load()
            dimensions = common.geometry(original.size, small.size, percent)
            source_hash = common.source_identity(original)
            key = common.digest({"source_pixels_and_icc": source_hash, "percent": percent, "identity": identity["fingerprint"]})
            entry = cache / key
            with lock_file(cache / ".locks" / (key + ".lock"), timeout=timeout):
                report = common.cached_report(entry, key)
                if report:
                    progress("Reusing cached Draw Things expansion")
                    report.update(input=str(input_path), cache_hit=True, total_seconds=time.monotonic() - started)
                    common.publish_pair(entry / "expanded.png", output, report)
                    return
                if os.environ.get("SPATIAL_DRAWTHINGS_CACHE_ONLY") == "1":
                    raise RuntimeError("No valid cached Draw Things expansion is available (cache-only test mode).")
                progress(f"Generating {percent}% per edge with Draw Things FLUX")
                inference_start = time.monotonic()
                raw = work / "generated.png"
                metadata = infer(work / "model-input.png", raw, config, dimensions, timeout)
                progress("Restoring the full-resolution original and matching border colors")
                expanded = work / "expanded.png"
                with Image.open(raw) as generated:
                    restored = common.restore_original(original, small, generated, metadata, dimensions, expanded,
                        generated_overlap_model_pixels=metadata["outpaint_source_restore_inset_pixels"])
                report = {"schema": 1, "helper_protocol_version": 1, "status": "complete", "backend": BACKEND,
                          "identity": identity, "input": str(input_path), "percent_per_edge": percent,
                          "cache_key": key, "source_pixels_and_icc_sha256": source_hash, "cache_hit": False,
                          "output_color_space": "sRGB", "orientation_applied": True,
                          "color_metadata": json.loads((work / "source.json").read_text()),
                          "preservation": "Pixel-exact full-resolution sRGB source interior; narrow inner edge feathered into generated overlap",
                          "inference_and_materialization_seconds": time.monotonic() - inference_start,
                          "total_seconds": time.monotonic() - started, **restored}
                if entry.exists():
                    shutil.rmtree(entry)
                common.publish_pair(expanded, entry, report)
                common.publish_pair(expanded, output, report)
                progress("SAVED " + str(output / "expanded.png"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    parser.add_argument("percent", nargs="?", type=int)
    parser.add_argument("--prepare-helper", type=Path)
    parser.add_argument("--cache-root", type=Path, default=support_root() / "Expanded Photos/Draw Things FLUX")
    parser.add_argument("--runtime-config", type=Path, default=default_runtime_config())
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--stop-server", action="store_true")
    parser.add_argument("--idle-seconds", type=float, default=0)
    args = parser.parse_args()
    def cancel(signum, frame):
        raise KeyboardInterrupt
    def deadline(signum, frame):
        raise TimeoutError("Draw Things expansion exceeded its time limit and was stopped. Try again or reduce edge expansion.")
    signal.signal(signal.SIGTERM, cancel)
    try:
        if args.check:
            identity, _ = check_runtime(args.prepare_helper, args.runtime_config)
            print(json.dumps(identity, sort_keys=True), flush=True)
            return 0
        if args.stop_server:
            print(json.dumps({"stopped": stop_server(load_runtime(args.runtime_config), max(0, args.idle_seconds))}), flush=True)
            return 0
        if args.input is None or args.output is None or args.percent is None or args.prepare_helper is None:
            parser.error("INPUT OUTPUT_DIRECTORY PERCENT --prepare-helper PATH are required")
        if not 1 <= args.percent <= 20 or not 1 <= args.timeout <= 1800:
            parser.error("PERCENT must be 1...20 and timeout 1...1800 seconds")
        signal.signal(signal.SIGALRM, deadline)
        signal.setitimer(signal.ITIMER_REAL, args.timeout)
        try:
            expand(args.input.resolve(), args.output.resolve(), args.percent, args.prepare_helper.resolve(),
                   args.cache_root.resolve(), args.runtime_config, args.timeout)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
        return 0
    except KeyboardInterrupt:
        print("ERROR: Draw Things expansion was cancelled.", file=sys.stderr, flush=True)
        return 130
    except Exception as error:
        print("ERROR: " + str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
