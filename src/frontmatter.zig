//! Minimal YAML frontmatter reader for `SKILL.md`.
//!
//! Deliberately not a general YAML parser. It understands exactly the shape
//! that skill manifests use in the wild: flat `key: value` pairs, quoted
//! scalars, and the folded/literal block scalars that long descriptions are
//! written in. Anything else is preserved as a note rather than an error,
//! because a skill with unusual metadata should still show up in the list.

const std = @import("std");
const bufmod = @import("buf.zig");

pub const Meta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    license: []const u8 = "",
    version: []const u8 = "",
    /// Populated for `allowed-tools: A, B` style manifests.
    tools: []const u8 = "",
    has_frontmatter: bool = false,
    /// Non-fatal issues, e.g. "no frontmatter", "missing description".
    notes: []const []const u8 = &.{},
    key_count: usize = 0,
};

fn unquote(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2) {
        if ((t[0] == '"' and t[t.len - 1] == '"') or (t[0] == '\'' and t[t.len - 1] == '\'')) {
            return t[1 .. t.len - 1];
        }
    }
    return t;
}

/// Detects the first body paragraph, used as a description fallback so that
/// hand-written skills without frontmatter still get a readable summary.
fn firstParagraph(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "```")) continue;
        if (std.mem.startsWith(u8, line, ">")) continue;
        if (std.mem.startsWith(u8, line, "---")) continue;
        if (std.mem.startsWith(u8, line, "*") or std.mem.startsWith(u8, line, "-")) continue;
        return try allocator.dupe(u8, line);
    }
    return "";
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Meta {
    var meta = Meta{};
    var notes: std.ArrayList([]const u8) = .empty;
    errdefer notes.deinit(allocator);

    const trimmed_start = std.mem.trimStart(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed_start, "---")) {
        try notes.append(allocator, "no frontmatter block");
        meta.description = try firstParagraph(allocator, content);
        meta.notes = try notes.toOwnedSlice(allocator);
        return meta;
    }

    const after_open = trimmed_start[3..];
    const eol = std.mem.findScalar(u8, after_open, '\n') orelse {
        try notes.append(allocator, "unterminated frontmatter");
        meta.notes = try notes.toOwnedSlice(allocator);
        return meta;
    };
    const rest = after_open[eol + 1 ..];

    // Find the closing delimiter line.
    var close_at: ?usize = null;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...")) {
            close_at = offset;
            break;
        }
        offset += line.len + 1;
    }

    const block = if (close_at) |c| rest[0..c] else rest;
    const body = if (close_at) |c| rest[@min(c + 4, rest.len)..] else "";

    if (close_at == null) try notes.append(allocator, "unterminated frontmatter");
    meta.has_frontmatter = true;

    // Walk the block, resolving flat keys and block scalars.
    var key_buf = std.ArrayList(u8).empty;
    defer key_buf.deinit(allocator);
    var val_buf = std.ArrayList(u8).empty;
    defer val_buf.deinit(allocator);

    var current_key: []const u8 = "";
    var block_style: u8 = 0; // 0 = none, '>' fold, '|' literal

    const flush = struct {
        fn call(
            gpa: std.mem.Allocator,
            m: *Meta,
            key: []const u8,
            value: []const u8,
        ) !void {
            if (key.len == 0) return;
            const v = unquote(value);
            if (std.mem.eql(u8, key, "name")) m.name = try gpa.dupe(u8, v);
            if (std.mem.eql(u8, key, "description")) m.description = try gpa.dupe(u8, v);
            if (std.mem.eql(u8, key, "license")) m.license = try gpa.dupe(u8, v);
            if (std.mem.eql(u8, key, "version")) m.version = try gpa.dupe(u8, v);
            if (std.mem.eql(u8, key, "allowed-tools") or std.mem.eql(u8, key, "allowed_tools")) {
                m.tools = try gpa.dupe(u8, v);
            }
        }
    }.call;

    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (block_style != 0) try val_buf.append(allocator, '\n');
            continue;
        }
        const indent = line.len - std.mem.trimStart(u8, line, " ").len;
        const stripped = std.mem.trimStart(u8, line, " ");

        if (block_style != 0 and indent > 0) {
            if (val_buf.items.len > 0 and val_buf.items[val_buf.items.len - 1] != '\n') {
                if (block_style == '>') try val_buf.append(allocator, ' ');
            }
            try val_buf.appendSlice(allocator, stripped);
            continue;
        }

        if (block_style != 0) {
            try flush(allocator, &meta, current_key, val_buf.items);
            meta.key_count += 1;
            current_key = "";
            block_style = 0;
            val_buf.clearRetainingCapacity();
        }

        if (stripped.len == 0 or stripped[0] == '#') continue;
        const colon = std.mem.findScalar(u8, stripped, ':') orelse {
            if (current_key.len > 0) {
                if (val_buf.items.len > 0) try val_buf.append(allocator, ' ');
                try val_buf.appendSlice(allocator, stripped);
            }
            continue;
        };
        const key = std.mem.trim(u8, stripped[0..colon], " \t");
        const value = std.mem.trim(u8, stripped[colon + 1 ..], " \t");

        key_buf.clearRetainingCapacity();
        try key_buf.appendSlice(allocator, key);

        if (indent > 0) {
            // Nested key: keep it but expose it as a dotted-ish field name.
            if (std.mem.eql(u8, key_buf.items, "version") and meta.version.len == 0) {
                meta.version = try allocator.dupe(u8, unquote(value));
                meta.key_count += 1;
            }
            continue;
        }

        if (std.mem.eql(u8, value, ">") or std.mem.eql(u8, value, ">-") or
            std.mem.eql(u8, value, ">+") or std.mem.eql(u8, value, "|") or
            std.mem.eql(u8, value, "|-") or std.mem.eql(u8, value, "|+"))
        {
            current_key = try allocator.dupe(u8, key_buf.items);
            block_style = if (value[0] == '>') '>' else '|';
            val_buf.clearRetainingCapacity();
            continue;
        }

        if (std.mem.eql(u8, key, "metadata")) continue;

        try flush(allocator, &meta, key_buf.items, value);
        meta.key_count += 1;
        current_key = try allocator.dupe(u8, key_buf.items);
        val_buf.clearRetainingCapacity();
        try val_buf.appendSlice(allocator, unquote(value));
    }

    if (block_style != 0) {
        try flush(allocator, &meta, current_key, val_buf.items);
        meta.key_count += 1;
    }

    meta.description = std.mem.trim(u8, meta.description, " \t\n");
    if (meta.description.len == 0) {
        meta.description = try firstParagraph(allocator, body);
        if (meta.description.len > 0) try notes.append(allocator, "description inferred from body") else try notes.append(allocator, "no description");
    }
    if (meta.name.len == 0) try notes.append(allocator, "no name in frontmatter");

    meta.notes = try notes.toOwnedSlice(allocator);
    return meta;
}

/// Renders a scaffold `SKILL.md`, matching the shape produced by `skills init`.
pub fn scaffold(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
) ![]u8 {
    var b = bufmod.Buf.init(allocator);
    errdefer b.deinit();
    b.add("---\n");
    b.addFmt("name: {s}\n", .{name});
    if (description.len == 0) {
        b.add("description: >-\n  Describe when this skill should be used, and what it\n  does in practice.\n");
    } else {
        b.addFmt("description: {s}\n", .{description});
    }
    b.add("license: MIT\n");
    b.add("---\n\n");
    b.addFmt("# {s}\n\n", .{name});
    b.add("## When to use\n\n");
    b.add("- <describe the trigger conditions>\n\n");
    b.add("## How it works\n\n");
    b.add("1. <step one>\n2. <step two>\n\n");
    b.add("## References\n\n");
    b.add("- `references/` for deep material that should not be loaded by default\n");
    return b.toOwnedSlice();
}
