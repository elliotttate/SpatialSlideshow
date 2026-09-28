#!/usr/bin/env python3
"""Synthetic protocol/cache/cancellation tests; never load model weights."""
import asyncio
import json
import os
from pathlib import Path
import signal
import socket
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageCms

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
import ExpandPhotoDrawThings as dt


def source_image(size=(317, 209)):
    y, x = np.indices(size[::-1])
    image = Image.fromarray(np.stack((x % 256, y % 256, (x + y) % 256), axis=-1).astype(np.uint8))
    image.info["icc_profile"] = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    return image


class DrawThingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.config_path = self.root / ".runtime-staged.json"
        self.config_path.write_text(json.dumps({"schema": 1, "release": dt.SERVER_RELEASE, "port": 7863,
            "server_binary": str(self.root / "server"), "models_directory": str(self.root / "models")}))
        self.config = dt.load_runtime(self.config_path)

    def tearDown(self):
        self.temporary.cleanup()

    def test_staged_runtime_works_and_remote_destinations_are_rejected(self):
        self.assertEqual(self.config["runtime_root"], str(self.root))
        original = json.loads(self.config_path.read_text())
        for change in ({"host": "example.com"}, {"tls": False}, {"port": True},
                       {"server_binary": "relative"}, {"release": "unverified"}):
            self.config_path.write_text(json.dumps({**original, **change}))
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                dt.load_runtime(self.config_path)

    def test_wire_mask_dimensions_and_original_pixels(self):
        from drawthings_py.request_builder import build_grpc_message
        from drawthings_py.generated.dt_grpc.config_generated import GenerationConfiguration
        for size in ((768, 184), (768, 432), (768, 576), (159, 105)):
            with self.subTest(size=size):
                small = source_image(size)
                dimensions = dt.common.geometry((size[0] * 3 + 1, size[1] * 3 + 1), size, 20)
                request, metadata = dt.build_request(small, dimensions, self.root)
                message, _ = build_grpc_message(request)
                fbs = GenerationConfiguration.GetRootAs(message.configuration, 0)
                width, height = metadata["outpaint_target_width"], metadata["outpaint_target_height"]
                left, top = metadata["outpaint_source_paste_left"], metadata["outpaint_source_paste_top"]
                self.assertEqual((fbs.StartWidth() * 64, fbs.StartHeight() * 64), (width, height))
                self.assertEqual(fbs.Model().decode(), dt.MODEL)
                self.assertEqual((fbs.Seed(), fbs.Steps(), fbs.GuidanceScale()), (8612, 4, 1))
                self.assertEqual(struct.unpack("<17I", message.image[:68])[5:9], (1, height, width, 3))
                tensor = np.frombuffer(message.image[68:], "<f2").reshape(height, width, 3)
                decoded = np.rint((tensor.astype(np.float32) + 1) * 127.5).clip(0, 255).astype(np.uint8)
                self.assertTrue(np.array_equal(decoded[top:top + small.height, left:left + small.width], np.asarray(small)))
                mask = np.frombuffer(message.mask[68:], np.uint8).reshape(height, width)
                self.assertEqual(set(np.unique(mask)), {0, 2})
                overlap = metadata["outpaint_mask_overlap_pixels"]
                self.assertEqual(overlap, 12)
                self.assertEqual(mask[top + overlap:top + small.height - overlap,
                                      left + overlap:left + small.width - overlap].max(), 0)
                self.assertEqual(mask[top, left], 2)
                self.assertEqual(mask[top + small.height - 1, left + small.width - 1], 2)
                self.assertEqual(mask[0, 0], 2)
                self.assertGreaterEqual(width - left - small.width, left)
                self.assertGreaterEqual(height - top - small.height, top)

    def test_persistent_cache_exact_pixels_and_runtime_invalidation(self):
        source = self.root / "source.png"
        original = source_image()
        original.save(source, icc_profile=original.info["icc_profile"])
        cache = self.root / "cache"
        count = [0]
        def prepare(helper, input_path, work):
            original.save(work / "original-srgb.png", icc_profile=original.info["icc_profile"])
            original.resize((159, 105)).save(work / "model-input.png")
            (work / "source.json").write_text("{}")
        def infer(small_path, raw, config, dimensions, timeout):
            count[0] += 1
            with Image.open(small_path) as small:
                _, metadata = dt.build_request(small, dimensions, raw.parent)
            with Image.open(raw.parent / "canvas.png") as canvas:
                canvas.save(raw)
            return {**metadata, "outpaint_source_restore_applied": True,
                    "outpaint_source_restore_inset_pixels": 18}
        identity = {"fingerprint": "runtime-a"}
        with patch.object(dt, "check_runtime", return_value=(identity, self.config)), \
             patch.object(dt, "prepare_photo", side_effect=prepare), patch.object(dt, "infer", side_effect=infer):
            dt.expand(source, self.root / "first", 20, Path("helper"), cache)
            with patch.dict(os.environ, {"SPATIAL_DRAWTHINGS_CACHE_ONLY": "1"}):
                dt.expand(source, self.root / "second", 20, Path("helper"), cache)
                self.assertEqual(count[0], 1)
                identity["fingerprint"] = "runtime-b"
                with self.assertRaises(RuntimeError):
                    dt.expand(source, self.root / "changed-runtime", 20, Path("helper"), cache)
                identity["fingerprint"] = "runtime-a"
            report = json.loads((self.root / "second/expansion.json").read_text())
            self.assertTrue(report["cache_hit"])
            self.assertEqual(report["backend"], dt.BACKEND)
            self.assertEqual(report["output_color_space"], "sRGB")
            self.assertEqual(report["seam_blend"], "multiband-generated-overlap")
            x, y, w, h = report["preserved_box_top_left"]
            px, py, _, _ = report["original_box_top_left"]
            with Image.open(self.root / "second/expanded.png") as output:
                self.assertEqual(output.crop((x, y, x+w, y+h)).tobytes(),
                                 original.crop((x-px, y-py, x-px+w, y-py+h)).tobytes())
                self.assertTrue(output.info.get("icc_profile"))
            entry = cache / report["cache_key"]
            (entry / "expanded.png").write_bytes(b"corrupted")
            with patch.dict(os.environ, {"SPATIAL_DRAWTHINGS_CACHE_ONLY": "1"}), self.assertRaises(RuntimeError):
                dt.expand(source, self.root / "corrupt", 20, Path("helper"), cache)
            self.assertFalse((self.root / "corrupt/expansion.json").exists())

    def test_inference_keeps_only_a_narrow_generated_overlap(self):
        small = source_image((159, 105))
        small_path = self.root / "small.png"
        small.save(small_path)
        dimensions = dt.common.geometry(small.size, small.size, 20)
        raw = self.root / "generated.png"
        async def generate(request, config, path, timeout):
            with Image.open(self.root / "canvas.png") as canvas:
                Image.new("RGB", canvas.size, (17, 34, 51)).save(path)
        with patch.object(dt, "ensure_server", return_value=self.state()), \
             patch.object(dt, "generate_request", side_effect=generate), \
             patch.object(dt, "owns_server", return_value=False):
            metadata = dt.infer(small_path, raw, self.config, dimensions)
        x, y = metadata["outpaint_source_paste_left"], metadata["outpaint_source_paste_top"]
        inset = metadata["outpaint_source_restore_inset_pixels"]
        self.assertEqual(inset, 18)
        with Image.open(raw) as output:
            self.assertEqual(output.getpixel((x, y)), (17, 34, 51))
            self.assertEqual(output.crop((x+inset, y+inset, x+small.width-inset, y+small.height-inset)).tobytes(),
                             small.crop((inset, inset, small.width-inset, small.height-inset)).tobytes())

    def test_overlap_feather_removes_a_hard_step_without_blurring_the_interior(self):
        original = Image.new("RGB", (384, 256), (220, 220, 220))
        small = original.resize((192, 128))
        dimensions = dt.common.geometry(original.size, small.size, 20)
        _, metadata = dt.build_request(small, dimensions, self.root)
        generated = Image.new("RGB", (metadata["outpaint_target_width"], metadata["outpaint_target_height"]), (40, 40, 40))
        x, y = metadata["outpaint_source_paste_left"], metadata["outpaint_source_paste_top"]
        generated.paste(small.crop((18, 18, small.width-18, small.height-18)), (x+18, y+18))
        metadata.update(outpaint_source_restore_applied=True, outpaint_source_restore_inset_pixels=18)
        output = self.root / "feather.png"
        # Isolate the seam from the independent border-color correction.
        with patch("KleinColorMatch.harmonize_border", side_effect=lambda g, *args, **kwargs: (g.copy(), {})):
            report = dt.common.restore_original(original, small, generated, metadata, dimensions, output,
                                                generated_overlap_model_pixels=18)
        px, py, w, h = report["original_box_top_left"]
        with Image.open(output) as image:
            row = np.asarray(image)[py+h//2, :, 0].astype(int)
            self.assertLess(abs(row[px]-row[px-1]), 5)
            self.assertLess(np.max(np.abs(np.diff(row[px-2:px+40]))), 15)
            self.assertEqual(image.crop((px+36, py+36, px+w-36, py+h-36)).tobytes(),
                             original.crop((36, 36, w-36, h-36)).tobytes())
            # This small canvas lies within the 64-model-pixel lighting band.
            # Its exterior may brighten, but must stay between the two inputs;
            # the separate multiband test covers exact pixels beyond the band.
            corner = image.getpixel((0, 0))
            self.assertTrue(all(40 <= channel <= 220 for channel in corner))
            self.assertEqual(len(set(corner)), 1)
        self.assertEqual(report["preserved_interior_max_rgb_error"], 0)
        with self.assertRaisesRegex(RuntimeError, "restoration contract"):
            dt.common.restore_original(original, small, generated, metadata, dimensions, self.root / "bad.png")

    def state(self):
        process = {"pid": 765432, "uid": os.getuid(), "start": "Sun Sep 27 12:00:00 2026",
                   "command": str(self.root / "server") + " models --name SpatialSlideshow-" + "a" * 32}
        return {"pid": process["pid"], "process": process, "launch_token": "a" * 32,
                "binary": str(self.root / "server"), "last_used_at": 0, "log": "server.log"}

    def test_pid_reuse_and_changed_command_never_kill_unowned_process(self):
        state = self.state()
        for change in ({"start": "another start"}, {"command": "/bin/sleep 1"}, {"uid": os.getuid() + 1}):
            with self.subTest(change=change), patch.object(dt, "process_snapshot", return_value={**state["process"], **change}), \
                 patch.object(dt.os, "kill") as kill:
                self.assertFalse(dt.stop_owned_server(self.config, state))
                kill.assert_not_called()
        with patch.object(dt, "process_snapshot", return_value=state["process"]):
            self.assertTrue(dt.owns_server(state))

    def test_busy_operation_and_recent_use_prevent_idle_stop(self):
        state = self.state()
        dt.common.write_json(self.root / "server-state.json", state)
        with dt.lock_file(self.root / "server-operation.lock"), patch.object(dt, "stop_owned_server") as stop:
            self.assertFalse(dt.stop_server(self.config))
            stop.assert_not_called()
        with patch.object(dt.time, "time", return_value=10), patch.object(dt, "stop_owned_server") as stop:
            self.assertFalse(dt.stop_server(self.config, idle_seconds=600))
            stop.assert_not_called()

    def test_timeout_and_cancellation_stop_owned_server(self):
        small_path = self.root / "small.png"
        small = source_image((159, 105))
        small.save(small_path)
        dimensions = dt.common.geometry(small.size, small.size, 20)
        for error in (TimeoutError(), asyncio.CancelledError()):
            async def fail(*args):
                raise error
            with self.subTest(error=type(error)), patch.object(dt, "ensure_server", return_value=self.state()), \
                 patch.object(dt, "generate_request", side_effect=fail), patch.object(dt, "owns_server", return_value=False), \
                 patch.object(dt, "stop_owned_server") as stop:
                with self.assertRaises((RuntimeError, asyncio.CancelledError)):
                    dt.infer(small_path, self.root / "generated.png", self.config, dimensions, 1)
                stop.assert_called_once()
                self.assertFalse((self.root / "generated.png").exists())

    def test_port_conflict_uses_another_local_port_without_killing_foreign_service(self):
        self.config_path = self.root / "runtime.json"
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as foreign:
            foreign.bind(("127.0.0.1", 0))
            foreign.listen()
            foreign_port = foreign.getsockname()[1]
            registration = {key: value for key, value in self.config.items()
                            if key not in ("config_path", "runtime_root")}
            registration["port"] = foreign_port
            self.config_path.write_text(json.dumps(registration))
            self.config = dt.load_runtime(self.config_path)
            with dt.lock_file(self.root / "server-operation.lock"), \
                 patch.object(dt, "port_open", return_value=True), \
                 patch.object(dt, "owns_server", side_effect=lambda state: bool(state.get("launch_token"))), \
                 patch.object(dt, "process_snapshot", return_value=self.state()["process"]), \
                 patch.object(dt.subprocess, "Popen") as start, patch.object(dt.os, "kill") as kill:
                start.return_value.pid = self.state()["pid"]
                start.return_value.poll.return_value = None
                result = dt.ensure_server(self.config)
                command = start.call_args.args[0]
                self.assertNotEqual(self.config["port"], foreign_port)
                self.assertEqual(command[command.index("--address") + 1], "127.0.0.1")
                self.assertEqual(int(command[command.index("--port") + 1]), self.config["port"])
                self.assertEqual(result["port"], self.config["port"])
                self.assertEqual(json.loads(self.config_path.read_text()), {**registration, "port": self.config["port"]})
                kill.assert_not_called()
                start.return_value.terminate.assert_not_called()
                start.return_value.kill.assert_not_called()
            # The real foreign listener remains available after fallback.
            self.assertTrue(dt.port_open(foreign_port))
            self.assertEqual(foreign.getsockname(), ("127.0.0.1", foreign_port))

    def test_transport_port_does_not_overwrite_staged_or_changed_registration(self):
        original = self.config_path.read_bytes()
        self.assertFalse(dt.persist_runtime_port(self.config, 12345))
        self.assertEqual(self.config_path.read_bytes(), original)
        registered = self.root / "runtime.json"
        registered.write_bytes(original)
        config = dt.load_runtime(registered)
        changed = {**json.loads(original), "models_directory": str(self.root / "new-models")}
        registered.write_text(json.dumps(changed))
        self.assertFalse(dt.persist_runtime_port(config, 12345))
        self.assertEqual(json.loads(registered.read_text()), changed)
        registered.unlink()
        registered.symlink_to(self.config_path)
        self.assertFalse(dt.persist_runtime_port(dt.load_runtime(registered), 12345))
        self.assertTrue(registered.is_symlink())
        self.assertEqual(self.config_path.read_bytes(), original)

    def test_migrated_encoder_pair_keeps_cache_identity_and_rejects_corruption(self):
        models = Path(self.config["models_directory"])
        models.mkdir()
        server = Path(self.config["server_binary"])
        server.write_bytes(b"verified fake server")
        server.chmod(0o755)
        encoder = models / "qwen_3_4b_q8p.ckpt"
        tensor = models / "qwen_3_4b_q8p.ckpt-tensordata"
        encoder.write_bytes(b"published encoder weights")
        published = {encoder.name: (encoder.stat().st_size, dt.common.sha(encoder))}
        metadata_data, tensor_data = b"metadata", b"external tensor data"
        import hashlib
        migrated = {encoder.name: (len(metadata_data), hashlib.sha256(metadata_data).hexdigest()),
                    tensor.name: (len(tensor_data), hashlib.sha256(tensor_data).hexdigest())}
        with patch.object(dt, "WEIGHTS", published), patch.object(dt, "MIGRATED_QWEN", migrated), \
             patch.object(dt, "SERVER_SIZE", server.stat().st_size), patch.object(dt, "SERVER_SHA256", dt.common.sha(server)), \
             patch.object(dt, "ensure_server") as start:
            before, _ = dt.check_runtime(runtime_config=self.config_path)
            registration = json.loads(self.config_path.read_text())
            registration["port"] = 54123
            self.config_path.write_text(json.dumps(registration))
            different_port, _ = dt.check_runtime(runtime_config=self.config_path)
            self.assertEqual(before["fingerprint"], different_port["fingerprint"])
            encoder.write_bytes(metadata_data)
            tensor.write_bytes(tensor_data)
            after, _ = dt.check_runtime(runtime_config=self.config_path)
            self.assertEqual(before["fingerprint"], after["fingerprint"])
            tensor.write_bytes(b"wrong external data")
            with self.assertRaisesRegex(RuntimeError, "incomplete|checksum"):
                dt.check_runtime(runtime_config=self.config_path)
            start.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
