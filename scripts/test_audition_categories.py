#!/usr/bin/env python3
"""Category selection and phase-timing checks with temporary audition fixtures."""

from pathlib import Path
import tempfile
import unittest

import audition_sounds as audition
from extract_sounds import wav_bytes


class CategoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.assets = Path(self.temporary.name)
        self.banks = {}
        for category in ("default", "space", "enter", "backspace"):
            self.banks[category] = {"samples": [f"{category}-down.wav"], "releaseSamples": [f"{category}-up.wav"]}
            for phase in ("down", "up"):
                (self.assets / f"{category}-{phase}.wav").write_bytes(wav_bytes([.02] * 2400))
        self.profile = {"id": "fixture", **self.banks["default"], "keySamples": {
            "7:44": self.banks["space"], "7:40": self.banks["enter"],
            "7:88": self.banks["enter"], "7:42": self.banks["backspace"]}}

    def test_specific_category_chooses_its_own_press_and_release(self):
        for category, bank in self.banks.items():
            with self.subTest(category=category):
                selected = audition.select_categories([self.profile], category)
                self.assertEqual(len(selected), 1)
                self.assertEqual(selected[0]["samples"], bank["samples"])
                self.assertEqual(selected[0]["releaseSamples"], bank["releaseSamples"])

    def test_all_includes_four_categories_without_duplicate_enter_aliases(self):
        groups = audition.select_categories([self.profile], "all")
        self.assertEqual([group["category"] for group in groups], ["default", "space", "enter", "backspace"])
        _, timeline = audition.build_audition(self.assets, [self.profile], category="all")
        self.assertEqual(len(timeline), 8)
        self.assertEqual(sum(event["path"] == "enter-down.wav" for event in timeline), 1)
        self.assertEqual(sum(event["path"] == "enter-up.wav" for event in timeline), 1)

    def test_keypad_enter_only_bank_is_available_once(self):
        del self.profile["keySamples"]["7:40"]
        groups = audition.select_categories([self.profile], "enter")
        self.assertEqual(groups[0]["samples"], self.banks["enter"]["samples"])

    def test_missing_special_bank_falls_back_and_all_avoids_repeated_generic_bank(self):
        del self.profile["keySamples"]
        group = audition.select_categories([self.profile], "space")[0]
        self.assertEqual(group["category"], "space")
        self.assertEqual(group["sourceCategory"], "default")
        self.assertEqual(group["samples"], self.banks["default"]["samples"])
        self.assertEqual(len(audition.select_categories([self.profile], "all")), 1)

    def test_isolated_categories_and_pair_holds_keep_category_timing(self):
        for phase in ("press", "release"):
            _, timeline = audition.build_audition(self.assets, [self.profile], phase=phase, category="all")
            self.assertEqual(len(timeline), 4)
            self.assertTrue(all(event["phase"] == phase for event in timeline))
        _, timeline = audition.build_audition(self.assets, [self.profile], category="all", holds=(.03, .1, .3))
        self.assertEqual(len(timeline), 24)
        for press, release in zip(timeline[::2], timeline[1::2]):
            self.assertEqual(press["category"], release["category"])
            self.assertAlmostEqual(release["startSeconds"] - press["startSeconds"], press["holdSeconds"], places=5)

    def test_mouse_all_avoids_generic_left_duplicate_and_middle_uses_generic(self):
        mouse = {"id": "mouse-fixture", **self.banks["default"], "keySamples": {
            "9:1": self.banks["default"], "9:2": self.banks["space"]}}
        groups = audition.select_categories([mouse], "all")
        self.assertEqual([group["category"] for group in groups], ["left", "right"])
        _, timeline = audition.build_audition(self.assets, [mouse], category="all")
        self.assertEqual(len(timeline), 4)
        middle = audition.select_categories([mouse], "middle")[0]
        self.assertEqual(middle["samples"], self.banks["default"]["samples"])
        self.assertEqual(middle["releaseSamples"], self.banks["default"]["releaseSamples"])
        self.assertEqual(middle["sourceCategory"], "default")


if __name__ == "__main__":
    unittest.main()
