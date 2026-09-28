#!/usr/bin/env python3
"""Synthetic-only geometry, exact source preservation, and persistent cache tests.

Run using the installed Klein Python runtime; no models are loaded by these tests.
"""
import importlib.util
import json
import math
import os
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageCms

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
spec = importlib.util.spec_from_file_location("klein", Path(__file__).resolve().parents[1] / "Sources/ExpandPhotoKlein.py")
klein = importlib.util.module_from_spec(spec)
spec.loader.exec_module(klein)


def synthetic_source(width=803, height=507):
    y, x = np.indices((height, width))
    pixels = np.stack((x % 256, y % 256, (x + y) % 256), axis=2).astype(np.uint8)
    image = Image.fromarray(pixels)
    image.info["icc_profile"] = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    return image


def synthetic_generation(small, dimensions):
    mx, _, my, _ = dimensions["requested_model_padding_lrtb"]
    width = math.ceil((small.width + 2 * mx) / 16) * 16
    height = math.ceil((small.height + 2 * my) / 16) * 16
    y, x = np.indices((height, width))
    generated = Image.fromarray(np.stack((x % 256, y % 256, (x + y) % 256), axis=2).astype(np.uint8))
    metadata = {"source_image_width": small.width, "source_image_height": small.height,
                "outpaint_target_width": width, "outpaint_target_height": height,
                "outpaint_source_paste_left": mx, "outpaint_source_paste_top": my,
                "outpaint_source_restore_applied": True}
    return generated, metadata


class KleinExpansionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_symmetric_geometry_crops_rounded_model_canvas_and_preserves_center(self):
        original = synthetic_source()
        small = original.resize((383, 242))
        for percent in (1, 5, 13, 20):
            with self.subTest(percent=percent):
                dimensions = klein.geometry(original.size, small.size, percent)
                generated, metadata = synthetic_generation(small, dimensions)
                path = self.root / f"{percent}.png"
                report = klein.restore_original(original, small, generated, metadata, dimensions, path)
                px, right, py, bottom = report["padding_lrtb"]
                self.assertEqual(px, right)
                self.assertEqual(py, bottom)
                self.assertEqual(report["output_size"], [original.width + 2 * px, original.height + 2 * py])
                x, y, w, h = report["preserved_box_top_left"]
                with Image.open(path) as output:
                    self.assertEqual(output.size, tuple(report["output_size"]))
                    self.assertEqual(output.crop((x, y, x + w, y + h)).tobytes(),
                                     original.crop((x - px, y - py, x - px + w, y - py + h)).tobytes())
                    self.assertTrue(output.info.get("icc_profile"))
                    # Generated canvas dimensions include a rounded trailing
                    # sliver. Verify the border uses source-aligned crop mapping,
                    # rather than stretching that sliver into the symmetric view.
                    sx, sy = original.width / small.width, original.height / small.height
                    left, top = metadata["outpaint_source_paste_left"], metadata["outpaint_source_paste_top"]
                    crop = (left - px / sx, top - py / sy,
                            left + small.width + px / sx, top + small.height + py / sy)
                    from KleinColorMatch import harmonize_border
                    matched, _ = harmonize_border(generated, small.convert("RGB"), left, top)
                    expected_border = matched.resize(output.size, Image.Resampling.LANCZOS, box=crop)
                    self.assertEqual(output.crop((0, 0, output.width, py)).tobytes(),
                                     expected_border.crop((0, 0, output.width, py)).tobytes())
                self.assertEqual(report["preserved_interior_max_rgb_error"], 0)
                self.assertEqual(report["output_sha256"], klein.sha(path))

    def test_bad_model_geometry_and_failed_restore_are_rejected(self):
        original = synthetic_source(103, 71)
        small = original.resize((51, 35))
        dimensions = klein.geometry(original.size, small.size, 5)
        generated, metadata = synthetic_generation(small, dimensions)
        for changed in ({"outpaint_target_width": 999}, {"source_image_width": 1},
                        {"outpaint_source_restore_applied": False}, {"outpaint_source_paste_left": 0}):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                klein.restore_original(original, small, generated, {**metadata, **changed}, dimensions, self.root / "bad.png")

    def test_source_identity_includes_pixels_and_icc(self):
        image = synthetic_source(23, 31)
        baseline = klein.source_identity(image)
        clone = image.copy()
        self.assertEqual(klein.source_identity(clone), baseline)
        clone.info["icc_profile"] = b"different color profile"
        self.assertNotEqual(klein.source_identity(clone), baseline)
        clone = image.copy()
        clone.putpixel((10, 10), (1, 2, 3))
        self.assertNotEqual(klein.source_identity(clone), baseline)

    def test_cache_survives_new_invocation_and_rejects_corruption(self):
        source = self.root / "input.png"
        original = synthetic_source(317, 209)
        original.save(source, icc_profile=original.info["icc_profile"])
        cache = self.root / "cache"
        count = [0]
        def prepare(helper, input_path, work):
            with Image.open(input_path) as image:
                image.save(work / "original-srgb.png", icc_profile=image.info["icc_profile"])
                image.resize((159, 105)).save(work / "model-input.png")
            (work / "source.json").write_text("{}")
        def infer(small_path, raw, adapter, dimensions):
            count[0] += 1
            with Image.open(small_path) as small:
                generated, metadata = synthetic_generation(small, dimensions)
            generated.save(raw)
            raw.with_suffix(".metadata.json").write_text(json.dumps(metadata))
        with patch.object(klein, "check_runtime", return_value=({"fingerprint": "synthetic-runtime-v1"}, None, None)), \
             patch.object(klein, "prepare_photo", side_effect=prepare), patch.object(klein, "infer", side_effect=infer):
            klein.expand(source, self.root / "first", 5, Path("helper"), cache)
            self.assertEqual(count[0], 1)
            with patch.dict(os.environ, {"SPATIAL_KLEIN_CACHE_ONLY": "1"}):
                klein.expand(source, self.root / "second", 5, Path("helper"), cache)
            self.assertEqual(count[0], 1)
            self.assertEqual(klein.sha(self.root / "first/expanded.png"), klein.sha(self.root / "second/expanded.png"))
            self.assertTrue(json.loads((self.root / "second/expansion.json").read_text())["cache_hit"])
            with patch.dict(os.environ, {"SPATIAL_KLEIN_CACHE_ONLY": "1"}), self.assertRaises(RuntimeError):
                klein.expand(source, self.root / "different-percent", 6, Path("helper"), cache)
            entry = next(path for path in cache.iterdir() if not path.name.startswith("."))
            (entry / "expanded.png").write_bytes(b"corrupt")
            with patch.dict(os.environ, {"SPATIAL_KLEIN_CACHE_ONLY": "1"}), self.assertRaises(RuntimeError):
                klein.expand(source, self.root / "corrupt", 5, Path("helper"), cache)
            self.assertFalse((self.root / "corrupt/expansion.json").exists())
            klein.expand(source, self.root / "repaired", 5, Path("helper"), cache)
            self.assertEqual(count[0], 2)

    def test_incomplete_cache_is_never_complete(self):
        entry = self.root / "partial"
        entry.mkdir()
        (entry / "expanded.png").write_bytes(b"image")
        self.assertIsNone(klein.cached_report(entry, "key"))
        klein.write_json(entry / "expansion.json", {"status": "working", "cache_key": "key"})
        self.assertIsNone(klein.cached_report(entry, "key"))
        klein.write_json(entry / "expansion.json", {"status": "complete", "cache_key": "other", "output_sha256": klein.sha(entry / "expanded.png")})
        self.assertIsNone(klein.cached_report(entry, "key"))

    def test_publish_failure_removes_unclaimed_output(self):
        source = self.root / "image.png"
        source.write_bytes(b"data")
        destination = self.root / "output"
        with patch.object(klein, "write_json", side_effect=OSError("no space")), self.assertRaises(OSError):
            klein.publish_pair(source, destination, {})
        self.assertFalse((destination / "expanded.png").exists())
        self.assertFalse((destination / "expansion.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
