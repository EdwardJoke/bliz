//! Skill discovery.
//!
//! Discovery is split into two phases so the UI can animate over real work
//! instead of faking a spinner:
//!
//!   1. `buildRoots` resolves every agent's skills directory to a concrete
//!      path and tells you which ones actually exist.
//!   2. `scanRoot` reads one root and returns the skills inside it.
//!
//! The prompt then drains roots a few at a time, so its progress counter is a
//! real count of directories visited.

const std = @import("std");
const registry = @import("registry.zig");
const frontmatter = @import("frontmatter.zig");

pub const Scope = enum {
    project,
    global,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .project => "project",
            .global => "global",
        };
    }
};

pub const RootCandidate = struct {
    path: []const u8,
    /// Shortened, human-facing form of `path`.
    display: []const u8,
    /// Display names of every agent that uses this directory.
    agents: []const []const u8,
    scope: Scope,
    tier: registry.Tier,
    exists: bool,
    /// Skills found here, filled in by `scanRoot`.
    skills: []Skill = &.{},
    scanned: bool = false,

    /// Group heading: a single agent name, or "First +N" for shared hubs.
    pub fn label(self: *const RootCandidate, out: []u8) []const u8 {
        if (self.agents.len == 0) return std.fs.path.basename(self.path);
        if (self.agents.len == 1) return self.agents[0];
        return std.fmt.bufPrint(out, "{s} +{d}", .{ self.agents[0], self.agents.len - 1 }) catch self.agents[0];
    }
};

pub const Skill = struct {
    /// Directory name — the stable identity used by remove/update.
    name: []const u8,
    /// `name:` from frontmatter when present and different from the directory.
    title: []const u8 = "",
    description: []const u8 = "",
    license: []const u8 = "",
    version: []const u8 = "",
    dir: []const u8,
    display_dir: []const u8,
    scope: Scope,
    root_index: usize = 0,
    mtime_ms: i64 = 0,
    bytes: u64 = 0,
    files: usize = 0,
    /// Notable subdirectories, e.g. "references, scripts".
    extras: []const u8 = "",
    has_frontmatter: bool = false,
    /// Set when the skill lives one level below the root (nested container).
    container: []const u8 = "",

    pub fn hasDescription(self: *const Skill) bool {
        return self.description.len > 0;
    }
};

pub const Scan = struct {
    skills: []Skill,
    roots: []RootCandidate,
    roots_present: usize,
    roots_scanned: usize,
    errors: []const []const u8,
};

/// Replaces a cwd prefix with `.` and a home prefix with `~`. Project paths win
/// over home paths because a relative path is far more readable once you are
/// already inside the project.
pub fn shortenPath(allocator: std.mem.Allocator, path: []const u8, home: []const u8, cwd: []const u8) []const u8 {
    if (cwd.len > 0 and !std.mem.eql(u8, cwd, "/") and std.mem.startsWith(u8, path, cwd)) {
        return std.fmt.allocPrint(allocator, ".{s}", .{path[cwd.len..]}) catch path;
    }
    if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
        return std.fmt.allocPrint(allocator, "~{s}", .{path[home.len..]}) catch path;
    }
    return path;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// Resolves every agent directory for the requested scopes into concrete
/// roots, merging agents that share a directory.
pub fn buildRoots(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    scopes: []const Scope,
) ![]RootCandidate {
    var roots: std.ArrayList(RootCandidate) = .empty;
    errdefer roots.deinit(arena);

    for (scopes) |scope| {
        for (registry.agents) |agent| {
            const template = switch (scope) {
                .project => agent.project,
                .global => agent.global,
            };
            if (template.len == 0) continue;

            const resolved = if (scope == .project)
                try std.fs.path.join(arena, &.{ cwd, template })
            else
                try registry.expand(arena, template, env);

            // Merge into an existing root with the same path.
            var merged = false;
            for (roots.items) |*existing| {
                if (existing.scope == scope and std.mem.eql(u8, existing.path, resolved)) {
                    var list: std.ArrayList([]const u8) = .empty;
                    try list.appendSlice(arena, existing.agents);
                    try list.append(arena, agent.display);
                    existing.agents = try list.toOwnedSlice(arena);
                    merged = true;
                    break;
                }
            }
            if (merged) continue;

            var one: std.ArrayList([]const u8) = .empty;
            try one.append(arena, agent.display);

            const home = env.get("HOME") orelse "";
            try roots.append(arena, .{
                .path = resolved,
                .display = shortenPath(arena, resolved, home, cwd),
                .agents = try one.toOwnedSlice(arena),
                .scope = scope,
                .tier = agent.tier,
                .exists = false,
            });
        }
    }

    // Probe existence once per root.
    for (roots.items) |*root| {
        root.exists = dirExists(io, root.path);
    }

    // Order: project before global, then tier, then label.
    std.mem.sort(RootCandidate, roots.items, {}, struct {
        fn lt(_: void, a: RootCandidate, b: RootCandidate) bool {
            if (a.exists != b.exists) return a.exists;
            if (a.scope != b.scope) return a.scope == .project;
            if (a.tier != b.tier) return @intFromEnum(a.tier) < @intFromEnum(b.tier);
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    return roots.toOwnedSlice(arena);
}

const notable_dirs = [_][]const u8{ "references", "scripts", "assets", "templates", "examples", "docs" };

fn probeExtras(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (notable_dirs) |name| {
        var sub = dir.openDir(io, name, .{}) catch continue;
        sub.close(io);
        found.append(arena, name) catch {};
    }
    if (found.items.len == 0) return "";
    return std.mem.join(arena, ", ", found.items) catch "";
}

fn countFiles(dir: std.Io.Dir, io: std.Io) usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file) n += 1;
    }
    return n;
}

fn readSkillMeta(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    errors: *std.ArrayList([]const u8),
    dir_display: []const u8,
) ?frontmatter.Meta {
    const content = dir.readFileAlloc(io, "SKILL.md", gpa, .limited(512 * 1024)) catch |err| {
        errors.append(arena, std.fmt.allocPrint(arena, "{s}: SKILL.md unreadable ({t})", .{ dir_display, err }) catch "read error") catch {};
        return null;
    };
    defer gpa.free(content);
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        errors.append(arena, std.fmt.allocPrint(arena, "{s}: SKILL.md is empty", .{dir_display}) catch "empty") catch {};
        return null;
    }
    return frontmatter.parse(arena, content) catch null;
}

fn makeSkill(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    scope: Scope,
    root_index: usize,
    dir: std.Io.Dir,
    dir_abs: []const u8,
    dir_display: []const u8,
    name: []const u8,
    container: []const u8,
    errors: *std.ArrayList([]const u8),
) !?Skill {
    // Directory-entry names point into the iterator's scratch buffer, which is
    // reused by the next `next()` call, so the name is copied before any
    // further I/O happens.
    const owned_name = try arena.dupe(u8, name);

    const meta_opt = readSkillMeta(arena, io, gpa, dir, errors, dir_display);
    if (meta_opt == null) return null;
    const meta = meta_opt.?;

    var mtime_ms: i64 = 0;
    var bytes: u64 = 0;
    if (dir.statFile(io, "SKILL.md", .{})) |st| {
        mtime_ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
        bytes = st.size;
    } else |_| {}

    return Skill{
        .name = owned_name,
        .title = if (meta.name.len > 0 and !std.mem.eql(u8, meta.name, owned_name)) meta.name else "",
        .description = meta.description,
        .license = meta.license,
        .version = meta.version,
        .dir = dir_abs,
        .display_dir = dir_display,
        .scope = scope,
        .root_index = root_index,
        .mtime_ms = mtime_ms,
        .bytes = bytes,
        .files = countFiles(dir, io),
        .extras = probeExtras(arena, io, dir),
        .has_frontmatter = meta.has_frontmatter,
        .container = container,
    };
}

/// Scans a single root. Handles three layouts:
///   * `<root>/<skill>/SKILL.md`             — the common case
///   * `<root>/<container>/<skill>/SKILL.md` — plugin/collection layouts
///   * `<root>/SKILL.md`                     — the root itself is one skill
pub fn scanRoot(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *RootCandidate,
    home: []const u8,
    cwd: []const u8,
    errors: *std.ArrayList([]const u8),
) !void {
    var found: std.ArrayList(Skill) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, root.path, .{ .iterate = true }) catch |err| {
        try errors.append(arena, std.fmt.allocPrint(arena, "{s}: cannot open ({t})", .{ root.display, err }) catch "open error");
        root.skills = &.{};
        root.scanned = true;
        return;
    };
    defer dir.close(io);

    // Root-is-a-skill layout.
    {
        var probe = std.Io.Dir.cwd().openDir(io, root.path, .{}) catch null;
        if (probe) |*p| {
            defer p.close(io);
            if (p.statFile(io, "SKILL.md", .{})) |_| {
                const base = std.fs.path.basename(root.path);
                const display = shortenPath(arena, root.path, home, cwd);
                if (try makeSkill(arena, io, gpa, root.scope, 0, p.*, root.path, display, base, "", errors)) |s| {
                    try found.append(arena, s);
                }
                root.skills = try found.toOwnedSlice(arena);
                root.scanned = true;
                return;
            } else |_| {}
        }
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const child_abs = try std.fs.path.join(arena, &.{ root.path, entry.name });
        const child_display = shortenPath(arena, child_abs, home, cwd);

        var child = std.Io.Dir.cwd().openDir(io, child_abs, .{ .iterate = true }) catch continue;
        defer child.close(io);

        if (child.statFile(io, "SKILL.md", .{})) |_| {
            if (try makeSkill(arena, io, gpa, root.scope, 0, child, child_abs, child_display, entry.name, "", errors)) |s| {
                try found.append(arena, s);
            }
            continue;
        } else |_| {}

        // Nested container: look exactly one level deeper.
        var sub_it = child.iterate();
        while (sub_it.next(io) catch null) |sub| {
            if (sub.kind != .directory) continue;
            if (sub.name.len == 0 or sub.name[0] == '.') continue;
            const sub_abs = try std.fs.path.join(arena, &.{ child_abs, sub.name });
            const sub_display = shortenPath(arena, sub_abs, home, cwd);
            var sub_dir = std.Io.Dir.cwd().openDir(io, sub_abs, .{}) catch continue;
            defer sub_dir.close(io);
            if (sub_dir.statFile(io, "SKILL.md", .{})) |_| {
                if (try makeSkill(arena, io, gpa, root.scope, 0, sub_dir, sub_abs, sub_display, sub.name, try arena.dupe(u8, entry.name), errors)) |s| {
                    try found.append(arena, s);
                }
            } else |_| {}
        }
    }

    std.mem.sort(Skill, found.items, {}, struct {
        fn lt(_: void, a: Skill, b: Skill) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    root.skills = try found.toOwnedSlice(arena);
    root.scanned = true;
}

/// Convenience wrapper that scans every existing root in one go.
pub fn scanAll(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    scopes: []const Scope,
) !Scan {
    var errors: std.ArrayList([]const u8) = .empty;
    const roots = try buildRoots(arena, io, env, cwd, scopes);
    const home = env.get("HOME") orelse "";

    var present: usize = 0;
    var scanned: usize = 0;
    for (roots) |*root| {
        if (!root.exists) continue;
        present += 1;
        try scanRoot(arena, io, gpa, root, home, cwd, &errors);
        scanned += 1;
    }

    // Flatten, preserving root order (project → global → tier → label).
    var all: std.ArrayList(Skill) = .empty;
    for (roots, 0..) |*root, idx| {
        for (root.skills) |s| {
            var copy = s;
            copy.root_index = idx;
            try all.append(arena, copy);
        }
    }

    return .{
        .skills = try all.toOwnedSlice(arena),
        .roots = roots,
        .roots_present = present,
        .roots_scanned = scanned,
        .errors = try errors.toOwnedSlice(arena),
    };
}

/// Human-friendly relative age used in hints and the detail pane.
pub fn ageLabel(allocator: std.mem.Allocator, mtime_ms: i64, now_ms: i64) []const u8 {
    if (mtime_ms <= 0) return "unknown";
    const delta = @max(0, now_ms - mtime_ms);
    const minutes = @divTrunc(delta, 60_000);
    const hours = @divTrunc(delta, 3_600_000);
    const days = @divTrunc(delta, 86_400_000);
    if (minutes < 1) return "just now";
    if (minutes < 60) return std.fmt.allocPrint(allocator, "{d}m ago", .{minutes}) catch "recently";
    if (hours < 24) return std.fmt.allocPrint(allocator, "{d}h ago", .{hours}) catch "recently";
    if (days < 60) return std.fmt.allocPrint(allocator, "{d}d ago", .{days}) catch "recently";
    return std.fmt.allocPrint(allocator, "{d}mo ago", .{@divTrunc(days, 30)}) catch "long ago";
}

pub fn humanBytes(allocator: std.mem.Allocator, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "";
    return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "";
}

/// Splits a description into sentences so the detail pane can show a compact
/// summary and still expose the full text.
pub fn sentenceCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c == '.' or c == '!' or c == '?') n += 1;
    }
    return if (n == 0 and text.len > 0) 1 else n;
}
