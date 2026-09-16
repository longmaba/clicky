#!/usr/bin/env python3
"""Temporary fixture tests for pinned imports and additive catalog rebuilding."""

import array
import copy
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
import wave
import zipfile

import extract_sounds as original
import import_thock_sounds as importer

FFMPEG = os.environ.get("CLICKY_TEST_FFMPEG") or shutil.which("ffmpeg") or ""


def fixture_wav(level):
    samples = array.array("h", [0] * 220 + [level, -level] * 200 + [0] * 50)
    output = io.BytesIO()
    with wave.open(output, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(44100)
        writer.writeframes(samples.tobytes())
    return output.getvalue()


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.assets = self.root / "Assets"
        self.assets.mkdir()
        self.originals = [{"id": "thocky", "samples": ["Sounds/Extras/test.wav"], "releaseSamples": None}]
        (self.assets / "profiles.json").write_bytes(original.json_bytes(self.originals))
        (self.assets / "Sounds/Extras").mkdir(parents=True)
        self.old_audio = fixture_wav(100)
        (self.assets / "Sounds/Extras/test.wav").write_bytes(self.old_audio)
        self.metadata = {"name": "Fixture", "brand": "Test", "author": "tplai", "supportsKeyUp": True, "category": "keyboard"}
        self.config = {"id": "fixture", "metadata": self.metadata, "license": {"type": "MIT"}, "sounds": {
            category: {"down": ["down.wav"], "up": ["up.wav"]}
            for category in ("default", "space", "enter", "backspace")}}
        self.config["sounds"]["default"]["up"].append("up2.wav")
        config_bytes = original.json_bytes(self.config)
        wavs = {"down.wav": fixture_wav(8000), "up.wav": fixture_wav(2000), "up2.wav": fixture_wav(1000)}
        with zipfile.ZipFile(self.cache / "fixture.zip", "w") as archive:
            archive.writestr("config.json", config_bytes)
            for name, payload in wavs.items():
                archive.writestr(name, payload)
        registry = {"soundpacks": {"keyboard": [{"id": "fixture", "metadata": self.metadata, "content": {"path": "keyboard/test"}}]}}
        registry_bytes = original.json_bytes(registry)
        (self.cache / "manifest.json").write_bytes(registry_bytes)
        processing = json.loads((importer.PROJECT / "Assets/thock-sources.json").read_text())["processing"]
        self.lock = {"schemaVersion": 1, "registry": {"repository": "fixture/test", "commit": "0" * 40,
            "manifestSha256": importer.digest(registry_bytes)}, "preserveProfileIDs": ["thocky"],
            "preservedProfilesSha256": importer.digest(original.json_bytes(self.originals)),
            "preservedFiles": {"Sounds/Extras/test.wav": importer.digest(self.old_audio)}, "processing": processing,
            "profiles": [{"id": "new-fixture", "packID": "fixture", "metadata": self.metadata,
                "name": "Test Fixture", "subtitle": "Fixture only", "color": "000000", "contentPath": "keyboard/test",
                "archiveSha256": importer.digest((self.cache / "fixture.zip").read_bytes()),
                "configSha256": importer.digest(config_bytes), "soundSha256": {name: importer.digest(payload) for name, payload in wavs.items()}}]}
        self.lock_path = self.root / "thock-sources.json"

    def build(self):
        self.lock_path.write_bytes(original.json_bytes(self.lock))
        return importer.build(self.lock_path, self.assets, self.cache, FFMPEG, offline=True)

    @unittest.skipUnless(Path(FFMPEG).is_file(), "FFmpeg is needed for fixture resampling")
    def test_additive_reproducible_import_retains_phase_and_key_mappings(self):
        files, report = self.build()
        self.assertEqual(files, self.build()[0])
        profiles = json.loads(files["profiles.json"])
        self.assertEqual(profiles[0], self.originals[0])
        self.assertEqual(files["Sounds/Extras/test.wav"], self.old_audio)
        paired = profiles[1]
        self.assertEqual(len(paired["samples"]), 1)
        self.assertEqual(len(paired["releaseSamples"]), 2)
        self.assertEqual(paired["keySamples"]["7:40"], paired["keySamples"]["7:88"])
        self.assertFalse(paired["normalizationReference"])
        self.assertEqual(set(paired["keySamples"]), {"7:40", "7:88", "7:44", "7:42"})
        self.assertEqual(len(report["profiles"][0]["selections"]), 9)
        for selection in report["profiles"][0]["selections"]:
            self.assertEqual(selection["identification"]["method"], "source-config")
            self.assertEqual(selection["sha256"], importer.digest(files[selection["path"]]))
        down, up = report["profiles"][0]["selections"][:2]
        # Identical-shaped source phases keep their 4:1 amplitude relationship.
        self.assertAlmostEqual(down["outputMetrics"]["peak"] / up["outputMetrics"]["peak"], 4, delta=.005)
        self.assertEqual(down["processing"]["removedDigitalLeadingFrames44100Hz"], 197)
        for payload in (files[path] for path in paired["samples"] + paired["releaseSamples"]):
            with wave.open(io.BytesIO(payload), "rb") as reader:
                self.assertEqual((reader.getnchannels(), reader.getsampwidth(), reader.getframerate()), (1, 2, 48000))
                pcm = array.array("h", reader.readframes(reader.getnframes()))
                self.assertEqual((pcm[0], pcm[-1]), (0, 0))
        independent = {"id": "another-library", "samples": ["other.wav"], "releaseSamples": None}
        (self.assets / "profiles.json").write_bytes(original.json_bytes(self.originals + [independent]))
        self.assertEqual(json.loads(self.build()[0]["profiles.json"])[-1], independent)

    def test_modified_archives_and_original_files_are_rejected(self):
        archive = self.cache / "fixture.zip"
        content = archive.read_bytes()
        archive.write_bytes(content + b"changed")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.build()
        archive.write_bytes(content)
        (self.assets / "Sounds/Extras/test.wav").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Original sound differs"):
            self.build()

    def test_missing_offline_sources_and_incomplete_phase_configs_are_rejected(self):
        (self.cache / "fixture.zip").unlink()
        with self.assertRaisesRegex(ValueError, "Missing cached source"):
            self.build()
        broken = copy.deepcopy(self.config)
        broken["sounds"]["default"]["up"] = []
        with self.assertRaisesRegex(ValueError, "Missing or duplicate"):
            importer.validate_config(broken, self.lock["profiles"][0])

    def test_safe_zip_read_never_extracts_paths_or_accepts_duplicates(self):
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr("../escape.wav", b"x")
            archive.writestr("safe.wav", b"x")
        with zipfile.ZipFile(io.BytesIO(payload.getvalue())) as archive:
            with self.assertRaisesRegex(ValueError, "Unsafe source path"):
                importer.read_member(archive, "../escape.wav")
            self.assertEqual(importer.read_member(archive, "safe.wav"), b"x")
        self.assertFalse((self.root / "escape.wav").exists())

    def test_original_extractor_retains_additional_profiles(self):
        extra = {"id": "new-fixture", "samples": ["new.wav"], "releaseSamples": ["up.wav"]}
        (self.assets / "profiles.json").write_bytes(original.json_bytes(self.originals + [extra]))
        files = {"profiles.json": original.json_bytes(self.originals)}
        self.assertEqual(original.preserve_additional_profiles(files, self.assets), 1)
        self.assertEqual(json.loads(files["profiles.json"]), self.originals + [extra])


if __name__ == "__main__":
    unittest.main()
