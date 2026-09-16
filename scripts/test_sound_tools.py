#!/usr/bin/env python3
"""Regression checks use temporary fixture audio; they never create shipped releases."""

import array
import copy
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import audition_sounds as audition
import check_sound_assets as checker
import extract_sounds as extract


class ReleaseReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "fixture.webm"
        self.source.write_bytes(b"test audio source")
        self.video = self.root / "fixture.mp4"
        self.video.write_bytes(b"test video source")
        self.review = {
            "schemaVersion": 1,
            "source": {"file": self.source.name, "sha256": hashlib.sha256(self.source.read_bytes()).hexdigest(),
                       "videoFile": self.video.name, "videoSha256": hashlib.sha256(self.video.read_bytes()).hexdigest()},
            "profiles": [{"id": "thocky", "status": "verified", "evidence": "Test fixture identity only.",
                          "releases": [{"startSeconds": .300, "endSeconds": .325, "attackSeconds": .301,
                                        "videoSeconds": .301, "evidence": "Test fixture video corroboration only."}]}],
        }
        self.review_path = self.root / "release-review.json"
        profiles = [("thocky", "Thocky", "Test fixture", "C68B54", 0, .5,
                     [(i * .03, i * .03 + .025) for i in range(1, 7)])]
        self.addCleanup(patch.stopall)
        patch.object(extract, "PROFILES", profiles).start()
        patch.object(extract, "ATTACK_FRAMES", {"thocky": [24] * 6}).start()
        # A tiny deterministic fixture, never a candidate for an actual release.
        samples = array.array("f", ((i % 48 - 24) / 500 for i in range(24_000)))
        patch.object(extract, "decode", return_value=samples).start()

    def build(self, review=True):
        self.review_path.write_text(json.dumps(self.review))
        return extract.build(self.source, "unused-test-ffmpeg", self.review_path if review else None)

    def test_unavailable_review_preserves_all_existing_audio_and_manifest_bytes(self):
        baseline = self.build(review=False)
        self.review["profiles"][0].update(status="unavailable", releases=[])
        reviewed = self.build()
        for path in baseline:
            if path != "extraction.json":
                self.assertEqual(baseline[path], reviewed[path], path)
        self.assertEqual(json.loads(reviewed["profiles.json"])[0]["releaseSamples"], None)

    def test_verified_review_is_reproducible_and_records_identity_and_processing(self):
        baseline = self.build(review=False)
        rendered = self.build()
        self.assertEqual(rendered, self.build())
        manifest = json.loads(rendered["profiles.json"])[0]
        self.assertEqual(manifest["releaseSamples"], ["Sounds/thocky/release-01.wav"])
        for path in manifest["samples"]:
            self.assertEqual(rendered[path], baseline[path])
        selection = json.loads(rendered["extraction.json"])["profiles"][0]["releaseSelections"][0]
        self.assertEqual(selection["attackAlignment"]["outputAttackFrame"], 24)
        self.assertEqual(selection["identification"]["status"], "verified")
        self.assertEqual(selection["sha256"], hashlib.sha256(rendered[selection["path"]]).hexdigest())

    def test_only_explicitly_reviewed_press_trim_changes_press_audio(self):
        baseline = self.build()
        self.review["profiles"][0]["pressTrims"] = [
            {"variant": 1, "endSeconds": .050, "videoSeconds": .051, "evidence": "Test fixture trim only."}]
        trimmed = self.build()
        self.assertNotEqual(trimmed["Sounds/thocky/01.wav"], baseline["Sounds/thocky/01.wav"])
        for variant in range(2, 7):
            path = f"Sounds/thocky/{variant:02d}.wav"
            self.assertEqual(trimmed[path], baseline[path])

    def test_rejects_unverified_cuts_missing_evidence_and_wrong_sources(self):
        original = copy.deepcopy(self.review)
        cases = [
            lambda review: review["profiles"][0].update(status="unverified"),
            lambda review: review["profiles"][0]["releases"][0].update(evidence=""),
            lambda review: review["profiles"][0]["releases"][0].pop("videoSeconds"),
            lambda review: review["profiles"][0]["releases"][0].update(startSeconds=.7),
            lambda review: review["profiles"][0]["releases"][0].update(attackSeconds=float("nan")),
            lambda review: review["source"].update(sha256="wrong"),
            lambda review: review["source"].update(videoSha256="wrong"),
        ]
        for mutate in cases:
            with self.subTest(mutate=mutate):
                self.review = copy.deepcopy(original)
                mutate(self.review)
                with self.assertRaises(ValueError):
                    self.build()


class AuditionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "press.wav").write_bytes(extract.wav_bytes([.1] * 960))
        (self.root / "release.wav").write_bytes(extract.wav_bytes([.05] * 960))
        self.group = {"id": "fixture", "samples": ["press.wav"], "releaseSamples": ["release.wav"]}

    def test_release_overlaps_press_at_requested_hold(self):
        payload, timeline = audition.build_audition(self.root, [self.group], holds=(.005,))
        samples = array.array("h", payload)
        self.assertEqual(timeline[1]["startSeconds"], .305)
        self.assertLess(timeline[1]["startSeconds"], timeline[0]["endSeconds"])
        onset = round(.3 * audition.RATE)
        self.assertEqual(samples[onset], 3277)
        self.assertEqual(samples[onset + 300], round(3277 + 1638 * .7))
        self.assertEqual(samples[onset + 1000], round(1638 * .7))
        self.assertEqual(timeline[0]["phaseGain"], 1)
        self.assertEqual(timeline[1]["phaseGain"], .7)

    def test_original_balance_option_leaves_press_identical_and_restores_release(self):
        softened, _ = audition.build_audition(self.root, [self.group], holds=(.1,))
        original, _ = audition.build_audition(self.root, [self.group], holds=(.1,), release_gain=1)
        softened, original = array.array("h", softened), array.array("h", original)
        press = round(.3 * audition.RATE)
        release = round(.4 * audition.RATE)
        self.assertEqual(softened[press:press + 960], original[press:press + 960])
        self.assertEqual(original[release], 1638)
        self.assertEqual(softened[release], round(original[release] * .7))

    def test_unavailable_release_stays_press_only_and_release_audition_reports_absence(self):
        self.group["releaseSamples"] = None
        _, timeline = audition.build_audition(self.root, [self.group])
        self.assertEqual([event["phase"] for event in timeline], ["press"])
        with self.assertRaisesRegex(ValueError, "No release samples"):
            audition.build_audition(self.root, [self.group], phase="release")

    def test_isolated_phases_multiple_holds_and_simultaneous_voices(self):
        for phase in ("press", "release"):
            _, timeline = audition.build_audition(self.root, [self.group], phase=phase)
            self.assertEqual([event["phase"] for event in timeline], [phase])
        _, timeline = audition.build_audition(self.root, [self.group], holds=(.005, .3), voices=2)
        self.assertEqual(len(timeline), 8)
        self.assertEqual(timeline[0]["startSeconds"], timeline[2]["startSeconds"])
        self.assertAlmostEqual(timeline[5]["startSeconds"] - timeline[4]["startSeconds"], .3)

    def test_fast_typing_interval_and_clipping_rejection(self):
        self.group["samples"] *= 2
        _, timeline = audition.build_audition(self.root, [self.group], interval=.01)
        self.assertAlmostEqual(timeline[2]["startSeconds"] - timeline[0]["startSeconds"], .01)
        with self.assertRaisesRegex(ValueError, "would clip"):
            audition.build_audition(self.root, [self.group], holds=(0,), voices=8)


class AssetCheckerTests(unittest.TestCase):
    def test_variable_release_count_and_provenance_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            assets = Path(temporary) / "Assets"
            shutil.copytree(extract.PROJECT / "Assets", assets)
            manifest = json.loads((assets / "profiles.json").read_text())
            extraction = json.loads((assets / "extraction.json").read_text())
            baseline = checker.check_assets(assets)
            legacy_ids = {record["id"] for record in extraction["profiles"]}
            for profile in manifest:
                if profile["id"] in legacy_ids:
                    profile["releaseSamples"] = None
            for record in extraction["profiles"]:
                record["releaseSelections"] = []
            profile = manifest[0]
            record = next(record for record in extraction["profiles"] if record["id"] == profile["id"])
            # Copy existing audio only inside this fixture to test manifest plumbing.
            # This does not claim these recordings contain authenticated releases.
            for count in (1, 2):
                path = f"Sounds/{profile['id']}/release-{count:02d}.wav"
                content = (assets / profile["samples"][count - 1]).read_bytes()
                (assets / path).write_bytes(content)
                profile["releaseSamples"] = (profile.get("releaseSamples") or []) + [path]
                record.setdefault("releaseSelections", []).append({"path": path,
                    "identification": {"status": "verified", "evidence": "Fixture only", "videoSeconds": 0},
                    "sha256": hashlib.sha256(content).hexdigest()})
                (assets / "profiles.json").write_text(json.dumps(manifest))
                (assets / "extraction.json").write_text(json.dumps(extraction))
                report = checker.check_assets(assets)
                self.assertEqual(report["releaseSampleCount"], baseline["releaseSampleCount"] + count)
                self.assertEqual(report["pressSampleCount"], baseline["pressSampleCount"])
                self.assertEqual(report["failures"], [])
            record["releaseSelections"][0]["sha256"] = "wrong"
            (assets / "extraction.json").write_text(json.dumps(extraction))
            with self.assertRaisesRegex(AssertionError, "hash mismatch"):
                checker.check_assets(assets)

    def test_catalog_phase_identity_and_imported_hash_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            assets = Path(temporary) / "Assets"
            shutil.copytree(extract.PROJECT / "Assets", assets)
            provenance_path = assets / "thock-import.json"
            provenance = json.loads(provenance_path.read_text())
            release = next(s for s in provenance["profiles"][0]["selections"] if s["phase"] == "release")
            original = copy.deepcopy(release)
            release["sourceFile"] = provenance["profiles"][0]["sourceSounds"][release["category"]]["down"][0]
            provenance_path.write_text(json.dumps(provenance))
            with self.assertRaisesRegex(AssertionError, "Wrong source phase"):
                checker.check_assets(assets)
            release.update(original)
            release["sha256"] = "wrong"
            provenance_path.write_text(json.dumps(provenance))
            with self.assertRaisesRegex(AssertionError, "Imported sound hash mismatch"):
                checker.check_assets(assets)

    def test_catalog_includes_special_keys_without_counting_enter_alias_twice(self):
        report = checker.check_assets(extract.PROJECT / "Assets")
        self.assertEqual(report["profileCount"], 20)
        self.assertEqual(report["catalogSampleCount"], 121)
        self.assertEqual(report["pressSampleCount"], 140)
        self.assertEqual(report["releaseSampleCount"], 41)
        self.assertEqual(len(report["releaseSupportedProfiles"]), 10)
        self.assertEqual(report["failures"], [])
        for profile in report["releaseSupportedProfiles"]:
            special = [s for s in report["samples"] if s["profile"] == profile and s["category"] != "default"]
            self.assertEqual(len(special), 6)
            self.assertEqual({s["category"] for s in special}, {"space", "enter", "backspace"})

    def test_catalog_requires_keypad_enter_even_when_return_covers_same_wavs(self):
        with tempfile.TemporaryDirectory() as temporary:
            assets = Path(temporary) / "Assets"
            shutil.copytree(extract.PROJECT / "Assets", assets)
            path = assets / "profiles.json"
            manifest = json.loads(path.read_text())
            profile = next(p for p in manifest if p.get("keySamples"))
            del profile["keySamples"]["7:88"]
            path.write_text(json.dumps(manifest))
            with self.assertRaises(AssertionError):
                checker.check_assets(assets)


if __name__ == "__main__":
    unittest.main()
