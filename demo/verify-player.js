// Verifies demo/player.html without a browser.
//
// It pulls the *real* palette + Screen implementation out of the generated
// page, replays the recording, and asserts that the resulting grid matches what
// the live prompt would have shown at that point. This is the risky part of the
// player (the escape parser + repaint protocol); the DOM rendering on top of it
// is trivial.

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const zlib = require("zlib");

const htmlPath = process.argv[2] || path.join(__dirname, "player.html");
const html = fs.readFileSync(htmlPath, "utf8");

// --- frames payload ----------------------------------------------------------
const m = html.match(/const FRAMES_B64 = "([A-Za-z0-9+/=]*)"/);
if (!m) throw new Error("no frames payload found in " + htmlPath);
const rec = JSON.parse(zlib.gunzipSync(Buffer.from(m[1], "base64")).toString("utf8"));

// --- the real emulator source ------------------------------------------------
const from = html.indexOf("const BASE16 = [");
const to = html.indexOf("/* --------------------------------------------------------------------- data */");
if (from < 0 || to < 0) throw new Error("could not locate the emulator source");
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(html.slice(from, to) + "\nthis.Screen = Screen;", sandbox);

// --- replay ------------------------------------------------------------------
const s = new sandbox.Screen(rec.cols, rec.rows);

function grid() {
  const lines = [];
  for (let y = 0; y < rec.rows; y++) {
    let row = "";
    for (let x = 0; x < rec.cols; x++) row += s.ch[s.idx(x, y)];
    lines.push(row.replace(/\s+$/, ""));
  }
  return lines.join("\n");
}

function replayTo(index) {
  s.reset();
  for (let i = 0; i <= index; i++) s.feed(rec.frames[i].text);
}

function atTime(ms) {
  let idx = 0;
  for (let i = 0; i < rec.frames.length; i++) if (rec.frames[i].dt <= ms) idx = i;
  return idx;
}

// --- what each recording is meant to show ------------------------------------
//
// The structural invariants further down are generic and run for every
// recording. These are not: they name strings a *particular* demo exists to
// demonstrate, which only the demo knows. Keyed by the recording's own title so
// a second recording (`bliz record --pick`) can carry its own expectations
// instead of being checked against the first one's.
let bad = 0;

const EXPECT = {
  "bliz find": {
    midAt: 1400,
    mid: ["Select skills", "type to filter", "Select all", "Claude Code", "code-review",
          "├─", "└─", "group", "Description", "skills in"],
    final: ["Select skills", "done", "skills selected"],
  },
  "bliz install": {
    // The middle of the recording is the *global* tab, one destination taken
    // there: the scope switch with the second segment active, the two headings
    // renamed for that scope ("Installed" / "Not installed" rather than "In this
    // project" / "Not here yet"), a `~`-relative path, the summary reporting the
    // tick left behind on the other tab, and the footer's commitment count.
    //
    // The sample point is late rather than at the nominal 260 ms of the opening
    // `wait:` token, because the header shimmer counts as animation for its full
    // 900 ms — so the recorder cannot advance past a wait token while it runs,
    // and every early token is stretched behind it.
    midAt: 3600,
    mid: ["Install to", "scope", "global", "Installed", "1 destination",
          "Not installed", "~/.codebuddy/skills", "will be created",
          "1 will be created", "+6 in project"],
    final: ["Install to", "done", "7 destinations selected"],
  },
};
const exp = EXPECT[rec.title] || { midAt: 1000, mid: [], final: [] };
// A recording nobody wrote expectations for would otherwise pass on the
// structural invariants alone while showing nothing in particular.
if (!EXPECT[rec.title]) {
  console.log("  FAIL no expectations registered for title " + JSON.stringify(rec.title));
  bad++;
}

function check(label, text, want) {
  for (const w of want) {
    const ok = text.includes(w);
    if (!ok) bad++;
    console.log("  " + (ok ? "ok  " : "FAIL") + "  " + label + "  " + JSON.stringify(w));
  }
}

// Mid-recording: the filtered list is on screen with rows, tree elbows and hints.
const mid = atTime(exp.midAt);
replayTo(mid);
const midGrid = grid();
console.log("--- t=" + (rec.frames[mid].dt / 1000).toFixed(2) + "s (frame " + mid + ") ---");
console.log(midGrid);
console.log();
check("mid", midGrid, exp.mid);

// Final: the prompt has been submitted.
replayTo(rec.frames.length - 1);
const finalGrid = grid();
console.log("--- final (frame " + (rec.frames.length - 1) + ") ---");
console.log(finalGrid);
console.log();
check("final", finalGrid, exp.final);

// --- structural invariants ---------------------------------------------------
console.log("\n" + "=".repeat(rec.cols));

// 1. Every recorded frame must be a well-formed frame: leading cursor-up equal
//    to the previous frame's height, erase-below, and no row wider than `cols`.
const strip = t => t.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
let height = 0, widest = 0;
for (let i = 0; i < rec.frames.length; i++) {
  const t = rec.frames[i].text;
  const mm = t.match(/^\x1b\[(\d+)A\x1b\[J/);
  const up = mm ? +mm[1] : 0;
  if (i === 0 && up !== 0) { console.log("  FAIL frame 0 should not move up"); bad++; }
  if (i > 0 && up !== height) {
    console.log("  FAIL frame " + i + " moved up " + up + " but the screen holds " + height);
    bad++;
    if (bad > 4) break;
  }
  const body = mm ? t.slice(mm[0].length) : t.replace(/^\x1b\[J/, "");
  // The frame's on-screen height is its newline count: every row is linefeed
  // terminated, so `h` linefeeds leave the cursor `h` rows below the top. The
  // trailing SGR after the last linefeed does not add a row.
  const lines = body.split("\n");
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
  for (const l of lines) widest = Math.max(widest, strip(l).length);
  height = (body.match(/\n/g) || []).length;
}
console.log("  widest row across the whole recording: " + widest + " cells (cols=" + rec.cols + ")");
if (widest > rec.cols) { console.log("  FAIL a row is wider than the terminal"); bad++; }

// 2. Frame heights must stay inside the canvas.
if (height > rec.rows) { console.log("  FAIL final frame is taller than the terminal"); bad++; }

console.log("\n" + rec.frames.length + " frames, " + rec.steps.length + " steps, " +
  (bad === 0 ? "PASS" : bad + " FAILURE(S)"));
process.exit(bad === 0 ? 0 : 1);
