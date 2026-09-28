#!/usr/bin/env python3
"""Installer behavior using tiny synthetic downloads; never reads user photos."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import SetupSupport as support
import setup_drawthings as drawthings
import setup_klein as klein


class RuntimeSetupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def server(self, data, ignore_range=False, bad_range=False):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                header = self.headers.get("Range")
                requests.append(header)
                offset = int(header.split("=")[1].split("-")[0]) if header else 0
                if ignore_range:
                    offset = 0
                partial = header and not ignore_range
                self.send_response(206 if partial else 200)
                if partial:
                    start = offset + 1 if bad_range else offset
                    self.send_header("Content-Range", f"bytes {start}-{len(data)-1}/{len(data)}")
                self.send_header("Content-Length", str(len(data) - offset))
                self.end_headers()
                self.wfile.write(data[offset:])
            def log_message(self, *_):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}/model", requests

    def test_bootstrap_configuration_does_not_execute_helper_imports(self):
        helper = self.root / "Helper.py"
        helper.write_text("import module_that_is_not_installed\nMODEL='test'\nraise RuntimeError('must not run')\n")
        config = support.literal_configuration(helper, ["MODEL"])
        self.assertEqual(config.MODEL, "test")
        self.assertFalse((self.root / "__pycache__").exists())
        with self.assertRaises(RuntimeError):
            support.literal_configuration(helper, ["NOT_PRESENT"])
        # The shipped Klein installer can read all constants in a bare runtime.
        actual = klein.load_helper(klein.helper_script())
        self.assertEqual(actual.MODEL_REVISION, "02f9458e2c412d067a24fd9ddc16b85dd7f3ddab")

    def test_resume_verified_download_and_publish_atomically(self):
        data = b"model bytes" * 100
        expected = len(data), hashlib.sha256(data).hexdigest()
        target = self.root / "weights.bin"
        partial = support.partial_path(target, expected)
        partial.write_bytes(data[:17])
        url, requests = self.server(data)
        self.assertEqual(support.remaining_bytes(target, expected), len(data) - 17)
        support.download_verified(url, target, expected)
        self.assertEqual(requests, ["bytes=17-"])
        self.assertEqual(target.read_bytes(), data)
        self.assertFalse(partial.exists())

    def test_server_without_range_restarts_scratch_without_corrupt_append(self):
        data = b"new verified content" * 100
        expected = len(data), hashlib.sha256(data).hexdigest()
        target = self.root / "weights.bin"
        support.partial_path(target, expected).write_bytes(data[:9])
        url, _ = self.server(data, ignore_range=True)
        support.download_verified(url, target, expected)
        self.assertEqual(target.read_bytes(), data)

    def test_bad_hash_never_replaces_existing_model(self):
        target = self.root / "weights.bin"
        target.write_bytes(b"existing user model")
        data = b"bad data"
        expected = len(data), hashlib.sha256(b"good one").hexdigest()
        url, _ = self.server(data)
        with self.assertRaisesRegex(RuntimeError, "checksum"):
            support.download_verified(url, target, expected)
        self.assertEqual(target.read_bytes(), b"existing user model")
        self.assertFalse(support.partial_path(target, expected).exists())

    def test_invalid_range_is_rejected_without_changing_partial(self):
        data = b"model bytes" * 100
        expected = len(data), hashlib.sha256(data).hexdigest()
        target = self.root / "weights.bin"
        partial = support.partial_path(target, expected)
        partial.write_bytes(data[:17])
        url, _ = self.server(data, bad_range=True)
        with self.assertRaisesRegex(RuntimeError, "byte range"):
            support.download_verified(url, target, expected)
        self.assertEqual(partial.read_bytes(), data[:17])
        self.assertFalse(target.exists())

    def test_fully_downloaded_partial_completes_without_network(self):
        data = b"a complete model"
        expected = len(data), hashlib.sha256(data).hexdigest()
        target = self.root / "server"
        support.partial_path(target, expected).write_bytes(data)
        with patch.object(support.urllib.request, "urlopen", side_effect=AssertionError("network")):
            support.download_verified("https://invalid.example/server", target, expected, executable=True)
        self.assertEqual(target.read_bytes(), data)
        self.assertTrue(os.access(target, os.X_OK))

    def test_retry_retains_partial_and_reports_useful_failure(self):
        data = b"model bytes" * 100
        expected = len(data), hashlib.sha256(data).hexdigest()
        target = self.root / "weights.bin"
        partial = support.partial_path(target, expected)
        partial.write_bytes(data[:17])
        with patch.object(support.urllib.request, "urlopen", side_effect=OSError("connection lost")), \
                patch.object(support.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "completed data will resume"):
                support.download_verified("https://invalid.example/model", target, expected)
        self.assertEqual(partial.read_bytes(), data[:17])

    def test_parallel_install_is_blocked(self):
        with support.installation_lock(self.root):
            with self.assertRaisesRegex(RuntimeError, "already being installed"):
                with support.installation_lock(self.root):
                    self.fail("acquired twice")
        with support.installation_lock(self.root):
            pass

    def test_busy_loopback_port_selects_free_alternative(self):
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", 0))
            busy.listen()
            with patch.object(drawthings, "PORT", busy.getsockname()[1]):
                selected = drawthings.choose_port(self.root)
            self.assertNotEqual(selected, busy.getsockname()[1])
            with socket.socket() as available:
                available.bind(("127.0.0.1", selected))

    def test_managed_setup_and_children_share_cancellable_group(self):
        code = """
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import SetupSupport
child = int(subprocess.check_output([sys.executable, '-c', 'import os; print(os.getpgrp())']))
print(json.dumps({'pid': os.getpid(), 'group': os.getpgrp(), 'child_group': child,
                  'flag': os.environ.get('SPATIAL_MANAGED_SETUP')}))
"""
        result = subprocess.check_output([sys.executable, "-B", "-c", code, str(Path(support.__file__).parent)],
                                         env=dict(os.environ, SPATIAL_MANAGED_SETUP="1"), text=True)
        identity = json.loads(result)
        self.assertEqual(identity["pid"], identity["group"])
        self.assertEqual(identity["child_group"], identity["group"])
        self.assertIsNone(identity["flag"])

    def test_damaged_managed_model_pair_is_preserved_in_quarantine(self):
        models = self.root / "models"
        models.mkdir()
        names = ["qwen_3_4b_q8p.ckpt", "qwen_3_4b_q8p.ckpt-tensordata"]
        for name in names:
            (models / name).write_text(name)
        untouched = models / "good-model.ckpt"
        untouched.write_text("keep")
        drawthings.quarantine_models(models, [names[0]])
        quarantine = list(models.glob(".invalid-*"))
        self.assertEqual(len(quarantine), 1)
        for name in names:
            self.assertEqual((quarantine[0] / name).read_text(), name)
            self.assertFalse((models / name).exists())
        self.assertEqual(untouched.read_text(), "keep")

    def test_damaged_stamped_environment_forces_reinstall(self):
        lock_hash = support.sha(Path(support.__file__).with_name("drawthings-requirements.lock"))
        env = self.root / ("venv-" + lock_hash[:16])
        python = env / "bin/python"
        python.parent.mkdir(parents=True)
        python.write_text("fake")
        python.chmod(0o755)
        (env / ".spatial-packages.json").write_text(json.dumps({"lock_sha256": lock_hash}))
        calls = []
        with patch.object(support, "check_python"), \
                patch.object(support, "validate_environment", side_effect=[subprocess.CalledProcessError(1, "check"), None]), \
                patch.object(support, "run", side_effect=lambda argv, **kwargs: calls.append(argv)):
            support.install_environment(self.root, "/portable/python", "drawthings")
        install = next(call for call in calls if "install" in call)
        self.assertIn("--force-reinstall", install)
        self.assertEqual(json.loads((env / ".spatial-packages.json").read_text())["lock_sha256"], lock_hash)

    def test_interrupted_virtual_environment_cannot_install_into_base_python(self):
        lock_hash = support.sha(Path(support.__file__).with_name("drawthings-requirements.lock"))
        environment = self.root / ("venv-" + lock_hash[:16])
        python = environment / "bin/python"
        python.parent.mkdir(parents=True)
        python.write_text("damaged venv")
        python.chmod(0o755)
        calls = []
        def fake_run(argv, **kwargs):
            calls.append(argv)
            if any("Incomplete virtual environment" in str(arg) for arg in argv):
                raise subprocess.CalledProcessError(1, argv)
            if "venv" in argv:
                replacement = Path(argv[-1]) / "bin/python"
                replacement.parent.mkdir(parents=True)
                replacement.write_text("repaired venv")
                replacement.chmod(0o755)
        with patch.object(support, "check_python"), patch.object(support, "validate_environment"), \
                patch.object(support, "run", side_effect=fake_run):
            result = support.install_environment(self.root, "/portable/python", "drawthings")
        preserved = list(self.root.glob("venv-*.invalid-*/bin/python"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_text(), "damaged venv")
        self.assertEqual(result.read_text(), "repaired venv")
        install = next(call for call in calls if "install" in call)
        self.assertEqual(install[0], python)
        self.assertIn("--force-reinstall", install)

    def test_dependency_locks_have_only_hashed_prebuilt_wheels(self):
        base = Path(support.__file__).parent
        for backend in ("drawthings", "klein"):
            rows = (base / (backend + "-requirements.lock")).read_text().splitlines()
            packages = [line for line in rows if line and not line.startswith("#")]
            self.assertGreater(len(packages), 10)
            for row in packages:
                self.assertIn(" @ https://files.pythonhosted.org/", row)
                self.assertIn(".whl --hash=sha256:", row)
                self.assertEqual(len(row.split("--hash=sha256:")[1]), 64)
                self.assertTrue("-any.whl " in row or "arm64.whl " in row or "universal2.whl " in row)

    def test_environment_install_uses_new_path_and_keeps_previous_registration(self):
        old = self.root / "venv"
        old.mkdir()
        (old / "keep").write_text("old environment")
        registration = self.root / "runtime.json"
        registration.write_text('{"python":"previous"}')
        def fake_run(argv, **kwargs):
            if "venv" in argv:
                target = Path(argv[-1]) / "bin/python"
                target.parent.mkdir(parents=True)
                target.write_text("fake")
                target.chmod(0o755)
            if "install" in argv:
                self.assertIn("--require-hashes", argv)
                self.assertIn("--only-binary=:all:", argv)
                raise subprocess.CalledProcessError(1, argv)
        with patch.object(support, "check_python"), patch.object(support, "run", side_effect=fake_run):
            with self.assertRaises(subprocess.CalledProcessError):
                support.install_environment(self.root, "/portable/python", "drawthings")
        self.assertEqual(registration.read_text(), '{"python":"previous"}')
        self.assertEqual((old / "keep").read_text(), "old environment")


if __name__ == "__main__":
    unittest.main()
