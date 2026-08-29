# Adding a device

omaperi has no device database. The panel renders **capabilities**, not brand
names, so supporting new hardware means teaching one adapter to describe it —
never touching `Panel.qml`.

There are two cases, and the first one is the common one.

## 1. The device is new, the backend is not

A second Razer mouse, another headset `headsetcontrol` supports, any webcam:
**nothing to do**. The existing adapter enumerates whatever the tool reports.
Plug it in and it appears on the next poll.

## 2. The backend is new

A vendor needs a tool omaperi does not speak yet — `rivalcfg` for SteelSeries
mice, `ckb-next` for Corsair, `solaar` for Logitech Unifying. That is one
adapter.

### Checklist

1. Write three functions in `bin/omaperi`:

   ```python
   def rivalcfg_available():
       if not shutil.which("rivalcfg"):
           return False, "rivalcfg not installed"
       return True, None

   def rivalcfg_devices():
       # Ask the tool what it sees. Return [] if nothing.
       return [{
           "id": "rivalcfg:%s" % serial,   # stable, unique, backend-prefixed
           "name": "SteelSeries Rival 3",
           "kind": "mouse",                # headset|mouse|keyboard|webcam|...
           "backend": "rivalcfg",
           "battery": {"level": 80, "charging": False},   # or None
           "controls": [
               control("dpi", "DPI", "range", min=100, max=8500, step=100, value=800),
           ],
           "note": None,                   # a sentence when something is off
       }]

   def rivalcfg_apply(dev, key, value):
       rc, _out, err = run(["rivalcfg", "--sensitivity", str(value)])
       if rc != 0:
           raise SystemExit("rivalcfg failed: %s" % err.strip())
   ```

2. Register it:

   ```python
   ADAPTERS = {
       ...
       "rivalcfg": (rivalcfg_available, rivalcfg_devices, rivalcfg_apply),
   }
   ```

3. `python3 tests/test_omaperi.py`, then `omaperi status` with the hardware
   plugged in.

You do **not** edit `Panel.qml`, `Model.js`, or the manifest.

### Rules that keep the panel honest

- **Report only what the device really has.** A control that silently does
  nothing is worse than a missing one. When a tool cannot tell you, leave the
  control out and put a sentence in `note`.
- **`available()` must be cheap and must not throw.** It runs on every poll.
  Return `(False, "reason")` rather than raising — the reason is shown to the
  user.
- **Prefix ids with the backend** and keep them stable across replugs. The panel
  addresses controls by `(device id, control key)`.
- **`0` is a valid value.** Use `None` for unknown, never `0` or `-1`.
- **Write-only controls should remember.** Use `remembered(dev_id, key,
  fallback)` / `remember(dev_id, key, value)` so the slider reflects what was
  last sent instead of snapping back.
- **Never shell out on import.** Enumeration happens in `devices()`, behind the
  poll lock and cache.

## Control types

| Type | Renders as | Required fields |
|---|---|---|
| `range` | slider | `min`, `max`, `step`, `value`; optional `unit` |
| `enum` | dropdown | `options: [{value, label}]`, `value` |
| `toggle` | switch | `value` (bool) |
| `action` | button | — |
| `readout` | text | `value` |
| `color` | swatch row | `value` (`#rrggbb`) |

If your device needs something none of these express, add the type to
`Panel.qml` once — after that every adapter can use it.
