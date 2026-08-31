// Pure helpers for the omaperi panel. No QML types in here so tests/test_model.js
// can run this file under plain JS. Deliberately ES5: the shell's other plugin
// JS avoids arrow functions and Array.find, so this matches.

.pragma library

var GLYPH = {
  headset: "󰋋",
  mouse: "󰍽",
  keyboard: "󰌌",
  webcam: "󰄀",
  screen: "󰍹",
  motherboard: "󰐚",
  memory: "󰍛",
  gpu: "󰢮",
  cooler: "󰈐",
  light: "󰌵",
  speaker: "󰓃",
  storage: "󰋊",
  microphone: "󰍬",
  gamepad: "󰊴",
  case: "󰟀",
  mousemat: "󰝤",
  other: "󰘮"
}

var FALLBACK_GLYPH = "󰘮"

function glyphFor(kind) {
  return GLYPH[kind] || FALLBACK_GLYPH
}

// Returns {devices, backends, error}. A parse failure keeps the caller's last
// good document rather than blanking the bar on a hiccup.
function parseDocument(text) {
  var doc
  try {
    doc = JSON.parse(String(text || ""))
  } catch (e) {
    return { devices: null, backends: null, error: "unreadable output" }
  }
  if (!doc || !doc.devices) {
    return { devices: null, backends: null, error: "no devices field" }
  }
  return { devices: doc.devices, backends: doc.backends || [], error: null }
}

// Devices that report a battery, in document order — these get a bar slot.
function batteryEntries(devices) {
  var out = []
  for (var i = 0; i < (devices || []).length; i++) {
    var d = devices[i]
    if (d.battery && typeof d.battery.level === "number" && d.battery.level >= 0) {
      out.push({
        id: d.id,
        name: d.name,
        glyph: glyphFor(d.kind),
        level: d.battery.level,
        charging: d.battery.charging === true
      })
    }
  }
  return out
}

// The device with least charge, which is the one worth a glance in the bar.
function lowestBattery(devices) {
  var entries = batteryEntries(devices)
  if (!entries.length) return null
  var lowest = entries[0]
  for (var i = 1; i < entries.length; i++) {
    if (entries[i].level < lowest.level) lowest = entries[i]
  }
  return lowest
}

// Summary mode keeps one fixed slot: the widget's own glyph, plus the lowest
// battery when anything reports one. Never changes width as devices sleep.
function summaryText(devices, showPercentage) {
  var glyph = glyphFor("other")
  if (!showPercentage) return glyph
  var lowest = lowestBattery(devices)
  return lowest ? glyph + "  " + lowest.level + "%" : glyph
}

function isLow(entry, lowPct) {
  return entry.level <= lowPct && !entry.charging
}

function anyLow(devices, lowPct) {
  var entries = batteryEntries(devices)
  for (var i = 0; i < entries.length; i++) {
    if (isLow(entries[i], lowPct)) return true
  }
  return false
}

function lowEntries(devices, lowPct) {
  return batteryEntries(devices).filter(function (e) { return isLow(e, lowPct) })
}

// Count of devices actually offering something to change, for the bar tooltip.
function controllableCount(devices) {
  var n = 0
  for (var i = 0; i < (devices || []).length; i++) {
    var controls = devices[i].controls || []
    for (var j = 0; j < controls.length; j++) {
      if (controls[j].type !== "readout") { n++; break }
    }
  }
  return n
}

function tooltipFor(devices, backends) {
  if (!devices || !devices.length) return "No peripherals detected"
  var entries = batteryEntries(devices)
  var parts = []
  for (var i = 0; i < entries.length; i++) {
    parts.push(entries[i].name + " " + entries[i].level + "%" +
               (entries[i].charging ? " · charging" : ""))
  }
  if (!parts.length) {
    parts.push(devices.length + " device" + (devices.length === 1 ? "" : "s"))
  }
  var off = unavailableBackends(backends)
  if (off.length) parts.push("inactive: " + off.join(", "))
  return parts.join("\n")
}

function unavailableBackends(backends) {
  var out = []
  for (var i = 0; i < (backends || []).length; i++) {
    if (!backends[i].available) out.push(backends[i].name)
  }
  return out
}

// Dropdown deals in strings; keep the label but stringify the value so the
// panel can hand the original back to the CLI unchanged.
function dropdownOptions(control) {
  var out = []
  var options = control.options || []
  for (var i = 0; i < options.length; i++) {
    out.push({ value: String(options[i].value), label: String(options[i].label) })
  }
  return out
}

function displayValue(control) {
  if (control.type === "range") {
    var v = (control.value === null || control.value === undefined) ? "—" : control.value
    return control.unit ? (v + " " + control.unit) : String(v)
  }
  if (control.type === "enum") {
    var options = control.options || []
    for (var i = 0; i < options.length; i++) {
      if (String(options[i].value) === String(control.value)) return String(options[i].label)
    }
    return "—"
  }
  if (control.type === "readout") return String(control.value)
  if (control.type === "color") return String(control.value || "")
  return ""
}

// Compact tab labels. A kind name reads better than a product string
// ("Mouse", not "Razer HyperPolling Wireless Dongle"), but two devices of the
// same kind would then be indistinguishable, so fall back to the real name
// only when the kind is not unique.
var KIND_LABEL = {
  headset: "Headset",
  mouse: "Mouse",
  keyboard: "Keyboard",
  webcam: "Webcam",
  screen: "Screen",
  motherboard: "Board",
  memory: "RAM",
  gpu: "GPU",
  cooler: "Cooler",
  light: "Lighting",
  speaker: "Speaker",
  storage: "Storage",
  microphone: "Mic",
  gamepad: "Gamepad",
  case: "Case",
  mousemat: "Mousemat",
  other: "Device"
}

// Prefer whatever the backend called the device type over a generic word, so
// an OpenRGB type omaperi does not map still reads as itself.
function kindLabel(device) {
  if (device.type_label) return String(device.type_label)
  return KIND_LABEL[device.kind] || "Device"
}

function shortenName(name) {
  // Vendors love repeating themselves: "Trust USB Camera: Trust USB Cam".
  var s = String(name || "").split(":")[0].trim()
  return s.length > 20 ? s.substring(0, 19) + "\u2026" : s
}

function kindIsUnique(devices, kind) {
  var n = 0
  for (var i = 0; i < (devices || []).length; i++) {
    if (devices[i].kind === kind) n++
  }
  return n <= 1
}

function tabLabel(devices, device) {
  var base = kindIsUnique(devices, device.kind)
             ? kindLabel(device)
             : shortenName(device.name)
  var label = glyphFor(device.kind) + "  " + base
  if (device.battery && typeof device.battery.level === "number" && device.battery.level >= 0) {
    label += "  " + device.battery.level + "%"
  }
  return label
}

// Keep a selection pointing at something that still exists, without losing the
// user's pick just because a poll reordered the list.
function resolveSelection(devices, currentId) {
  if (!devices || !devices.length) return ""
  for (var i = 0; i < devices.length; i++) {
    if (devices[i].id === currentId) return currentId
  }
  return devices[0].id
}

function findDevice(devices, id) {
  for (var i = 0; i < (devices || []).length; i++) {
    if (devices[i].id === id) return devices[i]
  }
  return null
}

// Swatches cover the common picks; the hue slider covers everything between.
// Saturation and value stay at full: pastels and off-whites are what the
// swatch row is for.
function hsvToHex(h, sat, val) {
  var c = val * sat
  var x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  var m = val - c
  var r = 0, g = 0, b = 0
  if (h < 60)       { r = c; g = x }
  else if (h < 120) { r = x; g = c }
  else if (h < 180) { g = c; b = x }
  else if (h < 240) { g = x; b = c }
  else if (h < 300) { r = x; b = c }
  else              { r = c; b = x }
  return "#" + pad2(Math.round((r + m) * 255))
             + pad2(Math.round((g + m) * 255))
             + pad2(Math.round((b + m) * 255))
}

function pad2(n) {
  var s = Math.max(0, Math.min(255, n)).toString(16)
  return s.length < 2 ? "0" + s : s
}

// Hue of a "#rrggbb", so the slider starts where the current colour is.
function hueOf(hex) {
  var v = String(hex || "").replace("#", "")
  if (v.length !== 6) return 0
  var r = parseInt(v.substring(0, 2), 16) / 255
  var g = parseInt(v.substring(2, 4), 16) / 255
  var b = parseInt(v.substring(4, 6), 16) / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  if (d === 0) return 0
  var h
  if (max === r) h = ((g - b) / d) % 6
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  h = Math.round(h * 60)
  return h < 0 ? h + 360 : h
}

// Saturation and value of a "#rrggbb", so a picker can start where the
// current colour is rather than snapping to a corner.
function satOf(hex) {
  var c = rgbOf(hex)
  var max = Math.max(c.r, c.g, c.b)
  return max === 0 ? 0 : (max - Math.min(c.r, c.g, c.b)) / max
}

function valOf(hex) {
  var c = rgbOf(hex)
  return Math.max(c.r, c.g, c.b)
}

function rgbOf(hex) {
  var v = String(hex || "").replace("#", "")
  if (v.length !== 6) return { r: 0, g: 0, b: 0 }
  return {
    r: parseInt(v.substring(0, 2), 16) / 255,
    g: parseInt(v.substring(2, 4), 16) / 255,
    b: parseInt(v.substring(4, 6), 16) / 255
  }
}
