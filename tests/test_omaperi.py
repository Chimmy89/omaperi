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
  LEDs: 'Key: A' 'Key: B' 'Key: C'
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


class TestOpenRGBLeds(unittest.TestCase):
    def setUp(self):
        self.devices = omaperi.parse_openrgb(OPENRGB_SAMPLE)

    def test_led_count_is_parsed(self):
        self.assertEqual(self.devices[1]["leds"], 3)

    def test_controller_without_leds_counts_zero(self):
        # Zones but no LEDs: an ARGB header whose strip length was never set.
        self.assertEqual(self.devices[0]["leds"], 0)

    def test_no_colour_control_when_nothing_can_light(self):
        # Colouring it lights nothing, but the mode change still takes the
        # header away from whatever is driving it -- the fans just go dark.
        device = omaperi.orgb_device(self.devices[0])
        self.assertNotIn("color", [c["key"] for c in device["controls"]])
        self.assertIn("no configured LEDs", device["note"])

    def test_colour_offered_when_leds_exist(self):
        device = omaperi.orgb_device(self.devices[1])
        self.assertIn("color", [c["key"] for c in device["controls"]])
        self.assertIsNone(device["note"])


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


class TestOpenRGBKinds(unittest.TestCase):
    def test_mapped_type_becomes_its_kind(self):
        device = omaperi.orgb_device({
            "index": 3, "name": "Some Fan", "type": "Cooler",
            "modes": ["Direct"], "active_mode": "Direct"})
        self.assertEqual(device["kind"], "cooler")
        # Nothing to fall back to: the kind already names it.
        self.assertIsNone(device["type_label"])

    def test_unmapped_type_keeps_the_name_openrgb_gave_it(self):
        device = omaperi.orgb_device({
            "index": 4, "name": "Odd Device", "type": "Thermometer",
            "modes": [], "active_mode": None})
        self.assertEqual(device["kind"], "other")
        self.assertEqual(device["type_label"], "Thermometer")

    def test_single_mode_is_a_readout_not_a_dropdown(self):
        device = omaperi.orgb_device({
            "index": 1, "name": "Kbd", "type": "Keyboard",
            "modes": ["Direct"], "active_mode": "Direct"})
        mode = [c for c in device["controls"] if c["key"] == "mode"][0]
        self.assertEqual(mode["type"], "readout")

    def test_several_modes_stay_a_dropdown(self):
        device = omaperi.orgb_device({
            "index": 1, "name": "Kbd", "type": "Keyboard",
            "modes": ["Off", "Static", "Direct"], "active_mode": "Static"})
        mode = [c for c in device["controls"] if c["key"] == "mode"][0]
        self.assertEqual(mode["type"], "enum")
        self.assertEqual(mode["value"], "Static")


class FakeRazer(object):
    """Minimal stand-in for an openrazer device."""

    def __init__(self, level, caps=("battery", "dpi")):
        self.name = "Fake Razer"
        self.type = "mouse"
        self.serial = "FAKE123"
        self.dpi = (800, 800)
        self.max_dpi = 30000
        self.supported_poll_rates = [125, 1000]
        self.poll_rate = 1000
        self.battery_level = level
        self.is_charging = False
        self._caps = caps

    def has(self, cap):
        return cap in self._caps

    def get_idle_time(self):
        raise RuntimeError("not supported")


class TestRazerSleepingBattery(unittest.TestCase):
    def test_zero_means_asleep_not_flat(self):
        # The dongle reports 0 while the mouse sleeps. Showing that as 0%
        # fires a false low-battery warning in the bar.
        device = omaperi.razer_device(FakeRazer(0))
        self.assertIsNone(device["battery"])
        self.assertIn("Asleep or powered off", device["note"])

    def test_real_level_is_reported(self):
        device = omaperi.razer_device(FakeRazer(87))
        self.assertEqual(device["battery"], {"level": 87, "charging": False})
        self.assertNotIn("Asleep", device["note"] or "")


class TestHeadsetEqualizer(unittest.TestCase):
    DEVICE = {
        "device": "Test", "id_vendor": "0x1", "id_product": "0x2",
        "capabilities": ["CAP_EQUALIZER", "CAP_EQUALIZER_PRESET"],
        "equalizer_presets": {"flat": [0.0] * 5, "bass boost": [4.0, 2.0, 0.0, 0.0, 0.0]},
        "battery": {"status": "BATTERY_UNAVAILABLE", "level": -1},
    }

    def test_band_count_comes_from_the_presets(self):
        # The presets are the same length as the device's EQ, and it is the
        # only place the CLI reveals the band count.
        self.assertEqual(omaperi.hs_band_count(self.DEVICE), 5)

    def test_no_presets_means_no_band_count(self):
        self.assertEqual(omaperi.hs_band_count({"equalizer_presets": {}}), 0)

    def test_one_band_control_per_band(self):
        device = omaperi.hs_device(self.DEVICE)
        bands = [c for c in device["controls"] if c["key"].startswith("eq_band_")]
        self.assertEqual(len(bands), 5)
        self.assertEqual(bands[0]["unit"], "dB")
        self.assertEqual((bands[0]["min"], bands[0]["max"]),
                         (omaperi.EQ_GAIN_MIN, omaperi.EQ_GAIN_MAX))

    def test_a_short_remembered_curve_is_padded(self):
        # A device that gains bands between runs must not raise.
        omaperi.remember("headset:test", "eq_curve", [3, 1])
        self.assertEqual(omaperi.hs_curve("headset:test", 5), [3, 1, 0, 0, 0])


class TestRazerAsleepGuard(unittest.TestCase):
    def test_sleeping_device_is_detected(self):
        # Writes to it are accepted and dropped, so an apply must not claim
        # success -- this is what left a test DPI on the mouse for a day.
        self.assertTrue(omaperi.razer_asleep(FakeRazer(0)))

    def test_awake_device_is_not_blocked(self):
        self.assertFalse(omaperi.razer_asleep(FakeRazer(100)))

    def test_device_without_a_battery_is_never_treated_as_asleep(self):
        self.assertFalse(omaperi.razer_asleep(FakeRazer(0, caps=("dpi",))))


class TestEffects(unittest.TestCase):
    def test_hsv_matches_known_hues(self):
        self.assertEqual(omaperi.hsv_rgb(0, 1, 1), (255, 0, 0))
        self.assertEqual(omaperi.hsv_rgb(120, 1, 1), (0, 255, 0))
        self.assertEqual(omaperi.hsv_rgb(240, 1, 1), (0, 0, 255))
        self.assertEqual(omaperi.hsv_rgb(0, 0, 1), (255, 255, 255))

    def test_rainbow_varies_along_the_strip(self):
        job = {"effect": "rainbow", "base": (0, 255, 136), "speed": 50}
        frame = omaperi.effect_frame(job, 8, 0.0)
        self.assertEqual(len(frame), 8)
        self.assertGreater(len(set(frame)), 4)   # a gradient, not one colour

    def test_rainbow_period_is_fixed_not_stretched(self):
        # Zones are sized to the channel maximum, usually far longer than the
        # strip actually attached, so a rainbow stretched over the zone would
        # show only a sliver of the spectrum on real hardware.
        job = {"effect": "rainbow", "base": (255, 0, 0), "speed": 50}
        short = omaperi.effect_frame(job, omaperi.RAINBOW_PERIOD, 0.0)
        long = omaperi.effect_frame(job, omaperi.RAINBOW_PERIOD * 4, 0.0)
        self.assertEqual(short, long[:omaperi.RAINBOW_PERIOD])

    def test_breathing_is_one_colour_that_moves_over_time(self):
        job = {"effect": "breathing", "base": (255, 0, 0), "speed": 50}
        a = omaperi.effect_frame(job, 4, 0.0)
        b = omaperi.effect_frame(job, 4, 0.25)
        self.assertEqual(len(set(a)), 1)
        self.assertNotEqual(a, b)

    def test_breathing_never_goes_fully_dark(self):
        # A strip that blinks out reads as broken hardware.
        job = {"effect": "breathing", "base": (255, 0, 0), "speed": 50}
        darkest = min(omaperi.effect_frame(job, 1, p / 40.0)[0] for p in range(40))
        self.assertGreater(darkest, 0)

    def test_static_returns_the_base_colour(self):
        job = {"effect": "static", "base": (18, 52, 86), "speed": 50}
        self.assertEqual(omaperi.effect_frame(job, 2, 0.7),
                         [omaperi.rgb(18, 52, 86)] * 2)


class TestControlValidation(unittest.TestCase):
    DEVICE = {
        "id": "v4l2:video0",
        "controls": [
            {"key": "brightness", "type": "range"},
            {"key": "mode", "type": "readout"},
        ],
    }

    def test_known_control_is_returned(self):
        self.assertEqual(omaperi.find_control(self.DEVICE, "brightness")["type"], "range")

    def test_unknown_control_is_refused(self):
        with self.assertRaises(SystemExit):
            omaperi.find_control(self.DEVICE, "nope")

    def test_a_crafted_key_cannot_smuggle_extra_controls(self):
        # v4l2-ctl -c takes a comma-separated list, so this must not reach it.
        with self.assertRaises(SystemExit):
            omaperi.find_control(self.DEVICE, "brightness=1,contrast=90")


class TestBackendListing(unittest.TestCase):
    def test_dummy_is_not_listed_as_inactive(self):
        # It is off on purpose; reporting it would read as a broken dependency.
        names = [b["name"] for b in omaperi.build_document()["backends"]]
        self.assertNotIn("dummy", names)


if __name__ == "__main__":
    unittest.main(verbosity=2)
