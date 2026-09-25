//! Display-width maths.
//!
//! Terminal cells are not bytes and not codepoints: CJK and most emoji occupy
//! two cells. Every measurement, truncation and alignment in the UI goes
//! through here, which is what keeps the left rail perfectly straight even
//! when skill descriptions contain wide characters.

const std = @import("std");

const Range = struct { lo: u21, hi: u21 };

/// Sorted, coalesced wide ranges (East Asian Wide/Fullwidth + emoji).
const wide_ranges = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115F },
    .{ .lo = 0x231A, .hi = 0x231B },
    .{ .lo = 0x2329, .hi = 0x232A },
    .{ .lo = 0x23E9, .hi = 0x23EC },
    .{ .lo = 0x23F0, .hi = 0x23F0 },
    .{ .lo = 0x23F3, .hi = 0x23F3 },
    .{ .lo = 0x25FD, .hi = 0x25FE },
    .{ .lo = 0x2614, .hi = 0x2615 },
    .{ .lo = 0x2648, .hi = 0x2653 },
    .{ .lo = 0x267F, .hi = 0x267F },
    .{ .lo = 0x2693, .hi = 0x2693 },
    .{ .lo = 0x26A1, .hi = 0x26A1 },
    .{ .lo = 0x26AA, .hi = 0x26AB },
    .{ .lo = 0x26BD, .hi = 0x26BE },
    .{ .lo = 0x26C4, .hi = 0x26C5 },
    .{ .lo = 0x26CE, .hi = 0x26CE },
    .{ .lo = 0x26D4, .hi = 0x26D4 },
    .{ .lo = 0x26EA, .hi = 0x26EA },
    .{ .lo = 0x26F2, .hi = 0x26F3 },
    .{ .lo = 0x26F5, .hi = 0x26F5 },
    .{ .lo = 0x26FA, .hi = 0x26FA },
    .{ .lo = 0x26FD, .hi = 0x26FD },
    .{ .lo = 0x2705, .hi = 0x2705 },
    .{ .lo = 0x270A, .hi = 0x270B },
    .{ .lo = 0x2728, .hi = 0x2728 },
    .{ .lo = 0x274C, .hi = 0x274C },
    .{ .lo = 0x274E, .hi = 0x274E },
    .{ .lo = 0x2753, .hi = 0x2755 },
    .{ .lo = 0x2757, .hi = 0x2757 },
    .{ .lo = 0x2795, .hi = 0x2797 },
    .{ .lo = 0x27B0, .hi = 0x27B0 },
    .{ .lo = 0x27BF, .hi = 0x27BF },
    .{ .lo = 0x2B1B, .hi = 0x2B1C },
    .{ .lo = 0x2B50, .hi = 0x2B50 },
    .{ .lo = 0x2B55, .hi = 0x2B55 },
    .{ .lo = 0x2E80, .hi = 0x303E },
    .{ .lo = 0x3041, .hi = 0x33FF },
    .{ .lo = 0x3400, .hi = 0x4DBF },
    .{ .lo = 0x4E00, .hi = 0x9FFF },
    .{ .lo = 0xA000, .hi = 0xA4CF },
    .{ .lo = 0xA960, .hi = 0xA97C },
    .{ .lo = 0xAC00, .hi = 0xD7A3 },
    .{ .lo = 0xF900, .hi = 0xFAFF },
    .{ .lo = 0xFE10, .hi = 0xFE19 },
    .{ .lo = 0xFE30, .hi = 0xFE6F },
    .{ .lo = 0xFF00, .hi = 0xFF60 },
    .{ .lo = 0xFFE0, .hi = 0xFFE6 },
    .{ .lo = 0x1F000, .hi = 0x1F9FF },
    .{ .lo = 0x20000, .hi = 0x2FFFD },
    .{ .lo = 0x30000, .hi = 0x3FFFD },
};

const zero_width_ranges = [_]Range{
    .{ .lo = 0x0300, .hi = 0x036F },
    .{ .lo = 0x200B, .hi = 0x200F },
    // Combining Diacritical Marks for Symbols — includes U+20E3, the enclosing
    // keycap. Without this, `1️⃣` measures as three cells and every row below it
    // on the same line shifts.
    .{ .lo = 0x20D0, .hi = 0x20FF },
    .{ .lo = 0xFE00, .hi = 0xFE0F },
    .{ .lo = 0xFEFF, .hi = 0xFEFF },
};

/// VARIATION SELECTOR-16. It contributes no glyph of its own but asks the
/// terminal to render the *preceding* character in emoji presentation, which
/// widens a one-cell base (❤) into a two-cell glyph (❤️).
const vs16: u21 = 0xFE0F;

fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn codepointWidth(cp: u21) usize {
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (inRanges(cp, &zero_width_ranges)) return 0;
    if (inRanges(cp, &wide_ranges)) return 2;
    return 1;
}

/// Decodes the next codepoint and its byte length. Invalid bytes count as 1.
fn nextCodepoint(s: []const u8) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return .{ .cp = s[0], .len = 1 };
    if (n > s.len) return .{ .cp = s[0], .len = 1 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = s[0], .len = 1 };
    return .{ .cp = @intCast(cp), .len = n };
}

/// Skips one escape sequence starting at `start` (which must point at ESC) and
/// returns the index just past it.
///
/// This has to be a real parser: treating `ESC [` as a complete sequence would
/// leave the parameters (`38;5;239`) to be measured as visible text, which
/// silently shifts every column and can slice a colour code in half on
/// truncation.
fn skipEscape(s: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= s.len) return i;
    switch (s[i]) {
        '[' => {
            // CSI: parameters, then intermediates, then a single final byte.
            i += 1;
            while (i < s.len and s[i] >= 0x30 and s[i] <= 0x3f) : (i += 1) {}
            while (i < s.len and s[i] >= 0x20 and s[i] <= 0x2f) : (i += 1) {}
            if (i < s.len) i += 1;
            return i;
        },
        ']' => {
            // OSC: terminated by BEL or ST.
            i += 1;
            while (i < s.len) : (i += 1) {
                if (s[i] == 0x07) return i + 1;
                if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') return i + 2;
            }
            return i;
        },
        else => return i + 1,
    }
}

/// Shared measurement loop. `styled` means ESC sequences are parsed and counted
/// as zero width; otherwise every byte is treated as visible text.
///
/// VS16 needs one cell of lookbehind: it widens the preceding one-cell glyph
/// instead of contributing a cell of its own, so the loop has to remember
/// whether the last glyph was promotable.
fn measure(s: []const u8, styled: bool) usize {
    var total: usize = 0;
    // True when the previous codepoint rendered a single cell and a following
    // VS16 would upgrade it to two.
    var promotable = false;
    var i: usize = 0;
    while (i < s.len) {
        if (styled and s[i] == 0x1b) {
            i = skipEscape(s, i);
            promotable = false;
            continue;
        }
        const d = nextCodepoint(s[i..]);
        if (d.cp == vs16 and promotable) {
            total += 1;
            promotable = false;
            i += d.len;
            continue;
        }
        const w = codepointWidth(d.cp);
        total += w;
        promotable = w == 1;
        i += d.len;
    }
    return total;
}

/// Number of terminal cells `s` occupies. Escape sequences measure as zero
/// width, so the same function works on plain and styled text.
pub fn width(s: []const u8) usize {
    return measure(s, true);
}

/// Width of plain text (no escape sequences present).
pub fn plainWidth(s: []const u8) usize {
    return measure(s, false);
}

/// Truncates to `max` display cells. ANSI sequences are copied through whole
/// and never counted, so a styled prefix can not be cut in half.
pub fn truncate(s: []const u8, max: usize) []const u8 {
    var cells: usize = 0;
    var i: usize = 0;
    var last_ok: usize = 0;
    var promotable = false;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEscape(s, i);
            last_ok = i;
            promotable = false;
            continue;
        }
        const d = nextCodepoint(s[i..]);
        // Must mirror `measure` exactly, or a truncation could disagree with the
        // measured width of the very same prefix.
        var w = codepointWidth(d.cp);
        const promoting = d.cp == vs16 and promotable;
        if (promoting) w = 1;
        if (cells + w > max) break;
        cells += w;
        i += d.len;
        last_ok = i;
        promotable = !promoting and w == 1;
    }
    return s[0..last_ok];
}

/// Pads `s` on the right so its display width reaches `target`.
pub fn padRight(buf: []u8, s: []const u8, target: usize) []const u8 {
    const w = width(s);
    if (w >= target) return s;
    const n = @min(target - w, buf.len -| s.len);
    @memcpy(buf[0..s.len], s);
    @memset(buf[s.len .. s.len + n], ' ');
    return buf[0 .. s.len + n];
}

/// Greedy word wrap into at most `max_lines` lines, each at most `max_width`
/// cells. Unused lines are returned as empty strings so that a fixed-height
/// pane never changes size when the highlighted row changes — the same trick
/// the reference prompt uses to avoid layout jumps.
///
/// `arena` is expected to be an arena: the normalised text and every returned
/// line slice live in storage that is only identifiable as a whole, so the
/// caller reclaims it by resetting the arena. Freeing the returned slice alone
/// would leak the backing store.
pub fn wrapLines(
    arena: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
    max_lines: usize,
) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(arena);

    // Collapse runs of whitespace so wrapped lines stay tight.
    var collapsed: std.ArrayList(u8) = .empty;
    var prev_space = false;
    for (text) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!prev_space) try collapsed.append(arena, ' ');
            prev_space = true;
        } else {
            try collapsed.append(arena, c);
            prev_space = false;
        }
    }
    const norm: []const u8 = try arena.dupe(u8, std.mem.trim(u8, collapsed.items, " "));

    var rest: []const u8 = norm;
    while (rest.len > 0 and lines.items.len < max_lines) {
        if (plainWidth(rest) <= max_width) {
            try lines.append(arena, rest);
            rest = rest[rest.len..];
            break;
        }
        const candidate = truncate(rest, max_width);
        // A single glyph wider than the whole budget makes `truncate` return
        // nothing, so stop here instead of spinning forever.
        if (candidate.len == 0) break;

        // If the candidate already ends on a word boundary then that boundary
        // falls exactly at `max_width`, so the candidate *is* the line. Breaking
        // at an earlier space would waste the cells between the two.
        const at_boundary = candidate.len == rest.len or std.ascii.isWhitespace(rest[candidate.len]);
        var break_at: ?usize = null;
        if (!at_boundary) {
            if (std.mem.findScalarLast(u8, candidate, ' ')) |i| {
                if (i > 0) break_at = i;
            }
        }

        if (break_at) |i| {
            try lines.append(arena, candidate[0..i]);
            rest = std.mem.trimStart(u8, rest[i..], " ");
        } else {
            try lines.append(arena, candidate);
            rest = std.mem.trimStart(u8, rest[candidate.len..], " ");
        }
    }

    // If text is still left over, the last line gets an ellipsis.
    if (rest.len > 0 and lines.items.len > 0) {
        const last = lines.items.len - 1;
        const trimmed = truncate(lines.items[last], if (max_width > 0) max_width - 1 else 0);
        lines.items[last] = try std.fmt.allocPrint(arena, "{s}…", .{trimmed});
    }

    while (lines.items.len < max_lines) try lines.append(arena, "");
    return lines.toOwnedSlice(arena);
}

/// Rounds a byte slice down to a codepoint boundary so slicing never splits a
/// multi-byte character.
pub fn floorBoundary(s: []const u8, mut_index: usize) usize {
    var i = @min(mut_index, s.len);
    while (i > 0 and i < s.len and (s[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ascii is one cell per byte" {
    try testing.expectEqual(@as(usize, 5), plainWidth("hello"));
    try testing.expectEqual(@as(usize, 0), plainWidth(""));
}

test "CJK and emoji are two cells" {
    // Three CJK glyphs, two cells each.
    try testing.expectEqual(@as(usize, 6), plainWidth("日本語"));
    try testing.expectEqual(@as(usize, 2), plainWidth("\u{1F600}"));
    // Fullwidth Latin lives in the FF00–FF60 range.
    try testing.expectEqual(@as(usize, 2), plainWidth("\u{FF21}"));
}

test "combining marks and joiners are zero cells" {
    // 'e' + COMBINING ACUTE ACCENT is one grapheme, hence one cell.
    try testing.expectEqual(@as(usize, 1), plainWidth("e\u{0301}"));
    // KEYCAP: '1' + VS16 + COMBINING ENCLOSING KEYCAP renders two cells.
    try testing.expectEqual(@as(usize, 2), plainWidth("1\u{FE0F}\u{20E3}"));
    try testing.expectEqual(@as(usize, 0), plainWidth("\u{200B}"));
}

test "VS16 widens a one-cell base into two" {
    // U+2764 alone is text presentation: one cell. With VS16 the terminal
    // switches to emoji presentation and it occupies two.
    try testing.expectEqual(@as(usize, 1), plainWidth("\u{2764}"));
    try testing.expectEqual(@as(usize, 2), plainWidth("\u{2764}\u{FE0F}"));
    // A base that is already wide must not be promoted twice.
    try testing.expectEqual(@as(usize, 2), plainWidth("\u{2705}\u{FE0F}"));
    try testing.expectEqual(@as(usize, 4), plainWidth("\u{2764}\u{FE0F}\u{2764}\u{FE0F}"));
}

test "escape sequences measure as zero width" {
    try testing.expectEqual(@as(usize, 4), width("\x1b[1mbold\x1b[0m"));
    try testing.expectEqual(@as(usize, 4), width("\x1b[38;5;239mtext\x1b[0m"));
    // OSC, BEL-terminated.
    try testing.expectEqual(@as(usize, 3), width("\x1b]0;title\x07abc"));
    // OSC, ST-terminated.
    try testing.expectEqual(@as(usize, 3), width("\x1b]8;;http://x\x1b\\abc"));
}

test "truncate counts cells, never bytes" {
    try testing.expectEqualStrings("hel", truncate("hello", 3));
    try testing.expectEqualStrings("hello", truncate("hello", 99));
    try testing.expectEqualStrings("", truncate("hello", 0));
    // Half a wide character cannot be shown, so it is dropped entirely.
    try testing.expectEqualStrings("", truncate("日本", 1));
    try testing.expectEqualStrings("日", truncate("日本", 3));
}

test "truncate never slices an escape sequence in half" {
    const styled = "\x1b[38;5;239mhello\x1b[0m";
    try testing.expectEqualStrings("\x1b[38;5;239mhel", truncate(styled, 3));
    // The width of a truncated prefix must agree with what truncate kept.
    var n: usize = 0;
    while (n <= 5) : (n += 1) {
        try testing.expectEqual(n, width(truncate(styled, n)));
    }
}

test "truncate never exceeds its budget and only grows" {
    const samples = [_][]const u8{
        "plain ascii",
        "\u{2764}\u{FE0F} emoji",
        "\u{65E5}\u{672C}\u{8A9E} mixed",
        "\x1b[1mstyled\x1b[0m \u{1F600}",
    };
    for (samples) |s| {
        const full = width(s);
        var n: usize = 0;
        var prev: usize = 0;
        while (n <= full + 1) : (n += 1) {
            const got = width(truncate(s, n));
            // The whole point of the width maths: a truncated prefix must fit
            // the space it is given, or the row runs past the terminal.
            try testing.expect(got <= n);
            try testing.expect(got <= full);
            // Asking for one more cell must never yield less than before.
            try testing.expect(got >= prev);
            prev = got;
        }
        // With the full budget available, nothing is lost.
        try testing.expectEqual(full, width(truncate(s, full)));
    }
}

test "padRight writes the text first, then the padding" {
    // Regression: an earlier version wrote the padding before the text, so
    // `padRight(buf, "find [query]", 22)` produced 26 cells and every column to
    // its right shifted.
    var buf: [64]u8 = undefined;
    const got = padRight(&buf, "find [query]", 22);
    try testing.expectEqualStrings("find [query]          ", got);
    try testing.expectEqual(@as(usize, 22), width(got));
}

test "padRight accounts for wide glyphs" {
    var buf: [64]u8 = undefined;
    // Two glyphs of two cells each leaves two cells of padding, not four.
    const got = padRight(&buf, "\u{65E5}\u{672C}", 6);
    try testing.expectEqual(@as(usize, 6), width(got));
    try testing.expectEqualStrings("\u{65E5}\u{672C}  ", got);
}

test "padRight leaves already-wide text alone" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("toolong", padRight(&buf, "toolong", 3));
}

test "padRight never overruns the scratch buffer" {
    var buf: [8]u8 = undefined;
    const got = padRight(&buf, "ab", 64);
    try testing.expect(got.len <= buf.len);
    try testing.expectEqualStrings("ab      ", got);
}

test "wrapLines collapses whitespace and pads to a fixed height" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try wrapLines(arena.allocator(), "  alpha    beta   gamma delta  ", 12, 4);
    try testing.expectEqual(@as(usize, 4), lines.len);
    for (lines) |l| try testing.expect(plainWidth(l) <= 12);
    try testing.expectEqualStrings("alpha beta", lines[0]);
    // Trailing lines are empty so the pane height never jumps.
    try testing.expectEqualStrings("", lines[lines.len - 1]);
}

test "wrapLines breaks on word boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try wrapLines(arena.allocator(), "alpha beta gamma", 10, 4);
    for (lines) |l| try testing.expect(plainWidth(l) <= 10);
    try testing.expectEqualStrings("alpha beta", lines[0]);
    try testing.expectEqualStrings("gamma", lines[1]);
}

test "wrapLines ellipsises the last line when text overflows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try wrapLines(arena.allocator(), "one two three four five six seven eight nine ten", 10, 2);
    try testing.expectEqual(@as(usize, 2), lines.len);
    for (lines) |l| try testing.expect(plainWidth(l) <= 10);
    try testing.expect(std.mem.endsWith(u8, lines[1], "\u{2026}"));
}

test "wrapLines counts cells for wide glyphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Six CJK glyphs at 12 cells must fit on one line, not be cut mid-glyph.
    const lines = try wrapLines(arena.allocator(), "日本語日本語", 12, 3);
    try testing.expectEqualStrings("日本語日本語", lines[0]);
    for (lines) |l| try testing.expect(plainWidth(l) <= 12);
}

test "wrapLines handles empty input without allocating a line of junk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try wrapLines(arena.allocator(), "", 10, 3);
    try testing.expectEqual(@as(usize, 3), lines.len);
    for (lines) |l| try testing.expectEqualStrings("", l);
}

test "floorBoundary rounds down to a codepoint start" {
    const s = "a\u{65E5}b";
    // Byte 1 is the first byte of the CJK char, so it is already a boundary.
    try testing.expectEqual(@as(usize, 1), floorBoundary(s, 1));
    // Byte 2 is a continuation byte, so it rounds back to 1.
    try testing.expectEqual(@as(usize, 1), floorBoundary(s, 2));
    try testing.expectEqual(@as(usize, 4), floorBoundary(s, 4));
    try testing.expectEqual(@as(usize, 5), floorBoundary(s, 99));
}
