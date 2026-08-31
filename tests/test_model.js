#!/usr/bin/env node
// Plain-JS checks for Model.js, per the file's own header comment.
//
//     node tests/test_model.js
//
// Model.js has no module.exports (it's a QML pragma-library, whose top-level
// functions QML exposes as `Model.foo`), so this loads it into a fresh vm
// context instead of require()-ing it, which would just see an empty module.

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(".pragma library", "");
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(src, sandbox);

const devices = [
  { id: "a", kind: "mouse", battery: { level: 10, charging: false } },
  { id: "b", kind: "headset", battery: { level: 80, charging: false } },
  { id: "c", kind: "mouse", battery: { level: 5, charging: true } },
];

const low = sandbox.lowEntries(devices, 15);
assert.strictEqual(low.length, 1, "a charging device below the threshold should not count as low");
assert.strictEqual(low[0].id, "a");

// A cross-realm array (this runs in a separate vm context) fails
// assert.deepStrictEqual against a host-realm [], so check length instead.
assert.strictEqual(sandbox.lowEntries(devices, 4).length, 0, "nothing is low below every battery level");

const parsed = sandbox.parseDocument(JSON.stringify({ devices: [], profiles: ["Gaming"] }));
assert.strictEqual(parsed.profiles.length, 1);
assert.strictEqual(parsed.profiles[0], "Gaming");

const noProfiles = sandbox.parseDocument(JSON.stringify({ devices: [] }));
assert.strictEqual(noProfiles.profiles.length, 0, "an older document with no profiles field should not throw");

console.log("Model.js: ok");
