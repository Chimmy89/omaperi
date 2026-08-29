// Pure helpers for the omaperi panel. No QML types in here so tests/test_model.js
// can run this file under plain JS. Deliberately ES5: the shell's other plugin
// JS avoids arrow functions and Array.find, so this matches.

.pragma library

var GLYPH = {
  headset: "󰋋",
  mouse: "󰍽",
  keyboard: "󰌌",
  webcam: "󰄀",
  motherboard: "󰐚",
  memory: "󰍛",
  gpu: "󰢮",
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
  motherboard: "Board",
  memory: "RAM",
  gpu: "GPU",
  other: "Device"
}

function kindLabel(kind) {
  return KIND_LABEL[kind] || "Device"
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
             ? kindLabel(device.kind)
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

var SWATCHES = [
  "#ff0033", "#ff7700", "#ffdd00", "#00ff88",
  "#00ddff", "#3355ff", "#aa44ff", "#ffffff"
]
