#!/usr/bin/env python3
"""Temporary stereo fixtures test recorded mouse import and phase validation."""

import array
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
import wave
import zipfile

from extract_sounds import json_bytes
import import_thock_mouse_sounds as importer
from check_mouse_sound_assets import check_mouse_assets

FFMPEG = os.environ.get("CLICKY_TEST_FFMPEG") or shutil.which("ffmpeg") or ""


def stereo_wav(level, channels=2):
    values = [0] * (220 * channels) + [level, -level] * (200 * channels) + [0] * (50 * channels)
    # Both channels share a short deterministic fixture; nothing is shipped.
    if channels == 2:
        values = [v for sample in ([0] * 220 + [level, -level] * 200 + [0] * 50) for v in (sample, sample)]
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(channels); writer.setsampwidth(2); writer.setframerate(44100)
        writer.writeframes(array.array("h", values).tobytes())
    return output.getvalue()


class MouseImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.assets = self.root / "Assets"; self.assets.mkdir()
        self.cache = self.root / "cache"; self.cache.mkdir()
        self.original = self.assets / "original.wav"; self.original.write_bytes(stereo_wav(100))
        self.metadata = {"name": "Fixture Mouse", "brand": "Fixture", "author": "Fixture", "category": "mouse", "supportsKeyUp": True}
        self.config = {"id": "fixture", "metadata": self.metadata, "license": {"type": "CC0"}, "sounds": {
            "left": {"down": ["1.wav"], "up": ["2.wav"]}, "right": {"down": ["3.wav"], "up": ["4.wav"]}}}
        config_payload = json_bytes(self.config)
        self.source_wavs = {str(i) + ".wav": stereo_wav(level) for i, level in enumerate((8000, 2000, 4000, 1000), 1)}
        with zipfile.ZipFile(self.cache / "fixture.zip", "w") as archive:
            archive.writestr("config.json", config_payload)
            for name, payload in self.source_wavs.items(): archive.writestr(name, payload)
        registry = {"soundpacks": {"mouse": [{"id": "fixture", "metadata": self.metadata, "content": {"path": "mouse/fixture"}}]}}
        registry_payload = json_bytes(registry); (self.cache / "manifest.json").write_bytes(registry_payload)
        processing = json.loads((importer.PROJECT / "Assets/thock-mouse-sources.json").read_text())["processing"]
        self.lock = {"schemaVersion": 1, "registry": {"repository": "fixture/test", "commit": "0" * 40,
            "manifestSha256": importer.digest(registry_payload)}, "processing": processing,
            "preservedFiles": {"original.wav": importer.digest(self.original.read_bytes())}, "excludedPacks": [],
            "profiles": [{"id": "fixture-mouse", "packID": "fixture", "name": "Fixture Mouse", "subtitle": "Fixture only", "color": "000000",
                "metadata": self.metadata, "contentPath": "mouse/fixture", "noticePath": "Licenses/fixture.txt",
                "archiveSha256": importer.digest((self.cache / "fixture.zip").read_bytes()), "configSha256": importer.digest(config_payload),
                "soundSha256": {name: importer.digest(payload) for name, payload in self.source_wavs.items()}}]}
        self.lock_path = self.assets / "thock-mouse-sources.json"

    def build(self):
        self.lock_path.write_bytes(json_bytes(self.lock))
        return importer.build(self.lock_path, self.assets, self.cache, FFMPEG, offline=True)

    def write_outputs(self, files):
        for relative, payload in files.items():
            path = self.assets / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(payload)

    @unittest.skipUnless(Path(FFMPEG).is_file(), "FFmpeg is required for stereo fixture import")
    def test_reproducible_buttons_phases_stereo_downmix_and_preservation(self):
        before = self.original.read_bytes(); files, report = self.build()
        self.assertEqual(files, self.build()[0]); self.assertEqual(self.original.read_bytes(), before)
        self.assertNotIn("original.wav", files)
        profile = json.loads(files["mouse-profiles.json"])[0]
        self.assertEqual(set(profile["keySamples"]), {"9:1", "9:2"})
        self.assertEqual(profile["samples"], profile["keySamples"]["9:1"]["samples"])
        self.assertEqual(profile["releaseSamples"], profile["keySamples"]["9:1"]["releaseSamples"])
        self.assertEqual(report["profiles"][0]["fallback"]["9:3"], "left")
        down, up = report["profiles"][0]["selections"][:2]
        self.assertEqual(down["sourceMetrics"]["channels"], 2)
        self.assertEqual(down["processing"]["removedDigitalLeadingFrames44100Hz"], 197)
        self.assertAlmostEqual(down["outputMetrics"]["peak"] / up["outputMetrics"]["peak"], 4, delta=.005)
        self.write_outputs(files)
        verified = check_mouse_assets(self.assets)
        self.assertEqual((verified["sampleCount"], verified["pressSampleCount"], verified["releaseSampleCount"]), (4, 2, 2))
        profile["keySamples"].pop("9:2")
        (self.assets / "mouse-profiles.json").write_bytes(json_bytes([profile]))
        with self.assertRaisesRegex(AssertionError, "left and right"):
            check_mouse_assets(self.assets)

    def test_refuses_modified_preserved_audio_archive_or_unapproved_license(self):
        before = self.original.read_bytes(); self.original.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Existing keyboard asset differs"): self.build()
        self.original.write_bytes(before)
        archive = self.cache / "fixture.zip"; archive.write_bytes(archive.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "Source size/hash mismatch"): self.build()
        self.config["license"]["type"] = "Proprietary"
        with self.assertRaisesRegex(ValueError, "approved paired CC0"): importer.validate_config(self.config, self.lock["profiles"][0])

    def test_refuses_missing_release_and_wrong_source_format(self):
        self.config["sounds"]["left"]["up"] = []
        with self.assertRaisesRegex(ValueError, "Missing/duplicate"): importer.validate_config(self.config, self.lock["profiles"][0])
        with self.assertRaisesRegex(ValueError, "Expected publisher stereo"):
            importer.render_stereo(stereo_wav(1000, channels=1), FFMPEG, self.lock["processing"])


if __name__ == "__main__":
    unittest.main()
