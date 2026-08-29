#!/usr/bin/env python3
"""Parser tests for omaperi. No hardware, no network, stdlib only:

    python3 tests/test_omaperi.py

These cover the two hand-written parsers. Everything else in the CLI is a
thin call into a vendor tool that already returns structured data.
"""

import importlib.util
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_loader(
    "omaperi",
    importlib.machinery.SourceFileLoader("omaperi", os.path.join(ROOT, "bin", "omaperi")),
)
omaperi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(omaperi)


OPENRGB_SAMPLE = """Connection attempt failed
0: MSI MYSTIC LIGHT
  Type:           Motherboard
  Description:    MSI Mystic Light Device (761-byte)
  Modes: [Direct]
  Zones: JAF 'JARGB 1'

1: SteelSeries Apex Pro TKL
  Type:           Keyboard
  Description:    SteelSeries Apex RGB Device
  Modes: Off Static [Direct] Breathing
  Zones: Keyboard
"""

V4L2_SAMPLE = """
User Controls

                     brightness 0x00980900 (int)    : min=0 max=255 step=1 default=136 value=136 flags=has-min-max
        white_balance_automatic 0x0098090c (bool)   : default=1 value=1
           power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=1 value=2 (60 Hz)
\t\t\t\t0: Disabled
\t\t\t\t1: 50 Hz
\t\t\t\t2: 60 Hz
      white_balance_temperature 0x0098091a (int)    : min=2800 max=6500 step=1 default=4600 value=4600 flags=inactive, has-min-max
                    focus_state 0x009a090f (int)    : min=0 max=3 value=1 flags=read-only

Camera Controls

                  auto_exposure 0x009a0901 (menu)   : min=0 max=3 default=3 value=3 (Aperture Priority Mode)
\t\t\t\t1: Manual Mode
\t\t\t\t3: Aperture Priority Mode
"""


class TestOpenRGBParser(unittest.TestCase):
    def setUp(self):
        self.devices = omaperi.parse_openrgb(OPENRGB_SAMPLE)

    def test_ignores_connection_noise_and_finds_both_devices(self):
        self.assertEqual(len(self.devices), 2)
        self.assertEqual(self.devices[1]["name"], "SteelSeries Apex Pro TKL")
        self.assertEqual(self.devices[1]["type"], "Keyboard")

    def test_bracketed_mode_is_the_active_one_and_brackets_are_stripped(self):
        keyboard = self.devices[1]
        self.assertEqual(keyboard["modes"], ["Off", "Static", "Direct", "Breathing"])
        self.assertEqual(keyboard["active_mode"], "Direct")

    def test_single_mode_device_still_reports_it_active(self):
        self.assertEqual(self.devices[0]["modes"], ["Direct"])
        self.assertEqual(self.devices[0]["active_mode"], "Direct")


class TestV4L2Parser(unittest.TestCase):
    def setUp(self):
        self.controls = omaperi.parse_v4l2_controls(V4L2_SAMPLE)
        self.by_key = {c["key"]: c for c in self.controls}

    def test_int_becomes_range_with_bounds(self):
        brightness = self.by_key["brightness"]
        self.assertEqual(brightness["type"], "range")
        self.assertEqual(
            (brightness["min"], brightness["max"], brightness["step"], brightness["value"]),
            (0, 255, 1, 136),
        )

    def test_bool_becomes_toggle(self):
        self.assertEqual(self.by_key["white_balance_automatic"]["type"], "toggle")
        self.assertIs(self.by_key["white_balance_automatic"]["value"], True)

    def test_menu_becomes_enum_with_its_entries(self):
        plf = self.by_key["power_line_frequency"]
        self.assertEqual(plf["type"], "enum")
        self.assertEqual(
            plf["options"],
            [{"value": 0, "label": "Disabled"},
             {"value": 1, "label": "50 Hz"},
             {"value": 2, "label": "60 Hz"}],
        )
        self.assertEqual(plf["value"], 2)

    def test_menu_entries_attach_to_the_right_control(self):
        # auto_exposure's entries must not land on power_line_frequency.
        self.assertEqual(
            self.by_key["auto_exposure"]["options"],
            [{"value": 1, "label": "Manual Mode"},
             {"value": 3, "label": "Aperture Priority Mode"}],
        )

    def test_inactive_and_readonly_controls_are_dropped(self):
        # Writing either fails; the automatic mode that owns them must be
        # turned off first, and then they reappear on the next poll.
        self.assertNotIn("white_balance_temperature", self.by_key)
        self.assertNotIn("focus_state", self.by_key)


class TestHexToRgb(unittest.TestCase):
    def test_parses_with_and_without_hash(self):
        self.assertEqual(omaperi.hex_to_rgb("#ff0033"), (255, 0, 51))
        self.assertEqual(omaperi.hex_to_rgb("00ff88"), (0, 255, 136))

    def test_bad_input_is_black_rather_than_a_crash(self):
        self.assertEqual(omaperi.hex_to_rgb("nope"), (0, 0, 0))
        self.assertEqual(omaperi.hex_to_rgb(None), (0, 0, 0))


class TestDocumentShape(unittest.TestCase):
    def test_headset_capabilities_become_controls(self):
        device = omaperi.hs_device({
            "device": "Test Headset",
            "id_vendor": "0x046d",
            "id_product": "0x0af7",
            "capabilities": ["CAP_SIDETONE", "CAP_EQUALIZER_PRESET", "CAP_BATTERY_STATUS"],
            "equalizer_presets": {"flat": [], "bass boost": []},
            "battery": {"status": "BATTERY_AVAILABLE", "level": 72},
        })
        keys = [c["key"] for c in device["controls"]]
        self.assertIn("sidetone", keys)
        self.assertIn("eq_preset", keys)
        self.assertEqual(device["battery"], {"level": 72, "charging": False})
        self.assertIsNone(device["note"])

    def test_preset_values_are_indices_because_that_is_what__p_takes(self):
        device = omaperi.hs_device({
            "device": "Test", "id_vendor": "0x1", "id_product": "0x2",
            "capabilities": ["CAP_EQUALIZER_PRESET"],
            "equalizer_presets": {"flat": [], "bass boost": [], "team chat": []},
            "battery": {"status": "BATTERY_UNAVAILABLE", "level": -1},
        })
        preset = device["controls"][0]
        self.assertEqual(
            preset["options"],
            [{"value": 0, "label": "flat"},
             {"value": 1, "label": "bass boost"},
             {"value": 2, "label": "team chat"}],
        )

    def test_powered_off_headset_is_flagged_not_hidden(self):
        device = omaperi.hs_device({
            "device": "Test", "id_vendor": "0x1", "id_product": "0x2",
            "capabilities": ["CAP_SIDETONE"],
            "battery": {"status": "BATTERY_UNAVAILABLE", "level": -1},
        })
        self.assertIsNone(device["battery"])
        self.assertEqual(device["note"], "Powered off or out of range")


if __name__ == "__main__":
    unittest.main(verbosity=2)
