#!/usr/bin/env python3
"""Synthetic regression checks for Klein's source-preserving border color match."""
import importlib.util
import json
from pathlib import Path
import unittest

import numpy as np
from PIL import Image

spec = importlib.util.spec_from_file_location("klein_color", Path(__file__).resolve().parents[1] / "Sources/KleinColorMatch.py")
color = importlib.util.module_from_spec(spec)
spec.loader.exec_module(color)


def mask(canvas_size, source_size, left, top):
    width, height = canvas_size
    sw, sh = source_size
    border = np.ones((height, width), dtype=bool)
    border[top:top + sh, left:left + sw] = False
    return border


class KleinColorTests(unittest.TestCase):
    def test_oklab_roundtrip_covers_srgb_gamut(self):
        rgb = np.random.default_rng(481).integers(0, 256, (64, 64, 3), dtype=np.uint8)
        result = color._from_oklab(color._to_oklab(rgb))
        self.assertLessEqual(np.abs(result.astype(int)-rgb).max(), 1)

    def test_purple_tint_corrected_through_outer_edges_and_corners(self):
        source = Image.new("RGB", (120, 80), (130, 119, 96))
        target = color._to_oklab(np.asarray(source))[0, 0]
        tinted = color._from_oklab(target + np.array([-.10, .065, -.055], np.float32))
        generated = Image.new("RGB", (168, 112), tuple(tinted))
        corrected, report = color.harmonize_border(generated, source, 24, 16)
        border = mask(generated.size, source.size, 24, 16)
        self.assertLessEqual(np.abs(np.asarray(corrected).astype(int)-np.asarray(source)[0, 0])[border].max(), 2)
        self.assertGreater(max(report["boundary_delta_before"].values()), .10)
        self.assertLess(max(report["boundary_delta_after"].values()), .002)
        json.dumps(report, allow_nan=False)

    def test_exact_source_pixels_even_if_model_changed_the_center(self):
        pixels = np.random.default_rng(31).integers(0, 256, (81, 119, 3), dtype=np.uint8)
        source = Image.fromarray(pixels)
        generated = Image.new("RGB", (177, 109), (191, 44, 176))
        corrected, _ = color.harmonize_border(generated, source, 19, 13)
        np.testing.assert_array_equal(np.asarray(corrected)[13:94, 19:138], pixels)

    def test_overlap_carries_color_correction_across_all_four_boundaries(self):
        source = Image.new("RGB", (160, 120), (130, 119, 96))
        base = color._to_oklab(np.asarray(source))[0, 0]
        tinted = color._from_oklab(base + np.array([-.08, .065, -.055], np.float32))
        generated = Image.new("RGB", (224, 168), tuple(tinted))
        corrected, report = color.harmonize_border(generated, source, 32, 24, restore_inset=18)
        rgb = np.asarray(corrected).astype(int)
        # The former implementation corrected the outside but restored raw
        # generated pixels inside, leaving a new hard rectangle here.
        for a, b in [(rgb[80,31],rgb[80,32]), (rgb[80,191],rgb[80,192]),
                     (rgb[23,100],rgb[24,100]), (rgb[143,100],rgb[144,100])]:
            self.assertLessEqual(np.abs(a-b).max(), 2)
        np.testing.assert_array_equal(rgb[42:126,50:174], np.asarray(source)[18:102,18:142])
        self.assertTrue(report["continuous_overlap_correction"])

    def test_multiband_lighting_transition_keeps_detail_and_exact_interior(self):
        yy, xx = np.indices((280, 360))
        rgb = np.empty((280, 360, 3), np.uint8)
        rgb[:] = (110, 105, 95)
        rgb += ((xx+yy) % 2 * 24).astype(np.uint8)[..., None]
        generated = Image.fromarray(rgb)
        source = Image.new("RGB", (200, 140), (170, 150, 120))
        result, report = color.blend_overlap(generated, source, 80, 70, 18)
        output = np.asarray(result)
        np.testing.assert_array_equal(output[88:192,98:262], np.asarray(source)[18:122,18:182])
        np.testing.assert_array_equal(output[:6], rgb[:6])
        # Fine detail in the new border must survive the broad lighting blend.
        near = output[100:180,60:72,0].astype(int)
        self.assertGreater(np.abs(np.diff(near, axis=0)).mean(), 20)
        # Low-frequency brightness should change gradually, not in a frame.
        pair_means = output[130:132,:,0].mean(axis=0)
        self.assertLess(np.abs(np.diff(pair_means[60:120])).max(), 5)
        self.assertFalse(report["final_image_blurred"])

    def test_multiband_rejects_unprotected_or_out_of_canvas_geometry(self):
        for left, top, inset in [(0,0,0),(0,0,25),(-1,0,12),(0,21,12)]:
            with self.subTest(geometry=(left,top,inset)), self.assertRaises(ValueError):
                color.blend_overlap(Image.new("RGB",(80,70)), Image.new("RGB",(60,50)),left,top,inset)

    def test_already_matching_border_is_unchanged(self):
        # Fine periodic texture matches across the boundary. A correction must
        # not impose a new grade merely because this is generated content.
        yy, xx = np.indices((128, 192))
        rgb = np.empty((128, 192, 3), np.uint8)
        rgb[:] = (90, 131, 110)
        rgb += ((xx+yy) % 2 * 10).astype(np.uint8)[..., None]
        generated = Image.fromarray(rgb)
        source = generated.crop((32, 24, 160, 104))
        corrected, report = color.harmonize_border(generated, source, 32, 24)
        np.testing.assert_array_equal(np.asarray(corrected), rgb)
        self.assertLess(max(report["boundary_delta_before"].values()), .00001)

    def test_generated_texture_is_retained_while_tint_is_removed(self):
        yy, xx = np.indices((128, 192))
        lab = np.zeros((128, 192, 3), np.float32)
        lab[:] = [.6, -.025, .055]
        lab[:, :, 0] += ((xx+yy) % 2 * .08)
        reference = color._from_oklab(lab)
        source = Image.fromarray(reference[24:104, 32:160])
        generated = Image.fromarray(color._from_oklab(lab + np.array([-.05, .05, -.04], np.float32)))
        corrected, _ = color.harmonize_border(generated, source, 32, 24)
        border = mask(generated.size, source.size, 32, 24)
        result_lab = color._to_oklab(np.asarray(corrected))
        expected_lab = color._to_oklab(reference)
        self.assertLess(np.abs(result_lab-expected_lab)[border].mean(), .002)
        self.assertGreater(result_lab[..., 0][border].std(), .038)

    def test_color_correction_adapts_to_different_edges(self):
        # Different color casts around a neutral source must each be corrected,
        # including a continuous corner transition between adjacent sides.
        source = Image.new("RGB", (120, 80), (134, 141, 138))
        base = color._to_oklab(np.asarray(source))[0, 0]
        lab = np.zeros((112, 168, 3), np.float32) + base
        field = np.zeros_like(lab)
        field[16:96, :24] = [-.09, .04, -.06]
        field[16:96, 144:] = [-.02, .02, -.03]
        field[:16, 24:144] = [.01, .04, -.04]
        field[96:, 24:144] = [-.03, .07, -.03]
        # Reproduce a spatially continuous color cast, independent of the
        # implementation, using angles/distances from each corner.
        for xs, ys, side, cap, reverse_x, reverse_y in [
            (slice(0,24), slice(0,16), field[16,0], field[0,24], True, True),
            (slice(144,168), slice(0,16), field[16,167], field[0,143], False, True),
            (slice(0,24), slice(96,112), field[95,0], field[111,24], True, False),
            (slice(144,168), slice(96,112), field[95,167], field[111,143], False, False)]:
            x = np.arange(1, 25)[::-1] if reverse_x else np.arange(1, 25)
            y = np.arange(1, 17)[::-1] if reverse_y else np.arange(1, 17)
            ratio = x[None, :]/(x[None, :]+y[:, None])
            field[ys, xs] = side * ratio[..., None] + cap * (1-ratio[..., None])
        generated = Image.fromarray(color._from_oklab(lab+field))
        corrected, report = color.harmonize_border(generated, source, 24, 16)
        before = np.abs(np.asarray(generated).astype(int)-np.asarray(source)[0, 0])
        after = np.abs(np.asarray(corrected).astype(int)-np.asarray(source)[0, 0])
        self.assertLess(after.mean(), before.mean() * .5)
        for edge, difference in report["boundary_delta_before"].items():
            self.assertLess(report["boundary_delta_after"][edge], difference * .35)
        # Corners should interpolate, not introduce a hard color boundary.
        corner = np.asarray(corrected)[:16, :24].astype(int)
        self.assertLess(np.abs(np.diff(corner, axis=0)).max(), 8)
        self.assertLess(np.abs(np.diff(corner, axis=1)).max(), 8)

    def test_one_sided_and_zero_padding(self):
        source = Image.new("RGB", (50, 40), (140, 136, 151))
        for size, offset in [((70,40),(0,0)), ((50,60),(0,20)), ((50,40),(0,0))]:
            with self.subTest(size=size, offset=offset):
                generated = Image.new("RGB", size, (134, 116, 157))
                result, report = color.harmonize_border(generated, source, *offset)
                self.assertEqual(result.size, size)
                self.assertLessEqual(np.abs(np.asarray(result).astype(int)-np.asarray(source)[0,0]).max(), 2)
                json.dumps(report, allow_nan=False)

    def test_tiny_and_asymmetric_images(self):
        for source_size, size, offset in [((1,1),(3,4),(1,2)), ((2,50),(7,70),(1,9))]:
            source = Image.new("RGB", source_size, (90, 125, 135))
            generated = Image.new("RGB", size, (97, 107, 169))
            result, report = color.harmonize_border(generated, source, *offset)
            self.assertLessEqual(np.abs(np.asarray(result).astype(int)-np.asarray(source)[0,0]).max(), 2)
            json.dumps(report, allow_nan=False)

    def test_rejects_invalid_source_placement(self):
        source = Image.new("RGB", (50,40))
        generated = Image.new("RGB", (70,60))
        for offset in [(-1,0),(0,-1),(21,0),(0,21),(.5,1),(1,.5)]:
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                color.harmonize_border(generated, source, *offset)


if __name__ == "__main__":
    unittest.main()
