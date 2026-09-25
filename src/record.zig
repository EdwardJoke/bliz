//! Frame recorder.
//!
//! Drives the prompt on a *virtual* clock and captures the exact byte stream
//! `Prompt.flush` would write for each repaint. Because `render()` is pure and
//! every animation reads `prompt.now`, the recording is deterministic and
//! pixel-identical to a live session of the same size.
//!
//! The output is consumed by `demo/player.html`, which implements the three
//! escape sequences this protocol uses (cursor-up, erase-below, SGR) and
//! replays the stream in a real terminal emulator written in ~100 lines of JS.

const std = @import("std");
const term = @import("term.zig");
const tui = @import("tui.zig");
const pick = @import("pick.zig");
const bufmod = @import("buf.zig");
const script = @import("script.zig");
const discover = @import("discover.zig");

const frame_ms: i64 = 16;
/// Capture cadence. 32 ms is ~31 fps, which looks smooth and keeps the JSON small.
const capture_every: usize = 2;

pub const Frame = struct {
    /// Milliseconds since the start of the recording.
    dt: i64,
    text: []const u8,
};

/// One scripted action, stamped with the virtual time it happened. The player
/// uses these to caption the replay, so the sidebar stays in sync with the
/// recording instead of hard-coding a second copy of the script.
pub const Step = struct {
    at: i64,
    label: []const u8,
    kind: Kind,

    pub const Kind = enum { scan, settle, key, hold, done };
};

pub const Recording = struct {
    frames: []Frame,
    steps: []Step,
    /// Result of the one-line-one-row check on the final frame. Recorded so a
    /// caller can gate on it (`record --verify` exits non-zero on violation)
    /// without having to re-derive the invariant from the byte stream.
    check: tui.FrameCheck,
};

pub const Options = struct {
    cols: usize = 104,
    rows: usize = 30,
    sync: bool = false,
    script: []const u8,
    title: []const u8 = "bliz find",
    /// Roots scanned per virtual frame during the loading phase.
    load_budget: usize = 1,
};

pub fn record(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    roots: []discover.RootCandidate,
    prompt_opts: tui.Options,
    opts: Options,
    cwd: []const u8,
) !Recording {
    const p = try arena.create(tui.Prompt);
    p.* = tui.Prompt.init(arena, gpa, io, env, roots, prompt_opts, cwd);
    defer p.deinit();
    p.setSize(opts.cols, opts.rows);
    p.now = 0;
    p.started_ms = 0;
    return drive(arena, p, opts);
}

/// The same recording, for the destination picker.
///
/// It shares `drive` because both prompts speak the frame protocol written
/// down in `paint.zig`; the only thing the recorder has to know about the
/// difference is that the picker has no scan to wait for.
pub fn recordPicker(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    items: []pick.Item,
    prompt_opts: pick.Options,
    opts: Options,
    cwd: []const u8,
) !Recording {
    const p = try arena.create(pick.Prompt);
    p.* = pick.Prompt.init(arena, gpa, io, env, items, prompt_opts, cwd);
    defer p.deinit();
    p.setSize(opts.cols, opts.rows);
    // The virtual clock starts at zero, so the entrance stagger `init` derived
    // from `now == 0` is exactly right here — unlike the live driver, which has
    // to re-arm it against the real monotonic clock.
    p.now = 0;
    p.started_ms = 0;
    return drive(arena, p, opts);
}

/// Runs a prompt on a virtual clock and captures its byte stream.
///
/// Generic over the prompt type on purpose: the recorder must not become a
/// second implementation of any prompt, or a recording would stop being
/// evidence about the real one. All it requires is the frame-protocol surface
/// (`render`, `update`, `now`, `frame`, `frame_rows`, `dirty`,
/// `wantsAnimation`, `handleInput`, `outcome`, `checkFrame`) plus, optionally,
/// a scan to wait out.
fn drive(arena: std.mem.Allocator, p: anytype, opts: Options) !Recording {
    const T = @TypeOf(p.*);
    var frames: std.ArrayList(Frame) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    var scratch = bufmod.Buf.init(arena);
    var on_screen_rows: usize = 0;
    var tick: usize = 0;
    var virtual_ms: i64 = 0;

    const tokens = try script.parse(arena, opts.script);
    var token_index: usize = 0;
    var hold_until: i64 = -1;

    // Phase 1: scanning, for prompts that have one. Keep ticking until the scan
    // lands *and* the minimum display time has passed, so the loading state is
    // actually observable.
    if (comptime @hasDecl(T, "loadTick")) {
        try steps.append(arena, .{ .at = 0, .label = "scanning agent roots", .kind = .scan });
        var guard: usize = 0;
        while (guard < 4000) : (guard += 1) {
            if (p.scan_complete and virtual_ms >= p.opts.min_load_ms) break;
            _ = p.loadTick(opts.load_budget);
            if (p.scan_complete and virtual_ms >= p.opts.min_load_ms) break;
            try capture(arena, &frames, p, &scratch, &on_screen_rows, &tick, virtual_ms, opts.sync);
            virtual_ms += frame_ms;
            p.now = virtual_ms;
            p.update(@as(f32, @floatFromInt(frame_ms)) / 1000.0);
        }
        p.finalizeLoad();
    }
    try steps.append(arena, .{ .at = virtual_ms, .label = "list settles", .kind = .settle });

    // Phase 2: the list settles in.
    {
        var guard: usize = 0;
        while (guard < 60) : (guard += 1) {
            try capture(arena, &frames, p, &scratch, &on_screen_rows, &tick, virtual_ms, opts.sync);
            virtual_ms += frame_ms;
            p.now = virtual_ms;
            p.update(@as(f32, @floatFromInt(frame_ms)) / 1000.0);
            if (!p.wantsAnimation()) break;
        }
    }

    // Phase 3: replay the scripted key sequence.
    while (token_index < tokens.len) {
        const token = tokens[token_index];
        token_index += 1;
        if (token.bytes.len > 0) {
            try steps.append(arena, .{ .at = virtual_ms, .label = token.label, .kind = .key });
            p.handleInput(token.bytes);
        } else {
            try steps.append(arena, .{ .at = virtual_ms, .label = token.label, .kind = .hold });
        }
        hold_until = if (token.wait_ms > 0) virtual_ms + token.wait_ms else virtual_ms;

        var guard: usize = 0;
        while (guard < 400) : (guard += 1) {
            try capture(arena, &frames, p, &scratch, &on_screen_rows, &tick, virtual_ms, opts.sync);
            virtual_ms += frame_ms;
            p.now = virtual_ms;
            p.update(@as(f32, @floatFromInt(frame_ms)) / 1000.0);
            if (virtual_ms >= hold_until and !p.wantsAnimation()) break;
        }
        if (p.outcome != null) break;
    }

    // Phase 4: let the finished frame land.
    if (p.outcome != null) {
        try steps.append(arena, .{ .at = virtual_ms, .label = "selection returned", .kind = .done });
        var guard: usize = 0;
        while (guard < 30) : (guard += 1) {
            try capture(arena, &frames, p, &scratch, &on_screen_rows, &tick, virtual_ms, opts.sync);
            virtual_ms += frame_ms;
            p.now = virtual_ms;
            p.update(@as(f32, @floatFromInt(frame_ms)) / 1000.0);
            if (!p.wantsAnimation()) break;
        }
    }

    return .{
        .frames = try frames.toOwnedSlice(arena),
        .steps = try steps.toOwnedSlice(arena),
        .check = p.checkFrame(),
    };
}

/// Appends every `capture_every`-th virtual frame.
///
/// `on_screen_rows` must track the height of the last frame actually *written*,
/// not the last one rendered. The reference prompt’s protocol is
/// `\x1b[{lastRenderHeight}A\x1b[J` + frame: the erase starts at the top of the
/// frame currently on screen, which keeps the frame top-anchored (so a shrinking
/// layout cannot leave stale rows above it) and keeps the cursor arithmetic
/// exact. Advancing `on_screen_rows` on a skipped tick would make it lag the
/// real screen by one tick, and the top would slide by the height delta every
/// time the layout changed.
fn capture(
    arena: std.mem.Allocator,
    frames: *std.ArrayList(Frame),
    p: anytype,
    scratch: *bufmod.Buf,
    on_screen_rows: *usize,
    tick: *usize,
    virtual_ms: i64,
    sync: bool,
) !void {
    p.render();
    tick.* += 1;
    if (@mod(tick.*, capture_every) != 0) return;

    scratch.clear();
    if (on_screen_rows.* > 0) {
        var upbuf: [32]u8 = undefined;
        scratch.add(term.moveUp(&upbuf, on_screen_rows.*));
        scratch.add(term.ERASE_BELOW);
    }
    if (sync) scratch.add(term.SYNC_BEGIN);
    addStripped(scratch, p.frame.bytes());
    scratch.add(term.RESET);
    if (sync) scratch.add(term.SYNC_END);

    try frames.append(arena, .{ .dt = virtual_ms, .text = try arena.dupe(u8, scratch.bytes()) });
    on_screen_rows.* = p.frame_rows;
}

/// Adds the frame with trailing spaces on each line removed. Trailing padding
/// is only ever there to overwrite stale cells, and the player erases the
/// region first, so dropping it shrinks the payload by more than half.
fn addStripped(b: *bufmod.Buf, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) b.add("\n");
        first = false;
        b.add(std.mem.trimEnd(u8, line, " "));
    }
}

/// Serialises a recording as JSON with an embedded JSON string escaper, so the
/// player can be a single self-contained HTML file.
pub fn toJson(arena: std.mem.Allocator, rec: Recording, opts: Options) ![]u8 {
    var b = bufmod.Buf.init(arena);
    b.add("{\n  \"version\": 1,\n");
    b.addFmt("  \"title\": ", .{});
    addJsonString(&b, opts.title);
    b.add(",\n");
    b.addFmt("  \"cols\": {d},\n  \"rows\": {d},\n  \"frameMs\": {d},\n", .{ opts.cols, opts.rows, frame_ms });
    b.add("  \"steps\": [\n");
    for (rec.steps, 0..) |s, i| {
        if (i > 0) b.add(",\n");
        b.addFmt("    {{ \"at\": {d}, \"kind\": ", .{s.at});
        addJsonString(&b, @tagName(s.kind));
        b.add(", \"label\": ");
        addJsonString(&b, s.label);
        b.add(" }");
    }
    b.add("\n  ],\n");
    b.add("  \"frames\": [\n");
    for (rec.frames, 0..) |f, i| {
        if (i > 0) b.add(",\n");
        b.addFmt("    {{ \"dt\": {d}, \"text\": ", .{f.dt});
        addJsonString(&b, f.text);
        b.add(" }");
    }
    b.add("\n  ]\n}\n");
    return b.toOwnedSlice();
}

fn addJsonString(b: *bufmod.Buf, s: []const u8) void {
    b.addByte('"');
    for (s) |c| {
        switch (c) {
            '"' => b.add("\\\""),
            '\\' => b.add("\\\\"),
            '\n' => b.add("\\n"),
            '\r' => b.add("\\r"),
            '\t' => b.add("\\t"),
            0x08 => b.add("\\b"),
            0x0c => b.add("\\f"),
            else => {
                if (c < 0x20) {
                    b.addFmt("\\u{x:0>4}", .{c});
                } else {
                    b.addByte(c);
                }
            },
        }
    }
    b.addByte('"');
}

/// Base64 of the gzip stream for `json`.
///
/// The recording is a wall of escape codes, so it deflates by two to three
/// orders of magnitude — enough to embed the whole thing inside a single
/// self-contained HTML file instead of shipping a sibling `.json` (which
/// `file://` pages cannot `fetch` anyway, thanks to CORS).
pub fn toGzipBase64(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var sink = try std.Io.Writer.Allocating.initCapacity(arena, 1 << 16);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&sink.writer, &window, .gzip, .default);
    try c.writer.writeAll(json);
    try c.finish();

    const gz = sink.written();
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(gz.len));
    return encoder.encode(out, gz);
}
