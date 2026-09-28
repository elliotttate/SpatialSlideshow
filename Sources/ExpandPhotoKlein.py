#!/usr/bin/env python3
"""Offline FLUX.2 Klein edge expansion with a source-preserving persistent cache.

Only setup_klein.py downloads software/models. This process checks pinned local
weights, runs MLX-Gen in-process, and restores the color-managed original center.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

# Local imports must not create __pycache__ inside the signed app bundle.
sys.dont_write_bytecode = True

MODEL = "AbstractFramework/flux.2-klein-base-4b-8bit"
MODEL_REVISION = "02f9458e2c412d067a24fd9ddc16b85dd7f3ddab"
ADAPTER = "fal/flux-2-klein-4B-outpaint-lora"
ADAPTER_REVISION = "b11770ac6a3cf9325dcf81742c12b1c4e257880f"
ADAPTER_FILE = "flux-outpaint-lora.safetensors"
BACKEND = "FLUX.2 Klein Base 4B + fal outpainting LoRA"
SETTINGS = {"pipeline": 1, "steps": 20, "guidance": 4.0, "seed": 8612,
            "adapter_scale": 1.0, "model_long_edge": 768, "feather_model_pixels": 3,
            "prompt": "Fill the green spaces according to the image"}
PINNED_PACKAGES = {"mlx-gen": "0.38.0", "mlx": "0.32.2", "mlx-metal": "0.32.2",
                   "Pillow": "12.3.0", "numpy": "2.5.3", "huggingface-hub": "1.33.0",
                   "safetensors": "0.8.0", "transformers": "5.17.0", "tokenizers": "0.23.2"}
WEIGHTS = {
    "text_encoder/0.safetensors": (2145931311, "f6809bd90892b0a2857847f789d294a76f4494a76e65ddbd224da69e70018edc"),
    "text_encoder/1.safetensors": (2128222146, "54ec81423abf46be7400817e05113024070197bc4e3f9c56e438ed6b5e3b3705"),
    "transformer/0.safetensors": (2142058104, "5f8a34d7d53d5e77e86103bad909440999b192c45dea9ce4ed92c8ba003c57ca"),
    "transformer/1.safetensors": (1975761704, "43d93f939aa1d8a1a7ed2c179a8bbd3b95bb88648d4236a293e943242d164206"),
    "vae/0.safetensors": (166156496, "01723641b0fe437a08b2b9a1980149ea5d962d904db3cc6cec70508074387278")}
ADAPTER_WEIGHT = (76039072, "9623927f2471613e0c9d7810da3c39f0b277a448193b223ea3cee67d5750974a")


def support_root():
    return Path.home() / "Library/Application Support/Photos Spatial Slideshow"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def progress(message):
    print("EXPANSION " + message, flush=True)


def file_signature(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]


def check_runtime(prepare_helper=None):
    """Verify local resources without importing MLX or loading GPU weights."""
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("FLUX.2 Klein requires an Apple Silicon Mac.")
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError("FLUX.2 Klein needs the managed Python 3.12 runtime. Run Scripts/setup_klein.py.")
    versions = {}
    for name, required in PINNED_PACKAGES.items():
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            raise RuntimeError(f"FLUX.2 Klein is missing {name}. Run Scripts/setup_klein.py to install its runtime.") from None
        if versions[name] != required:
            raise RuntimeError(f"FLUX.2 Klein requires {name} {required}; found {versions[name]}. Run Scripts/setup_klein.py.")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    from huggingface_hub import snapshot_download, hf_hub_download
    try:
        model_path = Path(snapshot_download(MODEL, revision=MODEL_REVISION, local_files_only=True))
        # MLX-Gen's capability router needs the repository ID. Its offline main
        # reference must resolve to exactly the revision whose weights we verify.
        main_path = Path(snapshot_download(MODEL, local_files_only=True))
        adapter_path = Path(hf_hub_download(ADAPTER, ADAPTER_FILE, revision=ADAPTER_REVISION, local_files_only=True))
    except Exception as error:
        raise RuntimeError("FLUX.2 Klein models are not fully downloaded. Run Scripts/setup_klein.py while online, then try again.") from error
    if model_path.resolve() != main_path.resolve():
        raise RuntimeError("The cached Klein model points to a different revision. Run Scripts/setup_klein.py to restore the pinned version.")
    validation_path = support_root() / "Klein Runtime/model-validation.json"
    try:
        validations = json.loads(validation_path.read_text())
    except (OSError, ValueError):
        validations = {}
    files = {name: (model_path / name, expected) for name, expected in WEIGHTS.items()}
    files["adapter/" + ADAPTER_FILE] = (adapter_path, ADAPTER_WEIGHT)
    new_validations = {}
    for name, (path, (size, expected)) in files.items():
        if not path.is_file() or path.stat().st_size != size:
            raise RuntimeError(f"Klein model file {name} is incomplete. Run Scripts/setup_klein.py to repair the download.")
        signature = file_signature(path)
        previous = validations.get(str(path.resolve()), {})
        if previous.get("signature") != signature or previous.get("sha256") != expected:
            if sha(path) != expected:
                raise RuntimeError(f"Klein model file {name} failed its checksum. Remove that cached file and run Scripts/setup_klein.py again.")
        new_validations[str(path.resolve())] = {"signature": signature, "sha256": expected}
    write_json(validation_path, new_validations)
    # Changes to tokenizers/configuration or installed implementation also change
    # the cache identity. Path relocation alone deliberately does not.
    model_metadata = {str(p.relative_to(model_path)): sha(p) for p in sorted(model_path.rglob("*"))
                      if p.is_file() and p.suffix in (".json", ".jinja")}
    for required in ("tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
                     "text_encoder/model.safetensors.index.json", "transformer/model.safetensors.index.json",
                     "vae/model.safetensors.index.json"):
        if required not in model_metadata:
            raise RuntimeError("Klein model configuration is incomplete. Run Scripts/setup_klein.py to repair it.")
    package_root = Path(importlib.metadata.distribution("mlx-gen").locate_file("mflux"))
    source_hashes = {str(p.relative_to(package_root)): sha(p) for p in sorted(package_root.rglob("*.py"))}
    identity = {"schema": 1, "backend": BACKEND, "model": MODEL, "model_revision": MODEL_REVISION,
                "adapter": ADAPTER, "adapter_revision": ADAPTER_REVISION,
                "weights_sha256": {name: item[1][1] for name, item in files.items()},
                "model_metadata_sha256": digest(model_metadata), "runtime_versions": versions,
                "runtime_source_sha256": digest(source_hashes),
                "python_version": platform.python_version(), "settings": SETTINGS,
                "script_sha256": sha(__file__)}
    color_match = Path(__file__).with_name("KleinColorMatch.py")
    if not color_match.is_file():
        raise RuntimeError("The FLUX border color-matching helper is missing. Rebuild or reinstall Spatial Slideshow.")
    identity["border_color_match_sha256"] = sha(color_match)
    if prepare_helper:
        helper = Path(prepare_helper)
        if not helper.is_file() or not os.access(helper, os.X_OK):
            raise RuntimeError("The photo preparation helper is missing. Rebuild Spatial Slideshow.")
        identity["prepare_helper_sha256"] = sha(helper)
    identity["fingerprint"] = digest(identity)
    return identity, model_path, adapter_path


def geometry(source_size, model_size, percent):
    w, h = source_size
    mw, mh = model_size
    if not 1 <= percent <= 20 or min(w, h, mw, mh) <= 0:
        raise ValueError("Expansion must be 1–20% per edge and the image dimensions must be positive.")
    # Match Swift's rounded() and request enough model border to cover every
    # full-resolution pixel, including when the model rounds its canvas up.
    px = max(1, math.floor(w * percent / 100 + .5))
    py = max(1, math.floor(h * percent / 100 + .5))
    mx = max(1, math.ceil(px * mw / w))
    my = max(1, math.ceil(py * mh / h))
    return {"source_size": [w, h], "output_size": [w + 2 * px, h + 2 * py],
            "original_box_top_left": [px, py, w, h], "original_box_bottom_left": [px, py, w, h],
            "padding_lrtb": [px, px, py, py], "model_source_size": [mw, mh],
            "requested_model_padding_lrtb": [mx, mx, my, my]}


def source_identity(original):
    image = original.convert("RGB")
    result = hashlib.sha256(canonical({"size": image.size, "mode": image.mode}))
    result.update(image.tobytes())
    result.update(original.info.get("icc_profile", b""))
    return result.hexdigest()


def restore_original(original, small, generated, metadata, dimensions, output, *, generated_overlap_model_pixels=0):
    """Restore an exact symmetric canvas independent of MLX canvas rounding."""
    import numpy as np
    from PIL import Image, ImageCms
    original = original.convert("RGB")
    generated = generated.convert("RGB")
    w, h = original.size
    mw, mh = small.size
    if generated.size != (metadata.get("outpaint_target_width"), metadata.get("outpaint_target_height")):
        raise RuntimeError("Klein returned inconsistent expansion dimensions; the result was not cached.")
    if metadata.get("source_image_width") != mw or metadata.get("source_image_height") != mh:
        raise RuntimeError("Klein resized the source unexpectedly; the result was not cached.")
    if metadata.get("outpaint_source_restore_applied") is not True:
        raise RuntimeError("Klein did not preserve the original composition; the result was not cached.")
    overlap = generated_overlap_model_pixels
    if type(overlap) is not int or not 0 <= overlap < min(mw, mh) / 2:
        raise RuntimeError("Invalid generated seam overlap; the result was not cached.")
    if metadata.get("outpaint_source_restore_inset_pixels", 0) != overlap:
        raise RuntimeError("The generated seam does not match the restoration contract; the result was not cached.")
    left, top = metadata["outpaint_source_paste_left"], metadata["outpaint_source_paste_top"]
    # The model can shift the generated surroundings toward magenta even when
    # the restored center is correct sRGB. Match only the new border to the
    # original before compositing, rather than applying a tint to the photo.
    from KleinColorMatch import harmonize_border
    generated, color_report = harmonize_border(generated, small.convert("RGB"), left, top,
                                               restore_inset=overlap)
    seam_report = None
    if overlap:
        from KleinColorMatch import blend_overlap
        generated, seam_report = blend_overlap(generated, small, left, top, overlap)
    px, _, py, _ = dimensions["padding_lrtb"]
    sx, sy = w / mw, h / mh
    crop = (left - px / sx, top - py / sy, left + mw + px / sx, top + mh + py / sy)
    if crop[0] < -1e-6 or crop[1] < -1e-6 or crop[2] > generated.width + 1e-6 or crop[3] > generated.height + 1e-6:
        raise RuntimeError("Klein did not generate enough border to cover the requested canvas.")
    # Sampling a fractional crop with one resize preserves the original-to-model
    # coordinate mapping. Resizing the entire rounded canvas would shift/stretch it.
    expanded = generated.resize(tuple(dimensions["output_size"]), Image.Resampling.LANCZOS, box=crop)
    feather = overlap or 3
    fx, fy = min(feather * sx, w / 2), min(feather * sy, h / 2)
    x = np.minimum(np.arange(w), np.arange(w)[::-1]) / fx
    y = np.minimum(np.arange(h), np.arange(h)[::-1]) / fy
    alpha = np.clip(np.minimum(y[:, None], x[None, :]), 0, 1)
    if overlap:
        # Zero slope at both ends hides the join without a separate blurred
        # stripe. The full-resolution interior remains completely untouched.
        alpha = alpha * alpha * (3 - 2 * alpha)
    mask = Image.fromarray(np.rint(alpha * 255).astype(np.uint8))
    expanded.paste(original, (px, py), mask)
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    expanded.save(output, icc_profile=profile)
    ix, iy = math.ceil(fx), math.ceil(fy)
    preserved = [px + ix, py + iy, max(0, w - 2 * ix), max(0, h - 2 * iy)]
    with Image.open(output) as saved:
        if preserved[2] > 0 and preserved[3] > 0:
            expected = original.crop((ix, iy, w - ix, h - iy)).tobytes()
            actual = saved.convert("RGB").crop((px + ix, py + iy, px + w - ix, py + h - iy)).tobytes()
            if actual != expected:
                raise RuntimeError("Original-pixel preservation check failed; the result was not cached.")
    return {**dimensions, "preserved_box_top_left": preserved,
            "model_canvas_size": list(generated.size),
            "model_padding_lrtb": [left, generated.width - left - mw, top, generated.height - top - mh],
            "feather_model_pixels": feather, "feather_source_pixels_xy": [fx, fy],
            "seam_blend": "multiband-generated-overlap" if overlap else "linear-source-restore",
            "multiband_seam": seam_report,
            "generated_overlap_model_pixels": overlap,
            "border_color_match": color_report,
            "preserved_interior_max_rgb_error": 0, "output_sha256": sha(output)}


def cached_report(directory, key):
    try:
        report = json.loads((directory / "expansion.json").read_text())
        image = directory / "expanded.png"
        if report.get("status") != "complete" or report.get("cache_key") != key:
            return None
        if not image.is_file() or report.get("output_sha256") != sha(image):
            return None
        return report
    except (OSError, ValueError):
        return None


def publish_pair(source, destination, report):
    destination.mkdir(parents=True, exist_ok=True)
    image = destination / "expanded.png"
    manifest = destination / "expansion.json"
    if image.exists() or manifest.exists():
        raise RuntimeError("The expansion destination already contains a result; refusing to overwrite it.")
    temporary = destination / (".expanded-" + uuid.uuid4().hex + ".png")
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, image)
        # Manifest is always published last as the atomic completion marker.
        write_json(manifest, report)
    except BaseException:
        temporary.unlink(missing_ok=True)
        image.unlink(missing_ok=True)
        raise


@contextmanager
def cache_lock(cache, key):
    import fcntl
    locks = cache / ".locks"
    locks.mkdir(parents=True, exist_ok=True)
    with (locks / (key + ".lock")).open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            progress("Waiting for an existing Klein expansion of this photo")
            fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def prepare_photo(helper, input_path, work):
    # Only the short native decode runs as a child. Inference stays in THIS
    # process, so the app's cancellation/timeout cannot orphan a GPU job.
    process = subprocess.Popen([str(helper), str(input_path), str(work), "768"])
    def cancel(signum, frame):
        process.terminate()
        try:
            process.wait(timeout=.4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise SystemExit(128 + signum)
    previous = signal.signal(signal.SIGTERM, cancel)
    try:
        code = process.wait(timeout=120)
        if code:
            raise RuntimeError("Could not decode or color-manage this photo. See the preparation error above.")
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise RuntimeError("Photo decoding took more than two minutes. Try downloading the original in Photos first.") from None
    finally:
        signal.signal(signal.SIGTERM, previous)


def infer(small, raw, adapter, dimensions):
    from mflux.cli.mlx_gen import main as mlxgen_main
    mx, _, my, _ = dimensions["requested_model_padding_lrtb"]
    argv = ["mlxgen", "generate", "--model", MODEL, "--image", str(small),
            "--outpaint-padding", f"{my},{mx},{my},{mx}", "--prompt", SETTINGS["prompt"],
            "--steps", str(SETTINGS["steps"]), "--guidance", str(SETTINGS["guidance"]),
            "--seed", str(SETTINGS["seed"]), "--lora-paths", str(adapter),
            "--lora-scales", "1.0", "--metadata", "--output", str(raw)]
    previous = sys.argv
    sys.argv = argv
    try:
        mlxgen_main()
    except SystemExit as error:
        if error.code not in (0, None):
            raise RuntimeError("Klein generation failed. Check available memory and the model diagnostic log.") from error
    finally:
        sys.argv = previous


def expand(input_path, output, percent, helper, cache):
    from PIL import Image
    started = time.monotonic()
    if not input_path.is_file():
        raise RuntimeError("The input photo is missing or unreadable.")
    if any((output / name).exists() for name in ("expanded.png", "expansion.json")):
        raise RuntimeError("The expansion destination already contains a result; refusing to overwrite it.")
    progress("Checking local FLUX.2 Klein models")
    identity, _, adapter = check_runtime(helper)
    cache.mkdir(parents=True, exist_ok=True)
    # The app owns this scratch parent and removes it even after a hard timeout.
    # Never leave partial generated images in the persistent cache on SIGKILL.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".klein-working-", dir=output.parent) as temporary:
        work = Path(temporary)
        progress("Decoding and color-managing the original photo")
        prepare_photo(helper, input_path, work)
        with Image.open(work / "original-srgb.png") as original, Image.open(work / "model-input.png") as small:
            original.load()
            small.load()
            dimensions = geometry(original.size, small.size, percent)
            source_hash = source_identity(original)
            key = digest({"source_pixels_and_icc": source_hash, "percent": percent, "identity": identity["fingerprint"]})
            entry = cache / key
            with cache_lock(cache, key):
                report = cached_report(entry, key)
                if report:
                    progress("Reusing cached Klein expansion")
                    report.update(input=str(input_path), cache_hit=True, total_seconds=time.monotonic() - started)
                    publish_pair(entry / "expanded.png", output, report)
                    return
                if os.environ.get("SPATIAL_KLEIN_CACHE_ONLY") == "1":
                    raise RuntimeError("No valid cached Klein expansion is available (cache-only test mode).")
                progress(f"Generating {percent}% per edge with FLUX.2 Klein · this may take several minutes")
                infer_start = time.monotonic()
                raw = work / "generated.png"
                infer(work / "model-input.png", raw, adapter, dimensions)
                metadata = json.loads(raw.with_suffix(".metadata.json").read_text())
                progress("Restoring the full-resolution original and validating the expansion")
                expanded = work / "expanded.png"
                with Image.open(raw) as generated:
                    restored = restore_original(original, small, generated, metadata, dimensions, expanded)
                report = {"schema": 1, "helper_protocol_version": 1, "status": "complete", "backend": BACKEND,
                          "identity": identity, "input": str(input_path), "percent_per_edge": percent,
                          "cache_key": key, "source_pixels_and_icc_sha256": source_hash, "cache_hit": False,
                          "output_color_space": "sRGB", "orientation_applied": True,
                          "color_metadata": json.loads((work / "source.json").read_text()),
                          "preservation": "Full-resolution color-managed SDR sRGB source center; narrow inner seam blended with generated context",
                          "inference_and_materialization_seconds": time.monotonic() - infer_start,
                          "total_seconds": time.monotonic() - started, **restored}
                # An invalid prior pair is replaced under the per-key lock, never
                # treated as reusable merely because its filenames exist.
                if entry.exists():
                    shutil.rmtree(entry)
                publish_pair(expanded, entry, report)
                publish_pair(expanded, output, report)
                progress("SAVED " + str(output / "expanded.png"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    parser.add_argument("percent", nargs="?", type=int)
    parser.add_argument("--prepare-helper", type=Path)
    parser.add_argument("--cache-root", type=Path, default=support_root() / "Expansion Cache/Klein")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if args.check:
            identity, _, _ = check_runtime(args.prepare_helper)
            print(json.dumps(identity, sort_keys=True), flush=True)
            return
        if args.input is None or args.output is None or args.percent is None or args.prepare_helper is None:
            parser.error("INPUT OUTPUT_DIRECTORY PERCENT --prepare-helper PATH are required")
        if not 1 <= args.percent <= 20:
            parser.error("PERCENT must be 1...20")
        expand(args.input.resolve(), args.output.resolve(), args.percent, args.prepare_helper.resolve(), args.cache_root.resolve())
    except Exception as error:
        print("ERROR: " + str(error), file=sys.stderr, flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
