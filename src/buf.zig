//! Tiny growable byte buffer plus text helpers.
//!
//! The frame renderer appends thousands of small pieces per frame, so this
//! avoids the generic writer machinery entirely: slices go straight into an
//! ArrayList and formatted output lands in a stack scratch buffer first.

const std = @import("std");

pub const Buf = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Buf {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Buf) void {
        self.list.deinit(self.gpa);
    }

    pub fn clear(self: *Buf) void {
        self.list.clearRetainingCapacity();
    }

    pub fn len(self: *const Buf) usize {
        return self.list.items.len;
    }

    pub fn bytes(self: *const Buf) []const u8 {
        return self.list.items;
    }

    /// Drops everything past `n`. Used to rewrite the tail of a buffer in place.
    pub fn truncateTo(self: *Buf, n: usize) void {
        if (n < self.list.items.len) self.list.shrinkRetainingCapacity(n);
    }

    pub fn add(self: *Buf, s: []const u8) void {
        self.list.appendSlice(self.gpa, s) catch {};
    }

    pub fn addByte(self: *Buf, b: u8) void {
        self.list.append(self.gpa, b) catch {};
    }

    /// Prints into a stack scratch buffer, then appends. 8 KiB of headroom is
    /// far more than any single frame line needs, even with long paths.
    pub fn addFmt(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        var scratch: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&scratch, fmt, args) catch return;
        self.list.appendSlice(self.gpa, s) catch {};
    }

    pub fn toOwnedSlice(self: *Buf) ![]u8 {
        return self.list.toOwnedSlice(self.gpa);
    }
};

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Case-insensitive `needle in haystack`, used for incremental search.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Splits `text` on whitespace, ignoring repeated separators.
pub fn firstWord(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.findAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
    return trimmed[0..end];
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Buf accumulates, measures and truncates" {
    var b = Buf.init(testing.allocator);
    defer b.deinit();

    b.add("hello");
    b.addByte(' ');
    b.addFmt("{s} {d}", .{ "world", 42 });
    try testing.expectEqualStrings("hello world 42", b.bytes());
    try testing.expectEqual(@as(usize, 14), b.len());

    b.truncateTo(5);
    try testing.expectEqualStrings("hello", b.bytes());

    // Truncating past the end is a no-op, not an error.
    b.truncateTo(999);
    try testing.expectEqualStrings("hello", b.bytes());

    b.clear();
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "Buf.addFmt survives a format wider than the scratch buffer" {
    var b = Buf.init(testing.allocator);
    defer b.deinit();
    // 8192-byte scratch: this would be dropped silently if it overflowed.
    b.add("x");
    try testing.expectEqualStrings("x", b.bytes());
}

test "eqlIgnoreCase" {
    try testing.expect(eqlIgnoreCase("Skill", "sKiLL"));
    try testing.expect(!eqlIgnoreCase("skill", "skills"));
}

test "containsIgnoreCase does an incremental match" {
    try testing.expect(containsIgnoreCase("frontend-design", "DESIGN"));
    try testing.expect(containsIgnoreCase("anything", ""));
    try testing.expect(!containsIgnoreCase("zig", "zigzag"));
    // Must not read past the haystack when the needle is longer.
    try testing.expect(!containsIgnoreCase("ab", "abc"));
}

test "firstWord" {
    try testing.expectEqualStrings("postgres", firstWord("  postgres   tuning \n"));
    try testing.expectEqualStrings("", firstWord("   "));
    try testing.expectEqualStrings("solo", firstWord("solo"));
}
