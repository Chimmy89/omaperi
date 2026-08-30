# omaperi

One Omarchy bar widget for every peripheral — headset, mouse, keyboard, webcam —
rendering whatever each device actually exposes.

Most peripheral plugins are built per vendor: one for Razer, one for OpenRGB, one
for headsets. omaperi is built per *capability*. Each adapter asks a tool that
already knows the device and translates the answer into one uniform document;
the panel renders that document. Nothing in the QML knows what a Razer is.

```
headsetcontrol -o json   →  ┐
openrazer (python)       →  ├─  omaperi status  →  one capability document  →  panel
openrgb --list-devices   →  │
v4l2-ctl --list-ctrls    →  ┘
```

## What you get

| Device class | Backend | Typical controls |
|---|---|---|
| Headsets | `headsetcontrol` | battery, sidetone, EQ presets **and a custom band curve**, auto-off, mic volume and noise filter, rotate-to-mute, lights, chatmix |
| Razer mice/keyboards | `openrazer` | battery, DPI, polling rate, sleep timer, lighting |
| Anything OpenRGB sees | `openrgb` | mode, colour |
| Webcams | `v4l2-ctl` | brightness, contrast, white balance, exposure, power-line frequency |

The panel is tabbed, one tab per device: a glyph, a short kind name ("Mouse",
not the product string), and the battery where there is one. A device that
cannot report right now still gets a tab, dimmed.

Only what a device really has appears. A headset without lights shows no light
switch; a mouse whose dongle exposes no lighting says so instead of offering a
control that does nothing.

## Screenshots

One slot in the bar, whatever `barMode` you pick:

![The omaperi widget in the Omarchy bar](docs/screenshots/bar.png)

One tab per device, each showing only the controls that device really has:

| Headset | Mouse | Keyboard |
|---|---|---|
| ![Headset tab](docs/screenshots/headset.png) | ![Mouse tab](docs/screenshots/mouse.png) | ![Keyboard tab](docs/screenshots/keyboard.png) |

The headset is powered off and says so instead of offering controls that would
do nothing; the mouse reports that OpenRazer exposes no lighting through its
dongle; the keyboard's single OpenRGB mode is shown as a value rather than a
dropdown pretending to be a choice.

A webcam, whose ten V4L2 controls are read straight off the device:

![Webcam tab](preview.png)

## Install

The widget needs the `omaperi` CLI on `PATH`:

```bash
install -Dm755 bin/omaperi ~/.local/bin/omaperi
omarchy plugin add https://github.com/Chimmy89/omaperi.git --enable
```

Then add it to the bar (Setup → Bar), or put `{"id": "io.github.chimmy89.omaperi"}`
in `~/.config/omarchy/shell.json`.

## Dependencies

omaperi itself needs only Python 3 (standard library) and Omarchy Quattro's
shell. Every backend is optional, detected at runtime, and hidden when absent —
install only what your hardware needs:

| Backend | Package | Covers | Licence |
|---|---|---|---|
| `headsetcontrol` | `headsetcontrol` | wireless headsets | GPL-3.0 |
| `openrazer` | `openrazer-meta` (AUR) | Razer devices | GPL-2.0 |
| `openrgb` | `openrgb` | anything OpenRGB sees — zones, readback, ARGB sizing | GPL-2.0 |
| `v4l2` | `v4l-utils` | webcams | GPL-2.0 |

```bash
sudo pacman -S headsetcontrol openrgb v4l-utils   # as applicable
yay -S openrazer-meta                             # Razer devices
```

None are bundled or downloaded by omaperi; it only calls them if they are
already on `PATH`. `omaperi backends` prints which are live and why the others
are not.

### OpenRGB: run the SDK server

omaperi talks to OpenRGB over its SDK socket. Without a server it falls back to
the `openrgb` CLI, which can only set one colour for a whole device — it cannot
report zones, read a colour back, or **size an addressable channel**. That last
one matters: an ARGB header cannot count what is plugged into it, so OpenRGB
starts it at zero LEDs, and a header at zero lights nothing no matter what
colour you send it.

```bash
install -Dm644 contrib/omaperi-openrgb.service ~/.config/systemd/user/omaperi-openrgb.service
systemctl --user enable --now omaperi-openrgb.service
```

With the server up, every addressable header simply gets a colour. You are not
asked how many LEDs are on it: an ARGB data line is one-way, so no software can
measure a strip, but surplus colour data is ignored by a shorter one — so
colouring a channel sizes it to its maximum and lights whatever is attached.

If you want the exact count anyway, turn on **Show advanced controls** in the
widget's settings. Sizes live in OpenRGB, so save a profile there to keep them
across restarts of the server.

### Lighting effects

Most controllers expose no firmware effects at all — OpenRGB reports a single
`Direct` mode for both the motherboard and keyboard here, with no speed range —
so omaperi animates them itself: **Static**, **Breathing**, **Spectrum** and
**Rainbow**, with a speed control.

The frame writer starts on its own when you pick an effect and exits once
everything is back to Static, so there is no service to enable and no process
left running when nothing is animating. Effects need the OpenRGB server, and
they stop if it does — unlike a firmware effect, which would keep running on
its own. Your hardware gives no choice there.

Rainbow repeats every 24 LEDs rather than being stretched across the zone,
because zones are sized to the channel maximum and stretching would show only
a sliver of the spectrum on a real strip.

## Removal

```bash
omarchy plugin remove io.github.chimmy89.omaperi
rm -f ~/.local/bin/omaperi
rm -rf ~/.local/state/omaperi     # remembered values, effect state, poll cache
```

Remove the widget from `bar.layout` in `~/.config/omarchy/shell.json` if you
added it there by hand. omaperi writes nothing else: no system files, no
services, no udev rules, and it never edits your configuration for you.

### Bar presentation

`barMode` (in the widget's `shell.json` entry) picks between:

- `summary` (default) — one fixed slot: the widget glyph plus the lowest
  battery among all devices, accent-coloured when low. The slot never changes
  width or disappears as devices sleep, so the click target stays put.
- `pills` — the glyph, then one slot per battery-bearing device. More
  at-a-glance detail, at the cost of a widget that changes width when a mouse
  goes to sleep.

## Usage

```bash
omaperi status                        # capability document as JSON
omaperi backends                      # adapter availability
omaperi apply v4l2:video0 brightness 180
omaperi apply headset:<vid>:<pid> eq_preset 1   # ids come from `omaperi status`
```

## Notes

- **OpenRGB is much faster with its server running.** Cold detection costs about
  1.4 s per call; against a running SDK server it is about 20 ms. Start it with
  `openrgb --server --startminimized` (that also gives you a tray icon).
- **A controller with no configured LEDs gets no colour control.** An ARGB
  header whose strip length was never set in OpenRGB reports zones but zero
  LEDs. Colouring it lights nothing, yet the accompanying mode change still
  takes the header away from whatever was driving it — so the fans on it just
  go dark. omaperi offers nothing there and says why. Set the channel sizes in
  the OpenRGB app first.
- **The headset EQ gain range is assumed, not read.** The device reports its
  real limits over HID, but headsetcontrol exposes them only through its C
  library — the CLI never prints them, upstream 4.1.0 included. Out-of-range
  values are clamped silently rather than refused, so omaperi offers ±12 dB;
  on a narrower device the ends of the sliders simply do nothing. Band *count*
  is exact: it comes from the preset definitions.
- **Colour readback needs the SDK server.** With it, the colour chip shows what
  the device is actually displaying. Without it, omaperi is on the CLI fallback
  and the chip only shows what it last set.
- **Some controls are write-only.** `headsetcontrol` can set sidetone but cannot
  read it back, so omaperi remembers what it last sent in
  `~/.local/state/omaperi/state.json` and shows that.
- **Inactive v4l2 controls are hidden, not broken.** Exposure is owned by
  auto-exposure while that is on; turn the automatic control off and the manual
  one appears on the next poll.
- **Polling is locked and cached.** The bar runs one widget instance per monitor,
  and two concurrent `headsetcontrol` calls fight over the same HID device and
  both return empty — which reads exactly like "device is off".

## Testing without hardware

```bash
OMAPERI_DUMMY=1 omaperi status
```

registers one fake device exercising every control type — range, enum, toggle,
action, readout and colour — so the panel can be worked on with nothing
plugged in. It is off unless that variable is set.

## Adding a device

See [docs/adding-a-device.md](docs/adding-a-device.md). It is one function plus
one registry line, and never any QML.

## Tests

```bash
python3 tests/test_omaperi.py
```

No hardware or network needed — they cover the two hand-written parsers.

## Author

Kim (<kimryen@gmail.com>) — <https://github.com/Chimmy89>

Bug reports and feature requests are best filed as
[issues](https://github.com/Chimmy89/omaperi/issues); mail is fine too.

## License

MIT © Kim
