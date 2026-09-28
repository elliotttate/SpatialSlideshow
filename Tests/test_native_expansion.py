"""Research bridge guards and cache validation; no Photos or inference calls."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("native",Path(__file__).resolve().parents[1]/"Sources/ExpandPhotoNative.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeExpansionTests(unittest.TestCase):
    def test_requires_exact_original_photos_process(self):
        with patch.object(native.subprocess,"check_output",return_value="42 /tmp/Photos.app/Contents/MacOS/Photos\n"):
            with self.assertRaisesRegex(RuntimeError,"original Apple Photos"): native.photos_pid()
        with patch.object(native.subprocess,"check_output",return_value="42 /tmp/Photos.app/Contents/MacOS/Photos\n99 "+native.PHOTOS+"\n"):
            self.assertEqual(native.photos_pid(),99)

    def test_cache_requires_matching_hash_key_and_geometry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = root/"expanded.png"
            image.write_bytes(b"\x89PNG\r\n\x1a\n"+struct.pack(">I",13)+b"IHDR"+struct.pack(">II",100,80))
            report = {"status":"complete","cache_key":"key","output_sha256":native.sha(image),"output_size":[100,80]}
            native.write_json(root/"expansion.json",report)
            self.assertEqual(native.cached(root,"key"),report)
            self.assertIsNone(native.cached(root,"other-key"))
            image.write_bytes(image.read_bytes()+b"tampered")
            self.assertIsNone(native.cached(root,"key"))
            report["output_sha256"] = native.sha(image)
            report["output_size"] = [200,160]
            native.write_json(root/"expansion.json",report)
            self.assertIsNone(native.cached(root,"key"))

    def test_cancel_before_submission_does_not_leave_queued_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(native,"current_job",Path(tmp)), patch.object(native,"cancelled",True), patch.object(native,"attach_started",False):
                with self.assertRaisesRegex(RuntimeError,"cancelled"): native.check_cancel()
            self.assertEqual(json.loads((Path(tmp)/"result.json").read_text())["status"],"failed")

    def test_cancel_after_submission_keeps_native_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"result.json"
            native.write_json(path,{"status":"generating"})
            with patch.object(native,"current_job",Path(tmp)), patch.object(native,"cancelled",True), patch.object(native,"attach_started",True):
                with self.assertRaises(RuntimeError): native.check_cancel()
            self.assertEqual(json.loads(path.read_text())["status"],"generating")


if __name__ == "__main__": unittest.main()
