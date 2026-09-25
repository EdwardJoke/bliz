//! Key-script parser.
//!
//! A tiny DSL that turns readable tokens into the exact byte sequences a
//! terminal would deliver. It exists so `bliz record` can drive the prompt
//! deterministically — the recorded demo is produced by the same input path as
//! a real session, not by a separate mock.
//!
//! Tokens are separated by `;`:
//!   down up left right tab home end pgup pgdn
//!   space enter esc backspace clear all
//!   type:<text>          literal text (typed one codepoint at a time)
//!   wait:<ms>            hold before the next token

const std = @import("std");

pub const Token = struct {
    bytes: []const u8,
    /// Milliseconds to hold after applying this token.
    wait_ms: i64 = 120,
    label: []const u8 = "",
};

const key_bytes = struct {
    const up = "\x1b[A";
    const down = "\x1b[B";
    const right = "\x1b[C";
    const left = "\x1b[D";
    const home = "\x1b[H";
    const end = "\x1b[F";
    const pgup = "\x1b[5~";
    const pgdn = "\x1b[6~";
    const space = " ";
    const enter = "\r";
    const esc = "\x1b";
    const backspace = "\x7f";
    const clear = "\x15";
    const select_all = "\x01";
};

pub fn parse(arena: std.mem.Allocator, script: []const u8) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    var it = std.mem.splitScalar(u8, script, ';');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t\r\n");
        if (token.len == 0) continue;

        if (std.mem.startsWith(u8, token, "wait:")) {
            const ms = std.fmt.parseInt(i64, token[5..], 10) catch 120;
            try out.append(arena, .{ .bytes = "", .wait_ms = ms, .label = "wait" });
            continue;
        }
        if (std.mem.startsWith(u8, token, "type:")) {
            // Emitted as one chunk: the prompt appends every byte, so a single
            // write is indistinguishable from fast typing.
            try out.append(arena, .{ .bytes = token[5..], .wait_ms = 180, .label = token[0..token.len] });
            continue;
        }

        const Entry = struct { name: []const u8, bytes: []const u8, wait: i64 };
        const table = [_]Entry{
            .{ .name = "down", .bytes = key_bytes.down, .wait = 110 },
            .{ .name = "up", .bytes = key_bytes.up, .wait = 110 },
            .{ .name = "left", .bytes = key_bytes.left, .wait = 220 },
            .{ .name = "right", .bytes = key_bytes.right, .wait = 220 },
            .{ .name = "tab", .bytes = "\x09", .wait = 200 },
            .{ .name = "home", .bytes = key_bytes.home, .wait = 200 },
            .{ .name = "end", .bytes = key_bytes.end, .wait = 200 },
            .{ .name = "pgup", .bytes = key_bytes.pgup, .wait = 200 },
            .{ .name = "pgdn", .bytes = key_bytes.pgdn, .wait = 200 },
            .{ .name = "space", .bytes = key_bytes.space, .wait = 260 },
            .{ .name = "enter", .bytes = key_bytes.enter, .wait = 420 },
            .{ .name = "esc", .bytes = key_bytes.esc, .wait = 220 },
            .{ .name = "backspace", .bytes = key_bytes.backspace, .wait = 140 },
            .{ .name = "clear", .bytes = key_bytes.clear, .wait = 220 },
            .{ .name = "all", .bytes = key_bytes.select_all, .wait = 320 },
        };
        var matched = false;
        for (table) |e| {
            if (std.mem.eql(u8, e.name, token)) {
                try out.append(arena, .{ .bytes = e.bytes, .wait_ms = e.wait, .label = e.name });
                matched = true;
                break;
            }
        }
        if (!matched) {
            // Unknown token: treat it as literal text so typos still do something.
            try out.append(arena, .{ .bytes = token, .wait_ms = 160, .label = token });
        }
    }
    return out.toOwnedSlice(arena);
}

test "parses mixed tokens" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tokens = try parse(arena.allocator(), "down; space; type:cl; wait:300; esc");
    try testing.expectEqual(@as(usize, 5), tokens.len);
    try testing.expectEqualStrings("\x1b[B", tokens[0].bytes);
    try testing.expectEqualStrings("cl", tokens[2].bytes);
    try testing.expectEqual(@as(i64, 300), tokens[3].wait_ms);
}
