//! Frame painting primitives, shared by every animated prompt.
//!
//! There are two prompts in this tool — the skill multiselect (`tui.zig`) and
//! the destination picker (`pick.zig`) — and they paint with the same protocol.
//! The protocol is subtle enough that having a second, independently written
//! copy of it would be a bug waiting to happen, so it lives here once:
//!
//!   * every emitted line is truncated *and* padded to exactly `cols` display
//!     cells, so one logical line is always exactly one terminal row and can
//!     never soft-wrap;
//!   * the repaint walks the cursor up by the height of the frame **currently on
//!     screen**, not the new frame's height, which keeps the layout top-anchored.
//!     Using the new height drifts one row per frame, forever, whenever the
//!     frame changes size.
//!
//! `checkFrame` turns the first rule into something a test can assert, and
//! `record --verify` gates the build on it.

const std = @import("std");
const term = @import("term.zig");
const width = @import("width.zig");
const bufmod = @import("buf.zig");

pub const FrameCheck = struct {
    violations: usize = 0,
    worst_line: usize = 0,
    worst_width: usize = 0,
    expected: usize = 0,
};

pub fn addSpaces(b: *bufmod.Buf, n: usize) void {
    const sp = "                                                                ";
    var left = n;
    while (left > 0) {
        const k = @min(left, sp.len);
        b.add(sp[0..k]);
        left -= k;
    }
}

pub fn countRows(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Appends the buffered row to `frame` as exactly one line of `cols` cells.
///
/// `offset` slides the right-aligned block horizontally (negative = left); that
/// is what the validation nudge and the collapse animation animate.
pub fn emitRow(
    arena: std.mem.Allocator,
    frame: *bufmod.Buf,
    row: *bufmod.Buf,
    cols: usize,
    right: []const u8,
    right_color: []const u8,
    offset: f32,
) void {
    const start = frame.len();
    const raw = row.bytes();
    const rw = width.width(right);
    const reserve: usize = if (right.len > 0) rw + 1 else 0;

    const off: i32 = @intFromFloat(offset);

    // A positive offset has to take its room out of the body, otherwise the row
    // grows past `cols`. A negative one just leaves a gap at the end, which the
    // tail top-up absorbs — visually identical to a left shift.
    var budget: i32 = @as(i32, @intCast(cols)) - @as(i32, @intCast(reserve)) - @max(off, 0);
    if (budget < 0) budget = 0;
    const left_budget: usize = @intCast(budget);

    const shown = width.truncate(raw, left_budget);
    frame.add(shown);

    var pad: i32 = @as(i32, @intCast(left_budget - width.width(shown))) + off;
    if (pad < 0) pad = 0;
    if (pad > 0) addSpaces(frame, @intCast(pad));

    if (right.len > 0) {
        frame.add(" ");
        frame.add(right_color);
        frame.add(right);
    }
    frame.add(term.RESET);

    // Belt and braces: whatever the arithmetic above did, this row leaves here
    // at exactly `cols`.
    const w = width.width(frame.bytes()[start..]);
    if (w > cols) {
        const text = arena.dupe(u8, width.truncate(frame.bytes()[start..], cols)) catch "";
        frame.truncateTo(start);
        frame.add(text);
    } else if (w < cols) {
        addSpaces(frame, cols - w);
    }

    frame.add("\n");
    row.clear();
}

/// The escape sequence that returns the cursor to the top row of the frame
/// **currently on screen** and erases it.
///
/// `painted_rows` is that frame's height — deliberately not the height of the
/// frame about to be drawn. Using the new height is the bug that makes a prompt
/// slide down the terminal one row per frame, forever, every time the layout
/// changes size: the erase starts above the frame, stranding a row that is then
/// redrawn one row lower each time. Kept separate from `flush` so the rule can
/// be asserted on directly.
pub fn erasePrevious(painted_rows: usize, buf: []u8) []const u8 {
    if (painted_rows == 0) return "";
    const up = term.moveUp(buf, painted_rows);
    const total = up.len + term.ERASE_BELOW.len;
    if (total > buf.len) return up;
    @memcpy(buf[up.len..][0..term.ERASE_BELOW.len], term.ERASE_BELOW);
    return buf[0..total];
}

/// Writes the frame with a full erase-and-redraw. The whole frame goes out in a
/// single `write()` (plus DEC 2026 sync markers where supported) so the terminal
/// never renders a half-updated prompt.
///
/// `painted_rows` must be the height of the frame currently on screen; see
/// `erasePrevious`. `frame_rows` is the height just built, which becomes the
/// next call's `painted_rows`.
pub fn flush(
    out: *term.Out,
    sync: bool,
    frame: []const u8,
    wrote_frame: *bool,
    painted_rows: *usize,
    frame_rows: usize,
) void {
    var upbuf: [32]u8 = undefined;
    if (wrote_frame.*) out.writeAll(erasePrevious(painted_rows.*, &upbuf));
    if (sync) out.writeAll(term.SYNC_BEGIN);
    out.writeAll(frame);
    out.writeAll(term.RESET);
    if (sync) out.writeAll(term.SYNC_END);
    out.flush();
    wrote_frame.* = true;
    painted_rows.* = frame_rows;
}

/// Verifies the one-line-one-row invariant the repaint depends on: every row
/// must measure exactly `cols` cells, otherwise it would soft-wrap and the
/// `move up N` arithmetic would drift.
pub fn checkFrame(frame: []const u8, cols: usize) FrameCheck {
    var result = FrameCheck{ .expected = cols };
    var it = std.mem.splitScalar(u8, frame, '\n');
    var line_index: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const w = width.width(line);
        if (w != cols) {
            result.violations += 1;
            if (w > result.worst_width) {
                result.worst_width = w;
                result.worst_line = line_index;
            }
        }
        line_index += 1;
    }
    return result;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "emitRow always leaves a line of exactly cols cells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var frame = bufmod.Buf.init(arena);
    var row = bufmod.Buf.init(arena);

    // Short body, long body, and a body that has to be cut to make room for
    // the right-aligned hint — all three have to land on `cols`.
    const cases = [_][]const u8{ "x", "a much longer body than the width", "界界界" };
    for (cases) |body| {
        row.add(body);
        emitRow(arena, &frame, &row, 20, "42", "\x1b[2m", 0);
    }
    try testing.expectEqual(@as(usize, 3), countRows(frame.bytes()));
    try testing.expectEqual(@as(usize, 0), checkFrame(frame.bytes(), 20).violations);

    // A positive offset eats into the body, and must not push the row over.
    row.add("body");
    emitRow(arena, &frame, &row, 20, "hint", "\x1b[2m", 6.0);
    try testing.expectEqual(@as(usize, 0), checkFrame(frame.bytes(), 20).violations);

    frame.deinit();
    row.deinit();
}

test "checkFrame reports a row that is not cols wide" {
    const chk = checkFrame("abc\n", 5);
    try testing.expectEqual(@as(usize, 1), chk.violations);
    try testing.expectEqual(@as(usize, 3), chk.worst_width);
    try testing.expectEqual(@as(usize, 5), chk.expected);

    // Trailing newlines are separators, not rows.
    try testing.expectEqual(@as(usize, 0), checkFrame("abcde\n", 5).violations);
}

test "the erase walks up over the frame that is on screen" {
    var buf: [32]u8 = undefined;
    // Nothing painted yet: there is nothing above to erase.
    try testing.expectEqualStrings("", erasePrevious(0, &buf));
    // Two rows on screen, so two rows up — regardless of how tall the frame
    // about to be written is.
    try testing.expectEqualStrings("\x1b[2A\x1b[J", erasePrevious(2, &buf));
    try testing.expectEqualStrings("\x1b[11A\x1b[J", erasePrevious(11, &buf));
    // A frame taller than the terminal must still produce a valid sequence
    // rather than a truncated `bufPrint`.
    try testing.expectEqualStrings("\x1b[999A\x1b[J", erasePrevious(999, &buf));
}
