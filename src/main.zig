//! bliz — a skill manager for the open agent-skills ecosystem, in Zig.
//!
//! Commands mirror the reference tool's surface (`list`, `find`, `init`,
//! `remove`) and add `stats` plus a `record` mode that captures real frames for
//! the web player. The interactive prompt is the centrepiece: see `tui.zig`.

const std = @import("std");
const term = @import("term.zig");
const style = @import("style.zig");
const width = @import("width.zig");
const bufmod = @import("buf.zig");
const discover = @import("discover.zig");
const registry = @import("registry.zig");
const frontmatter = @import("frontmatter.zig");
const install = @import("install.zig");
const tui = @import("tui.zig");
const pick = @import("pick.zig");
const record = @import("record.zig");

const version = "0.4.0";

var scratch: [16]u8 = undefined;

const Context = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    /// Directory holding the running executable, resolved. Lets assets that ship
    /// with the repo (`demo/player.template.html`) be found even when the command
    /// runs from some unrelated working directory.
    exe_dir: []const u8,
    out: *term.Out,
    args: []const [:0]const u8,

    fn flag(self: *Context, name: []const u8) bool {
        for (self.args) |a| {
            if (std.mem.eql(u8, a, name)) return true;
        }
        return false;
    }

    /// Value following `name`, or null.
    fn value(self: *Context, name: []const u8) ?[]const u8 {
        for (self.args, 0..) |a, i| {
            if (std.mem.eql(u8, a, name) and i + 1 < self.args.len) return self.args[i + 1];
        }
        return null;
    }

    /// Every value given for a repeatable flag, e.g. `-a claude-code -a cursor`
    /// or `--agent claude-code --agent cursor`.
    fn values(self: *Context, names: []const []const u8) [][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < self.args.len) : (i += 1) {
            for (names) |n| {
                if (std.mem.eql(u8, self.args[i], n) and i + 1 < self.args.len) {
                    out.append(self.arena, self.args[i + 1]) catch {};
                    break;
                }
            }
        }
        return out.items;
    }

    /// Operands: everything after the command token that is not a flag or a
    /// flag's value. `args[0]` is always the command itself, so it is skipped.
    fn positionals(self: *Context) [][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (i < self.args.len) : (i += 1) {
            const a = self.args[i];
            if (a.len > 1 and a[0] == '-') {
                if (takesValue(a) and i + 1 < self.args.len) i += 1;
                continue;
            }
            out.append(self.arena, a) catch {};
        }
        return out.items;
    }
};

fn takesValue(flag: []const u8) bool {
    const with_value = [_][]const u8{
        "--agent",       "-a",         "--scope", "--cols",     "--rows",
        "--out",         "--script",   "--message", "--root",   "--label",
        "--description", "--dir",      "--title", "--html",     "--template",
        "--skill",       "-s",         "--ref",
    };
    for (with_value) |f| {
        if (std.mem.eql(u8, flag, f)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var outbuf: [1 << 17]u8 = undefined;
    var out = term.Out.init(&outbuf);

    const args = try std.process.Args.toSlice(init.minimal.args, arena);
    const cwd = try std.process.currentPathAlloc(init.io, arena);

    // `zig-out/bin/bliz` → the repo root sits two levels up. Both this and the
    // bare cwd are used to locate the player template.
    const exe_dir = blk: {
        if (args.len == 0) break :blk cwd;
        const dir = std.fs.path.dirname(args[0]) orelse break :blk cwd;
        if (dir.len == 0) break :blk cwd;
        break :blk std.fs.path.resolve(arena, &.{ cwd, dir }) catch cwd;
    };

    var ctx = Context{
        .arena = arena,
        .gpa = init.gpa,
        .io = init.io,
        .env = init.environ_map,
        .cwd = cwd,
        .exe_dir = exe_dir,
        .out = &out,
        .args = if (args.len > 1) args[1..] else &.{},
    };

    const code = dispatch(&ctx) catch |err| {
        ctx.out.flush();
        // User-facing conditions already printed a message; report them as a
        // plain exit code instead of dumping an internal stack trace.
        switch (err) {
            error.NothingSelected, error.SkillNotFound, error.UnknownAgent, error.ProjectOnly, error.FrameInvariant, error.UnknownSource, error.SourceNotFound, error.GitNotFound, error.GitFailed, error.InstallFailed => {
                std.process.exit(1);
            },
            else => {
                std.debug.print("error: {t}\n", .{err});
                std.process.exit(1);
            },
        }
    };
    ctx.out.flush();
    if (code != 0) std.process.exit(code);
}

fn dispatch(ctx: *Context) !u8 {
    if (ctx.args.len == 0) {
        try cmdHelp(ctx);
        return 0;
    }
    const cmd = ctx.args[0];
    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        try cmdList(ctx);
    } else if (std.mem.eql(u8, cmd, "find") or std.mem.eql(u8, cmd, "browse")) {
        try cmdFind(ctx);
    } else if (std.mem.eql(u8, cmd, "inspect") or std.mem.eql(u8, cmd, "show")) {
        try cmdInspect(ctx);
    } else if (std.mem.eql(u8, cmd, "init") or std.mem.eql(u8, cmd, "create")) {
        try cmdInit(ctx);
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm")) {
        try cmdRemove(ctx);
    } else if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "add")) {
        try cmdInstall(ctx);
    } else if (std.mem.eql(u8, cmd, "stats")) {
        try cmdStats(ctx);
    } else if (std.mem.eql(u8, cmd, "agents")) {
        try cmdAgents(ctx);
    } else if (std.mem.eql(u8, cmd, "record")) {
        try cmdRecord(ctx);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try cmdHelp(ctx);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        ctx.out.writeAll(version);
        ctx.out.writeAll("\n");
    } else {
        ctx.out.writeAll(style.AMBER);
        ctx.out.writeAll("unknown command: ");
        ctx.out.writeAll(cmd);
        ctx.out.writeAll(term.RESET);
        ctx.out.writeAll("\n\n");
        try cmdHelp(ctx);
        return 1;
    }
    return 0;
}

fn scopesFrom(ctx: *Context) []const discover.Scope {
    if (ctx.flag("-g") or ctx.flag("--global")) return &.{.global};
    if (ctx.flag("-p") or ctx.flag("--project")) return &.{.project};
    if (ctx.value("--scope")) |s| {
        if (std.mem.eql(u8, s, "global")) return &.{.global};
        if (std.mem.eql(u8, s, "project")) return &.{.project};
    }
    return &.{ .project, .global };
}

/// Adds extra scan roots given with `--root`, for collections that do not live
/// in a standard agent directory.
fn withExtraRoots(
    ctx: *Context,
    arena: std.mem.Allocator,
    base: []discover.RootCandidate,
) ![]discover.RootCandidate {
    var list: std.ArrayList(discover.RootCandidate) = .empty;
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        if (!std.mem.eql(u8, ctx.args[i], "--root")) continue;
        if (i + 1 >= ctx.args.len) break;
        const path = ctx.args[i + 1];
        const abs = if (std.fs.path.isAbsolute(path))
            try arena.dupe(u8, path)
        else
            try std.fs.path.join(arena, &.{ ctx.cwd, path });
        var one: std.ArrayList([]const u8) = .empty;
        try one.append(arena, ctx.value("--label") orelse "custom");
        try list.append(arena, .{
            .path = abs,
            .display = discover.shortenPath(arena, abs, ctx.env.get("HOME") orelse "", ctx.cwd),
            .agents = try one.toOwnedSlice(arena),
            .scope = .project,
            .tier = .hub,
            .exists = true,
        });
    }
    for (base) |r| try list.append(arena, r);
    return list.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

fn cmdList(ctx: *Context) !void {
    const scopes = scopesFrom(ctx);
    const scan = try discover.scanAll(ctx.arena, ctx.io, ctx.gpa, ctx.cwd, ctx.env, scopes);
    const o = ctx.out;

    if (ctx.flag("--json")) {
        writeJson(ctx, scan);
        return;
    }

    o.writeAll(term.BOLD);
    o.writeAll(style.mixAt(&scratch, 245, 255, 1.0));
    o.writeAll("Skills");
    o.writeAll(term.RESET);
    o.writeAll(style.DIM);
    o.writeAll("  ");
    o.writeAll(if (scopes.len == 1) scopes[0].label() else "all scopes");
    o.writeAll(term.RESET);
    o.writeAll("\n\n");

    if (scan.skills.len == 0) {
        o.writeAll(style.DIM);
        o.writeAll("No skills found.\n");
        o.writeAll(style.FAINT);
        o.writeAll("Try `bliz init my-skill` to create one.\n");
        o.writeAll(term.RESET);
        return;
    }

    var name_width: usize = 0;
    for (scan.skills) |s| name_width = @max(name_width, width.width(s.name));
    name_width = @min(name_width, 30);

    var current_root: ?usize = null;
    for (scan.skills) |s| {
        if (current_root == null or current_root.? != s.root_index) {
            if (current_root != null) o.writeAll("\n");
            current_root = s.root_index;
            const root = scan.roots[s.root_index];
            var lbuf: [160]u8 = undefined;
            o.writeAll(style.mixAt(&scratch, 238, 245, 0.9));
            o.writeAll(root.label(&lbuf));
            o.writeAll(term.RESET);
            o.writeAll(style.GHOST);
            o.writeAll("  ");
            o.writeAll(root.display);
            o.writeAll(term.RESET);
            o.writeAll("\n");
        }
        printSkillLine(ctx, s, name_width);
    }

    o.writeAll("\n");
    var buf: [192]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "{d} skill{s} in {d} root{s}{s}\n", .{
        scan.skills.len,
        if (scan.skills.len == 1) "" else "s",
        scan.roots_present,
        if (scan.roots_present == 1) "" else "s",
        if (scan.errors.len > 0) " · some directories could not be read" else "",
    }) catch "";
    o.writeAll(style.FAINT);
    o.writeAll(summary);
    o.writeAll(term.RESET);
}

fn printSkillLine(ctx: *Context, s: discover.Skill, name_width: usize) void {
    var padbuf: [512]u8 = undefined;
    const o = ctx.out;
    o.writeAll("  ");
    o.writeAll(style.mixAt(&scratch, 240, 252, 0.92));
    o.writeAll(width.padRight(&padbuf, s.name, name_width));
    o.writeAll(term.RESET);
    o.writeAll("  ");
    o.writeAll(style.GHOST);
    o.writeAll(s.display_dir);
    o.writeAll(term.RESET);
    o.writeAll("\n    ");
    o.writeAll(style.FAINT);
    o.writeAll(if (s.description.len > 0) s.description else "no description");
    o.writeAll(term.RESET);
    if (!s.has_frontmatter) {
        o.writeAll("  ");
        o.writeAll(style.AMBER);
        o.writeAll("no frontmatter");
        o.writeAll(term.RESET);
    }
    if (s.extras.len > 0) {
        o.writeAll("  ");
        o.writeAll(style.GHOST);
        o.writeAll("[");
        o.writeAll(s.extras);
        o.writeAll("]");
        o.writeAll(term.RESET);
    }
    o.writeAll("\n");
}

fn writeJson(ctx: *Context, scan: discover.Scan) void {
    var b = bufmod.Buf.init(ctx.arena);
    b.add("[\n");
    for (scan.skills, 0..) |s, i| {
        if (i > 0) b.add(",\n");
        b.add("  { \"name\": ");
        jsonStr(&b, s.name);
        b.add(", \"description\": ");
        jsonStr(&b, s.description);
        b.add(", \"path\": ");
        jsonStr(&b, s.dir);
        b.add(", \"scope\": ");
        jsonStr(&b, s.scope.label());
        b.add(", \"root\": ");
        jsonStr(&b, scan.roots[s.root_index].display);
        b.addFmt(", \"files\": {d}, \"license\": ", .{s.files});
        jsonStr(&b, s.license);
        b.addFmt(", \"hasFrontmatter\": {s} }}", .{if (s.has_frontmatter) "true" else "false"});
    }
    b.add("\n]\n");
    ctx.out.writeAll(b.bytes());
}

fn jsonStr(b: *bufmod.Buf, s: []const u8) void {
    b.addByte('"');
    for (s) |c| {
        switch (c) {
            '"' => b.add("\\\""),
            '\\' => b.add("\\\\"),
            '\n' => b.add("\\n"),
            '\r' => b.add("\\r"),
            '\t' => b.add("\\t"),
            else => {
                if (c < 0x20) b.addFmt("\\u{x:0>4}", .{c}) else b.addByte(c);
            },
        }
    }
    b.addByte('"');
}

// ---------------------------------------------------------------------------
// find
// ---------------------------------------------------------------------------

fn cmdFind(ctx: *Context) !void {
    const scopes = scopesFrom(ctx);
    const base = try discover.buildRoots(ctx.arena, ctx.io, ctx.env, ctx.cwd, scopes);
    const roots = try withExtraRoots(ctx, ctx.arena, base);

    // Without a TTY (pipes, CI) there is no interactive prompt to drive, so
    // fall back to the static listing instead of hanging on stdin.
    if (!term.stdinIsTty() or !term.stdoutIsTty()) {
        return cmdList(ctx);
    }

    const opts = tui.Options{
        .message = ctx.value("--message") orelse "Select skills",
        .badge = if (scopes.len == 1) scopes[0].label() else "all scopes",
        .detail_lines = 3,
        .select_all = !ctx.flag("--no-select-all"),
        .require_selection = ctx.flag("--required"),
        .initial_query = if (ctx.positionals().len > 0) ctx.positionals()[0] else "",
    };

    const result = try tui.run(
        ctx.arena,
        ctx.gpa,
        ctx.io,
        ctx.env,
        roots,
        opts,
        ctx.out,
        term.supportsSyncOutput(ctx.env) and !term.envTrue(ctx.env, "NO_SYNC"),
        ctx.cwd,
    );

    switch (result.outcome) {
        .cancelled => return error.NothingSelected,
        .submitted => |indices| {
            printSelection(ctx, result.skills, indices);
            if (indices.len == 0) return error.NothingSelected;
        },
    }
}

fn printSelection(ctx: *Context, skills: []discover.Skill, indices: []const usize) void {
    const o = ctx.out;
    o.writeAll("\n");
    for (indices) |i| {
        o.writeAll(style.GREEN);
        o.writeAll("  ✓ ");
        o.writeAll(term.RESET);
        o.writeAll(style.mixAt(&scratch, 244, 252, 1.0));
        o.writeAll(skills[i].name);
        o.writeAll(term.RESET);
        o.writeAll(style.GHOST);
        o.writeAll("  ");
        o.writeAll(skills[i].display_dir);
        o.writeAll(term.RESET);
        o.writeAll("\n");
    }
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {d} skill{s} selected\n", .{
        indices.len,
        if (indices.len == 1) "" else "s",
    }) catch "";
    o.writeAll(style.FAINT);
    o.writeAll(line);
    o.writeAll(term.RESET);
}

// ---------------------------------------------------------------------------
// inspect
// ---------------------------------------------------------------------------

fn cmdInspect(ctx: *Context) !void {
    const positionals = ctx.positionals();
    if (positionals.len == 0) {
        ctx.out.writeAll("usage: bliz inspect <name>\n");
        return error.SkillNotFound;
    }
    const needle = positionals[0];
    const scopes = scopesFrom(ctx);
    const scan = try discover.scanAll(ctx.arena, ctx.io, ctx.gpa, ctx.cwd, ctx.env, scopes);
    const o = ctx.out;

    var found: ?discover.Skill = null;
    for (scan.skills) |s| {
        if (std.mem.eql(u8, s.name, needle)) {
            found = s;
            break;
        }
    }
    if (found == null) {
        o.writeAll(style.AMBER);
        o.writeAll("no skill named ");
        o.writeAll(needle);
        o.writeAll(term.RESET);
        o.writeAll("\n");
        return error.SkillNotFound;
    }
    const s = found.?;

    o.writeAll(term.BOLD);
    o.writeAll(style.mixAt(&scratch, 245, 255, 1.0));
    o.writeAll(s.name);
    o.writeAll(term.RESET);
    if (s.title.len > 0) {
        o.writeAll(style.DIM);
        o.writeAll("  ");
        o.writeAll(s.title);
        o.writeAll(term.RESET);
    }
    o.writeAll("\n\n");

    const rows = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "path", .v = s.dir },
        .{ .k = "scope", .v = s.scope.label() },
        .{ .k = "license", .v = if (s.license.len > 0) s.license else "—" },
        .{ .k = "version", .v = if (s.version.len > 0) s.version else "—" },
        .{ .k = "bundles", .v = if (s.extras.len > 0) s.extras else "—" },
    };
    for (rows) |r| {
        var padbuf: [256]u8 = undefined;
        o.writeAll(style.GHOST);
        o.writeAll(width.padRight(&padbuf, r.k, 9));
        o.writeAll(term.RESET);
        o.writeAll(style.mixAt(&scratch, 238, 247, 0.95));
        o.writeAll(r.v);
        o.writeAll(term.RESET);
        o.writeAll("\n");
    }

    var nbuf: [96]u8 = undefined;
    const meta = std.fmt.bufPrint(&nbuf, "{d} file{s} · {d} bytes · updated {s}", .{
        s.files,
        if (s.files == 1) "" else "s",
        s.bytes,
        discover.ageLabel(ctx.arena, s.mtime_ms, term.wallMs(ctx.io)),
    }) catch "";
    o.writeAll(style.FAINT);
    o.writeAll(meta);
    o.writeAll(term.RESET);
    o.writeAll("\n\n");

    o.writeAll(style.mixAt(&scratch, 240, 250, 0.95));
    o.writeAll(s.description);
    o.writeAll(term.RESET);
    o.writeAll("\n");

    if (!s.has_frontmatter) {
        o.writeAll("\n");
        o.writeAll(style.AMBER);
        o.writeAll("!  no frontmatter block — agents cannot index this skill\n");
        o.writeAll(term.RESET);
    }
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

fn cmdInit(ctx: *Context) !void {
    const positionals = ctx.positionals();
    const name = if (positionals.len > 0) positionals[0] else "my-skill";
    const description = ctx.value("--description") orelse "";

    const target_agent = ctx.value("--dir") orelse ctx.value("--agent") orelse "claude-code";
    const scope_global = ctx.flag("-g") or ctx.flag("--global");

    // `--dir` is an exact destination; otherwise resolve the agent's directory.
    var root: []const u8 = undefined;
    if (std.mem.indexOfScalar(u8, target_agent, '/') != null or ctx.value("--dir") != null) {
        root = if (std.fs.path.isAbsolute(target_agent))
            try ctx.arena.dupe(u8, target_agent)
        else
            try std.fs.path.join(ctx.arena, &.{ ctx.cwd, target_agent });
    } else {
        const agent = registry.find(target_agent) orelse {
            ctx.out.writeAll("unknown agent. run `bliz agents` for the list\n");
            return error.UnknownAgent;
        };
        const template = if (scope_global) agent.global else agent.project;
        if (template.len == 0) {
            ctx.out.writeAll("that agent is project-only\n");
            return error.ProjectOnly;
        }
        root = if (scope_global)
            try registry.expand(ctx.arena, template, ctx.env)
        else
            try std.fs.path.join(ctx.arena, &.{ ctx.cwd, template });
    }

    const dir = try std.fs.path.join(ctx.arena, &.{ root, name });
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch |err| {
        ctx.out.writeAll("could not create: ");
        ctx.out.writeAll(dir);
        ctx.out.writeAll("\n");
        return err;
    };

    const content = try frontmatter.scaffold(ctx.arena, name, description);
    const path = try std.fs.path.join(ctx.arena, &.{ dir, "SKILL.md" });
    const file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true });
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, content);

    const o = ctx.out;
    o.writeAll(style.GREEN);
    o.writeAll("◇  created ");
    o.writeAll(term.RESET);
    o.writeAll(term.BOLD);
    o.writeAll(name);
    o.writeAll(term.RESET);
    o.writeAll(style.GHOST);
    o.writeAll("  ");
    o.writeAll(discover.shortenPath(ctx.arena, path, ctx.env.get("HOME") orelse "", ctx.cwd));
    o.writeAll(term.RESET);
    o.writeAll("\n");
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

const InstallTarget = struct {
    display: []const u8,
    root: []const u8,
    /// How many other agents share this directory (the shared `.agents/skills`
    /// hubs), so the report can say so without listing each one.
    merged: usize = 0,
};

const InstallOutcome = struct {
    skill: []const u8,
    /// Absolute destination. Empty when the install never got that far.
    dest: []const u8 = "",
    /// Shortened destination, for humans.
    where: []const u8 = "",
    agent: []const u8 = "",
    status: Status,
    note: []const u8 = "",

    const Status = enum { installed, replaced, planned, skipped, failed };
};

/// The agent's skills directory, absolute. Empty when the agent has no
/// directory in the requested scope.
fn agentRoot(ctx: *Context, agent: registry.Agent, global: bool) ![]const u8 {
    const template = if (global) agent.global else agent.project;
    if (template.len == 0) return "";
    if (global) return registry.expand(ctx.arena, template, ctx.env);
    return std.fs.path.join(ctx.arena, &.{ ctx.cwd, template });
}

fn dirExistsAt(ctx: *Context, path: []const u8) bool {
    if (path.len == 0) return false;
    var d = std.Io.Dir.cwd().openDir(ctx.io, path, .{}) catch return false;
    d.close(ctx.io);
    return true;
}

/// Adds a target, merging agents that resolve to the same directory. Without
/// this, installing to `cursor` and `codex` would copy the same skill into
/// `.agents/skills` twice.
fn addTarget(
    ctx: *Context,
    list: *std.ArrayList(InstallTarget),
    agent: registry.Agent,
    root: []const u8,
) !void {
    for (list.items) |*t| {
        if (std.mem.eql(u8, t.root, root)) {
            t.merged += 1;
            return;
        }
    }
    try list.append(ctx.arena, .{ .display = agent.display, .root = root });
}

fn hasSpec(specs: []const []const u8, needle: []const u8) bool {
    for (specs) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// The targets a bare `bliz install` picks: every agent whose skills directory
/// already exists in this scope, or — when there is none — the fallback set.
/// Returns true when the fallback was needed, so the caller can explain itself.
fn addDefaultTargets(ctx: *Context, list: *std.ArrayList(InstallTarget), global: bool) !bool {
    for (registry.agents) |a| {
        const root = try agentRoot(ctx, a, global);
        if (root.len == 0 or !dirExistsAt(ctx, root)) continue;
        try addTarget(ctx, list, a, root);
    }
    if (list.items.len > 0) return false;
    try addFallbackTargets(ctx, list, global);
    return true;
}

/// True when it is worth asking the user a question: both ends are a terminal,
/// the answer was not already given with `-a`, and the caller did not ask for
/// machine-readable output or explicitly wave the prompt away.
fn interactive(ctx: *Context) bool {
    if (!term.stdinIsTty() or !term.stdoutIsTty()) return false;
    if (ctx.flag("--json")) return false;
    if (ctx.flag("--yes") or ctx.flag("-y")) return false;
    return true;
}

/// Every scope as a `pick.Scope`, so the picker's own vocabulary is used for
/// the rows while `discover.Scope` stays the vocabulary for scanning.
fn pickScope(s: discover.Scope) pick.Scope {
    return if (s == .global) .global else .project;
}

/// One candidate per registry agent per offered scope: its resolved destination
/// plus whether that directory exists right now. `pick.buildItems` merges the
/// agents that share a directory — all 21 hub agents become a single
/// `.agents/skills` row — and orders the result defaults-first, which is what
/// the pre-checked rows are.
///
/// The same agent appears once per scope on purpose: `.agents/skills` in the
/// checkout and `~/.agents/skills` are two different decisions, and the scope
/// is part of the merge key so they cannot collapse into one row.
fn pickerItems(ctx: *Context, scopes: []const discover.Scope, defaults: []const InstallTarget) ![]pick.Item {
    const home = ctx.env.get("HOME") orelse "";
    var cands: std.ArrayList(pick.Candidate) = .empty;
    for (scopes) |scope| {
        const global = scope == .global;
        for (registry.agents) |a| {
            const root = try agentRoot(ctx, a, global);
            if (root.len == 0) continue;
            try cands.append(ctx.arena, .{
                .key = a.key,
                .display = a.display,
                .root = root,
                .short_root = discover.shortenPath(ctx.arena, root, home, ctx.cwd),
                .detected = dirExistsAt(ctx, root),
                .default_on = hasTargetRoot(defaults, root),
                .scope = pickScope(scope),
            });
        }
    }
    return pick.buildItems(ctx.arena, cands.items);
}

fn hasTargetRoot(targets: []const InstallTarget, root: []const u8) bool {
    for (targets) |t| {
        if (std.mem.eql(u8, t.root, root)) return true;
    }
    return false;
}

/// Turns the picker's checked rows back into install targets.
///
/// `display` is the *primary* agent and `merged` the number of others sharing
/// the directory, so the report's `Cursor +20` label is produced by the same
/// formatting the flag-driven path uses rather than being passed through.
fn targetsFromItems(arena: std.mem.Allocator, items: []const pick.Item, chosen: []const usize) ![]InstallTarget {
    var out: std.ArrayList(InstallTarget) = .empty;
    for (chosen) |i| {
        if (i >= items.len) continue;
        const it = items[i];
        try out.append(arena, .{
            .display = it.agents[0],
            .root = it.root,
            .merged = if (it.agents.len > 1) it.agents.len - 1 else 0,
        });
    }
    return out.items;
}

/// Opens the picker and turns the answer back into install targets.
///
/// `defaults` comes from the *primary* scope only, so the tab the prompt opens
/// on is pre-checked exactly the way a bare install would have installed, and
/// the other tab opens empty. That is what keeps `↵` on the first frame
/// meaning what it always meant while still making the other scope one
/// keystroke away.
fn runPicker(ctx: *Context, scopes: []const discover.Scope, defaults: []const InstallTarget) ![]InstallTarget {
    const items = try pickerItems(ctx, scopes, defaults);
    if (items.len == 0) return &.{};

    const result = try pick.run(
        ctx.arena,
        ctx.gpa,
        ctx.io,
        ctx.env,
        items,
        .{
            .message = "Install to",
            .badge = if (scopes.len > 1) "project + global" else scopes[0].label(),
            .detail_lines = 3,
        },
        ctx.out,
        term.supportsSyncOutput(ctx.env),
        ctx.cwd,
    );
    return switch (result.outcome) {
        .cancelled => &.{},
        .submitted => |indices| targetsFromItems(ctx.arena, items, indices),
    };
}

/// Targets for a scope that has no agent directory at all.
///
/// The universal hub is the anchor: it is the reference's canonical copy
/// location, and every hub agent reads it. On top of that, agents whose project
/// directory the reference creates by default are included — but only when they
/// actually look installed on this machine, so `bliz install` never invents a
/// `.claude/` directory for someone who does not use Claude Code.
fn addFallbackTargets(
    ctx: *Context,
    list: *std.ArrayList(InstallTarget),
    global: bool,
) !void {
    const hub_root = try agentRoot(ctx, registry.universal_hub, global);
    if (hub_root.len > 0) try addTarget(ctx, list, registry.universal_hub, hub_root);

    for (registry.agents) |a| {
        if (!registry.createsProjectDirByDefault(a.key)) continue;
        if (!registry.installedGlobally(ctx.arena, ctx.io, ctx.env, a)) continue;
        const root = try agentRoot(ctx, a, global);
        if (root.len == 0) continue;
        try addTarget(ctx, list, a, root);
    }
}

fn cmdInstall(ctx: *Context) !void {
    const o = ctx.out;
    const positionals = ctx.positionals();

    if (positionals.len == 0) {
        o.writeAll("usage: bliz install <source> [--skill <name>]... [-a <agent>]... [-g|-p] [--yes]\n\n");
        o.writeAll(style.FAINT);
        o.writeAll("  owner/repo\n");
        o.writeAll("  https://github.com/owner/repo\n");
        o.writeAll("  https://github.com/owner/repo/tree/<ref>/<path>\n");
        o.writeAll("  ./local-directory\n");
        o.writeAll(term.RESET);
        return error.UnknownSource;
    }
    const spec = positionals[0];
    const home = ctx.env.get("HOME") orelse "";

    var src = install.parseSource(ctx.arena, ctx.io, spec, ctx.cwd, home) catch |err| switch (err) {
        error.SourceNotFound => {
            o.writeAll(style.AMBER);
            o.writeAll("no such directory: ");
            o.writeAll(spec);
            o.writeAll("\n");
            o.writeAll(term.RESET);
            return error.SourceNotFound;
        },
        error.UnknownSource => {
            o.writeAll(style.AMBER);
            o.writeAll("unrecognised source: ");
            o.writeAll(spec);
            o.writeAll("\n");
            o.writeAll(term.RESET);
            o.writeAll(style.FAINT);
            o.writeAll("  expected owner/repo, a github.com URL, or a local directory\n");
            o.writeAll(term.RESET);
            return error.UnknownSource;
        },
        else => return err,
    };
    if (src.ref.len == 0) {
        if (ctx.value("--ref")) |r| src.ref = r;
    }

    // --- fetch ------------------------------------------------------------
    // `tmp_path` is declared out here so the cleanup defer runs at function
    // exit rather than at the end of the `if` block, which would delete the
    // checkout before it had been read.
    var tmp_path: []const u8 = "";
    defer {
        if (tmp_path.len > 0) std.Io.Dir.cwd().deleteTree(ctx.io, tmp_path) catch {};
    }

    var search_root = src.location;
    if (src.is_git) {
        tmp_path = try install.tempDir(ctx.arena, ctx.io, ctx.env);
        const dest = try std.fs.path.join(ctx.arena, &.{ tmp_path, src.baseName() });

        o.writeAll(style.FAINT);
        o.writeAll("  fetching ");
        o.writeAll(src.location);
        if (src.ref.len > 0) {
            o.writeAll(" @ ");
            o.writeAll(src.ref);
        }
        o.writeAll("\n");
        o.writeAll(term.RESET);

        var git_err: []const u8 = "";
        install.clone(ctx.arena, ctx.gpa, ctx.io, src.location, src.ref, dest, &git_err) catch |err| switch (err) {
            error.GitNotFound => {
                o.writeAll(style.AMBER);
                o.writeAll("git is required to install from a repository but is not on PATH\n");
                o.writeAll(term.RESET);
                return error.GitNotFound;
            },
            error.GitFailed => {
                o.writeAll(style.AMBER);
                o.writeAll("could not fetch ");
                o.writeAll(spec);
                o.writeAll("\n");
                o.writeAll(term.RESET);
                o.writeAll(style.FAINT);
                o.writeAll("  ");
                o.writeAll(git_err);
                o.writeAll("\n");
                o.writeAll(term.RESET);
                return error.GitFailed;
            },
            else => return err,
        };
        search_root = dest;
    }
    if (src.sub_path.len > 0) {
        search_root = try std.fs.path.join(ctx.arena, &.{ search_root, src.sub_path });
        if (!dirExistsAt(ctx, search_root)) {
            o.writeAll(style.AMBER);
            o.writeAll("no directory ");
            o.writeAll(src.sub_path);
            o.writeAll(" in that source\n");
            o.writeAll(term.RESET);
            return error.SourceNotFound;
        }
    }

    // --- discover ---------------------------------------------------------
    const found = try install.find(ctx.arena, ctx.io, ctx.gpa, search_root, src.baseName());
    if (found.len == 0) {
        o.writeAll(style.AMBER);
        o.writeAll("no SKILL.md found in ");
        o.writeAll(spec);
        o.writeAll("\n");
        o.writeAll(term.RESET);
        return error.SkillNotFound;
    }
    if (ctx.flag("--list") or ctx.flag("-l")) {
        if (ctx.flag("--json")) {
            printFoundJson(ctx, found);
        } else {
            listFound(ctx, src.display, found);
        }
        return;
    }

    // --- where ------------------------------------------------------------
    // `-g` names the scope for every path that cannot ask, and it is also what
    // the prompt pre-checks. `-p` says the same thing for project, which is the
    // default anyway but was advertised in `--help` and read by nothing before
    // now. Naming either one narrows the prompt to that scope; naming neither
    // offers both, because "where does this go?" is the question those flags
    // used to have to answer for you.
    const global = ctx.flag("-g") or ctx.flag("--global");
    const project_only = ctx.flag("-p") or ctx.flag("--project");
    const scopes: []const discover.Scope = if (global)
        &.{.global}
    else if (project_only)
        &.{.project}
    else
        &.{ .project, .global };
    const agent_specs = ctx.values(&.{ "--agent", "-a" });
    // `--all` is the reference's shorthand for "every skill, every agent".
    // Every skill is already the default, so it only widens the agent set.
    const all_agents = ctx.flag("--all") or hasSpec(agent_specs, "*");

    var targets: std.ArrayList(InstallTarget) = .empty;
    if (all_agents) {
        for (registry.agents) |a| {
            const root = try agentRoot(ctx, a, global);
            if (root.len == 0) continue;
            try addTarget(ctx, &targets, a, root);
        }
    } else if (agent_specs.len > 0) {
        for (agent_specs) |key| {
            const a = registry.find(key) orelse {
                o.writeAll(style.AMBER);
                o.writeAll("unknown agent: ");
                o.writeAll(key);
                o.writeAll(term.RESET);
                o.writeAll(style.FAINT);
                o.writeAll("\n  run `bliz agents` for the list\n");
                o.writeAll(term.RESET);
                return error.UnknownAgent;
            };
            const root = try agentRoot(ctx, a, global);
            if (root.len == 0) {
                o.writeAll(style.AMBER);
                o.writeAll(a.display);
                o.writeAll(" has no global directory — it is project-only\n");
                o.writeAll(term.RESET);
                return error.ProjectOnly;
            }
            try addTarget(ctx, &targets, a, root);
        }
    } else {
        // No agent named: install to the agents actually present here. A bare
        // `bliz install` should not litter every agent's directory on the
        // machine, and it should not invent directories that were never there.
        const fell_back = try addDefaultTargets(ctx, &targets, global);
        if (targets.items.len == 0) {
            o.writeAll(style.AMBER);
            o.writeAll("no agent found in this ");
            o.writeAll(if (global) "account" else "project");
            o.writeAll(term.RESET);
            o.writeAll(style.FAINT);
            o.writeAll("\n  pass -a <agent> to choose one; `bliz agents` lists them all\n");
            o.writeAll(term.RESET);
            return error.UnknownAgent;
        }

        // With a terminal to ask on, the choice becomes a prompt instead of an
        // inference. It opens with exactly the set a bare install would have
        // used already checked, so `↵` on the first frame is unchanged
        // behaviour and everything else is one keystroke away.
        if (interactive(ctx)) {
            const picked = try runPicker(ctx, scopes, targets.items);
            if (picked.len == 0) {
                o.writeAll(style.AMBER);
                o.writeAll("cancelled — nothing installed\n");
                o.writeAll(term.RESET);
                return error.NothingSelected;
            }
            targets = .empty;
            try targets.appendSlice(ctx.arena, picked);
        } else if (fell_back) {
            // Nothing was detected and there is nobody to ask. The reference
            // tool does not stop at this point either: it always writes the
            // universal `.agents/skills` hub, and it also creates the project
            // directory of any agent it can see installed on the machine
            // (Claude Code is the one that opts into that upstream). Matching it
            // means a bare install in a fresh checkout lands somewhere useful
            // instead of dead-ending — while still not inventing directories for
            // the fifty-odd agents nobody here uses.
            o.writeAll(style.FAINT);
            o.writeAll("  no agent detected — using ");
            for (targets.items, 0..) |t, i| {
                if (i > 0) o.writeAll(", ");
                o.writeAll(t.display);
            }
            o.writeAll("\n");
            o.writeAll(term.RESET);
        }
    }

    // --- which skills -----------------------------------------------------
    // Target labels are formatted only now, because `merged` keeps growing
    // while agents are added.
    const labels = try ctx.arena.alloc([]const u8, targets.items.len);
    for (targets.items, 0..) |t, i| {
        labels[i] = if (t.merged > 0)
            try std.fmt.allocPrint(ctx.arena, "{s} +{d}", .{ t.display, t.merged })
        else
            t.display;
    }

    const skill_specs = ctx.values(&.{ "--skill", "-s" });
    var chosen: std.ArrayList(install.Found) = .empty;
    if (skill_specs.len == 0 or hasSpec(skill_specs, "*")) {
        try chosen.appendSlice(ctx.arena, found);
    } else {
        for (skill_specs) |needle| {
            var hit = false;
            for (found) |f| {
                const match = std.mem.eql(u8, f.name, needle) or
                    (f.title.len > 0 and std.mem.eql(u8, f.title, needle));
                if (!match) continue;
                try chosen.append(ctx.arena, f);
                hit = true;
            }
            if (!hit) {
                o.writeAll(style.AMBER);
                o.writeAll("no skill named ");
                o.writeAll(needle);
                o.writeAll(" in this source\n");
                o.writeAll(term.RESET);
            }
        }
        if (chosen.items.len == 0) return error.SkillNotFound;
    }

    // --- act --------------------------------------------------------------
    const force = ctx.flag("--force");
    const dry_run = ctx.flag("--dry-run");
    var results: std.ArrayList(InstallOutcome) = .empty;
    var total_files: usize = 0;
    var total_bytes: u64 = 0;

    for (chosen.items) |f| {
        for (targets.items, 0..) |t, ti| {
            const dest = try std.fs.path.join(ctx.arena, &.{ t.root, f.name });
            const where = discover.shortenPath(ctx.arena, dest, home, ctx.cwd);

            if (install.isInside(f.dir, dest)) {
                try results.append(ctx.arena, .{
                    .skill = f.name,
                    .where = where,
                    .agent = labels[ti],
                    .status = .failed,
                    .note = "destination is inside the source",
                });
                continue;
            }
            const exists = dirExistsAt(ctx, dest);
            if (exists and !force) {
                try results.append(ctx.arena, .{
                    .skill = f.name,
                    .dest = dest,
                    .where = where,
                    .agent = labels[ti],
                    .status = .skipped,
                    .note = "--force to replace",
                });
                continue;
            }
            if (dry_run) {
                try results.append(ctx.arena, .{
                    .skill = f.name,
                    .dest = dest,
                    .where = where,
                    .agent = labels[ti],
                    .status = .planned,
                });
                continue;
            }

            // Replacing means clearing the destination first, so a stale file
            // from the previous version cannot survive the update.
            if (exists) std.Io.Dir.cwd().deleteTree(ctx.io, dest) catch {};

            const stats = install.copyTree(ctx.arena, ctx.io, f.dir, dest) catch |err| {
                try results.append(ctx.arena, .{
                    .skill = f.name,
                    .dest = dest,
                    .where = where,
                    .agent = labels[ti],
                    .status = .failed,
                    .note = @errorName(err),
                });
                continue;
            };
            total_files += stats.files;
            total_bytes += stats.bytes;
            try results.append(ctx.arena, .{
                .skill = f.name,
                .dest = dest,
                .where = where,
                .agent = labels[ti],
                .status = if (exists) .replaced else .installed,
            });
        }
    }

    if (ctx.flag("--json")) {
        printInstallJson(ctx, results.items);
        return;
    }
    const failed = printInstallReport(ctx, src.display, results.items, targets.items, total_files, total_bytes, dry_run);
    if (failed > 0) return error.InstallFailed;
}

fn listFound(ctx: *Context, source: []const u8, found: []const install.Found) void {
    const o = ctx.out;
    var name_width: usize = 0;
    for (found) |f| name_width = @max(name_width, width.width(f.name));
    name_width = @min(name_width, 32);

    o.writeAll("\n");
    o.writeAll(term.BOLD);
    o.writeAll(style.mixAt(&scratch, 245, 255, 1.0));
    o.writeAll("available");
    o.writeAll(term.RESET);
    o.writeAll(style.GHOST);
    o.writeAll("  ");
    o.writeAll(source);
    o.writeAll(term.RESET);
    o.writeAll("\n\n");

    for (found) |f| {
        var padbuf: [128]u8 = undefined;
        o.writeAll("  ");
        o.writeAll(style.mixAt(&scratch, 240, 252, 0.92));
        o.writeAll(width.padRight(&padbuf, f.name, name_width));
        o.writeAll(term.RESET);
        if (f.rel.len > 0) {
            o.writeAll("  ");
            o.writeAll(style.GHOST);
            o.writeAll(f.rel);
            o.writeAll(term.RESET);
        }
        o.writeAll("\n    ");
        o.writeAll(style.FAINT);
        o.writeAll(if (f.description.len > 0) f.description else "no description");
        o.writeAll(term.RESET);
        if (!f.has_frontmatter) {
            o.writeAll("  ");
            o.writeAll(style.AMBER);
            o.writeAll("no frontmatter");
            o.writeAll(term.RESET);
        }
        o.writeAll("\n");
    }

    var buf: [96]u8 = undefined;
    o.writeAll(style.FAINT);
    o.writeAll(std.fmt.bufPrint(&buf, "\n  {d} skill{s} — nothing installed\n", .{
        found.len,
        if (found.len == 1) "" else "s",
    }) catch "");
    o.writeAll(term.RESET);
}

/// `--list --json`: the source's inventory, without installing anything.
fn printFoundJson(ctx: *Context, found: []const install.Found) void {
    var b = bufmod.Buf.init(ctx.arena);
    b.add("[\n");
    for (found, 0..) |f, i| {
        if (i > 0) b.add(",\n");
        b.add("  { \"name\": ");
        jsonStr(&b, f.name);
        b.add(", \"title\": ");
        jsonStr(&b, f.title);
        b.add(", \"description\": ");
        jsonStr(&b, f.description);
        b.add(", \"path\": ");
        jsonStr(&b, f.dir);
        b.add(", \"rel\": ");
        jsonStr(&b, f.rel);
        b.addFmt(", \"files\": {d}, \"hasFrontmatter\": {s} }}", .{
            f.files,
            if (f.has_frontmatter) "true" else "false",
        });
    }
    b.add("\n]\n");
    ctx.out.writeAll(b.bytes());
}

/// Returns the number of failures, so the caller can exit non-zero.
fn printInstallReport(
    ctx: *Context,
    source: []const u8,
    results: []const InstallOutcome,
    targets: []const InstallTarget,
    files: usize,
    bytes: u64,
    dry_run: bool,
) usize {
    const o = ctx.out;
    var installed: usize = 0;
    var replaced: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var name_width: usize = 0;
    for (results) |r| name_width = @max(name_width, width.width(r.skill));
    name_width = @min(name_width, 32);

    // The agent column earns its space only when more than one destination is
    // in play. With a single target the path already says which agent it is.
    var agent_width: usize = 0;
    var show_agent = targets.len > 1;
    for (results) |r| agent_width = @max(agent_width, width.width(r.agent));
    for (targets) |t| {
        if (t.merged > 0) show_agent = true;
    }
    agent_width = @min(agent_width, 22);

    o.writeAll("\n");
    o.writeAll(term.BOLD);
    o.writeAll(style.mixAt(&scratch, 245, 255, 1.0));
    o.writeAll(if (dry_run) "dry run" else "install");
    o.writeAll(term.RESET);
    o.writeAll(style.GHOST);
    o.writeAll("  ");
    o.writeAll(source);
    o.writeAll(term.RESET);
    o.writeAll("\n\n");

    for (results) |r| {
        // Two pad buffers: `padRight` writes into the buffer it is given, so
        // sharing one would clobber the first column.
        var padbuf: [128]u8 = undefined;
        var abuf: [128]u8 = undefined;
        const color = switch (r.status) {
            .installed => style.GREEN,
            .replaced => style.AMBER,
            .planned => style.ACCENT,
            .skipped => style.GHOST,
            .failed => style.RED,
        };
        const marker = switch (r.status) {
            .installed => style.CHECK,
            .replaced => "↻",
            .planned => style.RADIO_OFF,
            .skipped => "·",
            .failed => "✗",
        };
        switch (r.status) {
            .installed, .planned => installed += 1,
            .replaced => replaced += 1,
            .skipped => skipped += 1,
            .failed => failed += 1,
        }

        o.writeAll("  ");
        o.writeAll(color);
        o.writeAll(marker);
        o.writeAll(term.RESET);
        o.writeAll(" ");
        o.writeAll(style.mixAt(&scratch, 240, 252, 0.95));
        o.writeAll(width.padRight(&padbuf, r.skill, name_width));
        o.writeAll(term.RESET);
        if (show_agent) {
            o.writeAll("  ");
            o.writeAll(style.FAINT);
            o.writeAll(width.padRight(&abuf, r.agent, agent_width));
            o.writeAll(term.RESET);
        }
        o.writeAll(style.GHOST);
        o.writeAll("  ");
        o.writeAll(r.where);
        o.writeAll(term.RESET);
        if (r.note.len > 0) {
            o.writeAll(style.FAINT);
            o.writeAll("  ");
            o.writeAll(r.note);
            o.writeAll(term.RESET);
        }
        o.writeAll("\n");
    }

    var b = bufmod.Buf.init(ctx.arena);
    b.addFmt("\n  {d} {s}", .{ installed, if (dry_run) "would install" else "installed" });
    if (replaced > 0) b.addFmt(" · {d} replaced", .{replaced});
    if (skipped > 0) b.addFmt(" · {d} skipped", .{skipped});
    if (failed > 0) b.addFmt(" · {d} failed", .{failed});
    if (!dry_run and files > 0) {
        b.addFmt(" · {d} file{s} · {s}", .{
            files,
            if (files == 1) "" else "s",
            discover.humanBytes(ctx.arena, bytes),
        });
    }
    b.add("\n");
    o.writeAll(style.FAINT);
    o.writeAll(b.bytes());
    o.writeAll(term.RESET);
    return failed;
}

fn printInstallJson(ctx: *Context, results: []const InstallOutcome) void {
    var b = bufmod.Buf.init(ctx.arena);
    b.add("[\n");
    for (results, 0..) |r, i| {
        if (i > 0) b.add(",\n");
        b.add("  { \"skill\": ");
        jsonStr(&b, r.skill);
        b.add(", \"path\": ");
        jsonStr(&b, r.dest);
        b.add(", \"agent\": ");
        jsonStr(&b, r.agent);
        b.add(", \"status\": ");
        jsonStr(&b, @tagName(r.status));
        b.add(" }");
    }
    b.add("\n]\n");
    ctx.out.writeAll(b.bytes());
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

fn cmdRemove(ctx: *Context) !void {
    const positionals = ctx.positionals();
    const scopes = scopesFrom(ctx);
    const scan = try discover.scanAll(ctx.arena, ctx.io, ctx.gpa, ctx.cwd, ctx.env, scopes);
    const o = ctx.out;

    var targets: std.ArrayList(discover.Skill) = .empty;
    if (positionals.len == 0) {
        // Nothing named: drive the same animated prompt, then act on the result.
        if (!term.stdinIsTty()) {
            o.writeAll("usage: bliz remove <name>...\n");
            return;
        }
        const result = try tui.run(ctx.arena, ctx.gpa, ctx.io, ctx.env, scan.roots, .{
            .message = "Remove skills",
            .badge = if (scopes.len == 1) scopes[0].label() else "all scopes",
            .require_selection = true,
            .detail_lines = 3,
        }, o, term.supportsSyncOutput(ctx.env), ctx.cwd);
        switch (result.outcome) {
            .cancelled => return error.NothingSelected,
            .submitted => |indices| {
                for (indices) |i| try targets.append(ctx.arena, result.skills[i]);
            },
        }
    } else {
        for (positionals) |name| {
            for (scan.skills) |s| {
                if (std.mem.eql(u8, s.name, name)) try targets.append(ctx.arena, s);
            }
        }
    }

    if (targets.items.len == 0) {
        o.writeAll(style.AMBER);
        o.writeAll("nothing to remove\n");
        o.writeAll(term.RESET);
        return;
    }

    // Always show exactly what would be deleted before deleting it.
    o.writeAll("\n");
    for (targets.items) |s| {
        o.writeAll("  ");
        o.writeAll(style.RED);
        o.writeAll("✗ ");
        o.writeAll(term.RESET);
        o.writeAll(s.name);
        o.writeAll(style.GHOST);
        o.writeAll("  ");
        o.writeAll(s.dir);
        o.writeAll(term.RESET);
        o.writeAll("\n");
    }
    if (!(ctx.flag("--yes") or ctx.flag("-y"))) {
        o.writeAll(style.FAINT);
        o.writeAll("  pass --yes to confirm\n");
        o.writeAll(term.RESET);
        return;
    }

    var removed: usize = 0;
    for (targets.items) |s| {
        std.Io.Dir.cwd().deleteTree(ctx.io, s.dir) catch {
            o.writeAll(style.RED);
            o.writeAll("  failed: ");
            o.writeAll(s.dir);
            o.writeAll("\n");
            o.writeAll(term.RESET);
            continue;
        };
        removed += 1;
    }
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "removed {d} skill{s}\n", .{
        removed,
        if (removed == 1) "" else "s",
    }) catch "";
    o.writeAll(style.GREEN);
    o.writeAll(line);
    o.writeAll(term.RESET);
}

// ---------------------------------------------------------------------------
// stats / agents / record
// ---------------------------------------------------------------------------

fn cmdStats(ctx: *Context) !void {
    const scopes = scopesFrom(ctx);
    const scan = try discover.scanAll(ctx.arena, ctx.io, ctx.gpa, ctx.cwd, ctx.env, scopes);
    const o = ctx.out;

    o.writeAll(term.BOLD);
    o.writeAll(style.mixAt(&scratch, 245, 255, 1.0));
    o.writeAll("Skill inventory");
    o.writeAll(term.RESET);
    o.writeAll("\n\n");

    var max_count: usize = 1;
    for (scan.roots) |r| max_count = @max(max_count, r.skills.len);
    const bar_max: usize = 34;

    var lbuf: [160]u8 = undefined;
    for (scan.roots) |r| {
        if (!r.exists) continue;
        var padbuf: [192]u8 = undefined;
        o.writeAll(style.mixAt(&scratch, 238, 247, 0.9));
        // Two roots can share a display name (e.g. `.workbuddy/skills` and
        // `~/.workbuddy/skills`). Suffix the scope only when that actually
        // happens, so the common case stays clean.
        const base = r.label(&lbuf);
        var nbuf2: [80]u8 = undefined;
        const ambiguous = for (scan.roots) |other| {
            if (other.path.ptr == r.path.ptr) continue;
            if (!other.exists) continue;
            var obuf: [160]u8 = undefined;
            if (std.mem.eql(u8, other.label(&obuf), base)) break true;
        } else false;
        const shown = if (ambiguous)
            (std.fmt.bufPrint(&nbuf2, "{s} · {s}", .{ base, r.scope.label() }) catch base)
        else
            base;
        o.writeAll(width.padRight(&padbuf, shown, 22));
        o.writeAll(term.RESET);
        o.writeAll(" ");

        const filled = if (r.skills.len == 0) 0 else @max(1, r.skills.len * bar_max / max_count);
        o.writeAll(if (r.skills.len > 0) style.ACCENT else style.GHOST);
        var i: usize = 0;
        while (i < filled) : (i += 1) o.writeAll("█");
        o.writeAll(style.GHOST);
        while (i < bar_max) : (i += 1) o.writeAll("░");
        o.writeAll(term.RESET);
        var nbuf: [32]u8 = undefined;
        o.writeAll(style.mixAt(&scratch, 240, 250, 0.85));
        o.writeAll(std.fmt.bufPrint(&nbuf, " {d}", .{r.skills.len}) catch "");
        o.writeAll(term.RESET);
        o.writeAll("\n");
    }
    var with_fm: usize = 0;
    var bytes: u64 = 0;
    for (scan.skills) |s| {
        if (s.has_frontmatter) with_fm += 1;
        bytes += s.bytes;
    }
    var fb: [192]u8 = undefined;
    const summary = std.fmt.bufPrint(&fb, "\n{d} skills · {d}/{d} with frontmatter · {s}\n", .{
        scan.skills.len,
        with_fm,
        scan.skills.len,
        discover.humanBytes(ctx.arena, bytes),
    }) catch "";
    o.writeAll(style.FAINT);
    o.writeAll(summary);
    o.writeAll(term.RESET);
}

fn cmdAgents(ctx: *Context) !void {
    const o = ctx.out;
    o.writeAll(term.BOLD);
    o.writeAll(style.mixAt(&scratch, 245, 255, 1.0));
    o.writeAll("Agents");
    o.writeAll(term.RESET);
    o.writeAll(style.FAINT);
    var nbuf: [48]u8 = undefined;
    o.writeAll("  ");
    o.writeAll(std.fmt.bufPrint(&nbuf, "{d} supported, ● = present here\n\n", .{registry.agents.len}) catch "");
    o.writeAll(term.RESET);

    for (registry.agents) |a| {
        var pad_key: [192]u8 = undefined;
        var pad_disp: [192]u8 = undefined;
        const exists = dirExists(ctx, if (a.project.len > 0) a.project else a.global);
        o.writeAll(if (exists) style.GREEN else style.GHOST);
        o.writeAll(if (exists) "●" else "○");
        o.writeAll(term.RESET);
        o.writeAll(" ");
        o.writeAll(style.mixAt(&scratch, 240, 251, 0.9));
        o.writeAll(width.padRight(&pad_key, a.key, 18));
        o.writeAll(term.RESET);
        o.writeAll(style.FAINT);
        o.writeAll(width.padRight(&pad_disp, a.display, 22));
        o.writeAll(term.RESET);
        o.writeAll(style.mixAt(&scratch, 236, 241, 0.9));
        o.writeAll(a.project);
        o.writeAll(term.RESET);
        if (a.global.len > 0) {
            o.writeAll(style.GHOST);
            o.writeAll("  ");
            o.writeAll(a.global);
            o.writeAll(term.RESET);
        }
        o.writeAll("\n");
    }
}

fn dirExists(ctx: *Context, relative: []const u8) bool {
    const abs = std.fs.path.join(ctx.arena, &.{ ctx.cwd, relative }) catch return false;
    var d = std.Io.Dir.cwd().openDir(ctx.io, abs, .{}) catch return false;
    d.close(ctx.io);
    return true;
}

const default_script =
    "wait:200;down;down;space;down;space;down;space;" ++
    "type:re;wait:460;backspace;backspace;clear;wait:240;" ++
    "tab;left;wait:360;right;wait:360;" ++
    "all;wait:460;down;down;down;down;down;down;down;down;" ++
    "wait:320;enter";

/// A key sequence for the destination picker: switch to the global scope, take
/// one destination there, switch back, and confirm.
///
/// It shows the four things the prompt is for, in the order a user meets them —
/// the pre-checked defaults on the scope it opens on, the scope switch and its
/// own group headings, a choice made on the other tab surviving the switch back
/// (the summary has to account for it), and finally the confirmation.
const default_pick_script =
    "wait:260;space;wait:680;" ++
    "down;down;down;down;down;wait:240;space;wait:560;" ++
    "up;up;up;up;up;wait:200;space;wait:640;" ++
    "wait:320;enter";

fn cmdRecord(ctx: *Context) !void {
    const want_html = ctx.value("--html");
    const out_path = ctx.value("--out") orelse if (want_html == null) "frames.json" else "";
    const cols = if (ctx.value("--cols")) |v| std.fmt.parseInt(usize, v, 10) catch 104 else 104;
    const rows = if (ctx.value("--rows")) |v| std.fmt.parseInt(usize, v, 10) catch 30 else 30;
    const pick_mode = ctx.flag("--pick");
    const message = ctx.value("--message") orelse if (pick_mode) "Install to" else "Select skills";
    const title = ctx.value("--title") orelse if (pick_mode) "bliz install" else "bliz find";
    const scope_global = ctx.flag("-g") or ctx.flag("--global");
    const scopes: []const discover.Scope = if (scope_global) &.{.global} else &.{.project};

    const base = try discover.buildRoots(ctx.arena, ctx.io, ctx.env, ctx.cwd, scopes);
    const roots = try withExtraRoots(ctx, ctx.arena, base);

    const script = ctx.value("--script") orelse
        (if (pick_mode) default_pick_script else default_script);
    const rec_opts = record.Options{
        .cols = cols,
        .rows = rows,
        .script = script,
        .title = title,
    };

    const rec = if (pick_mode) blk: {
        // The picker's rows are destinations, not skills, so they come from the
        // same registry sweep `bliz install` uses. The defaults go through the
        // same `addDefaultTargets` too, so the recording shows the pre-selection
        // a real bare install would have opened with rather than an empty one —
        // and, like a real bare install, it offers both scopes and pre-checks
        // only the primary one.
        const pick_scopes: []const discover.Scope = if (scope_global) &.{.global} else &.{ .project, .global };
        var defaults: std.ArrayList(InstallTarget) = .empty;
        _ = try addDefaultTargets(ctx, &defaults, scope_global);
        const items = try pickerItems(ctx, pick_scopes, defaults.items);
        break :blk try record.recordPicker(
            ctx.arena,
            ctx.gpa,
            ctx.io,
            ctx.env,
            items,
            .{
                .message = message,
                .badge = if (pick_scopes.len > 1) "project + global" else pick_scopes[0].label(),
                .detail_lines = 3,
            },
            rec_opts,
            ctx.cwd,
        );
    } else try record.record(
        ctx.arena,
        ctx.gpa,
        ctx.io,
        ctx.env,
        roots,
        .{
            .message = message,
            .badge = if (scope_global) "global" else "project",
            .detail_lines = 3,
            .select_all = true,
            .min_load_ms = 460,
        },
        rec_opts,
        ctx.cwd,
    );

    const json = try record.toJson(ctx.arena, rec, rec_opts);

    // `--verify` turns the width invariant into a gate: every row of the frame
    // must measure exactly `cols` cells, or the `move up N` repaint arithmetic
    // drifts and the replay slides down the canvas. Report it, and fail loudly
    // when it is violated so this can run in CI.
    if (ctx.flag("--verify")) {
        var vb: [256]u8 = undefined;
        const chk = rec.check;
        if (chk.violations == 0) {
            ctx.out.writeAll(style.GREEN);
            ctx.out.writeAll(std.fmt.bufPrint(&vb, "◇  frame invariant ok — every row is {d} cells\n", .{chk.expected}) catch "");
        } else {
            ctx.out.writeAll(style.AMBER);
            ctx.out.writeAll(std.fmt.bufPrint(&vb, "◇  frame invariant broken — {d} row(s) off; worst {d} cells on line {d} (expected {d})\n", .{
                chk.violations, chk.worst_width, chk.worst_line, chk.expected,
            }) catch "");
        }
        ctx.out.writeAll(term.RESET);
        if (chk.violations > 0) return error.FrameInvariant;
    }

    if (out_path.len > 0) {
        const abs = if (std.fs.path.isAbsolute(out_path))
            out_path
        else
            try std.fs.path.resolve(ctx.arena, &.{ ctx.cwd, out_path });
        if (std.fs.path.dirname(abs)) |parent| {
            std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
        }
        const file = try std.Io.Dir.cwd().createFile(ctx.io, abs, .{ .truncate = true });
        defer file.close(ctx.io);
        try file.writeStreamingAll(ctx.io, json);

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "◇  recorded {d} frames at {d}×{d} → {s}\n", .{
            rec.frames.len, cols, rows, abs,
        }) catch "";
        ctx.out.writeAll(style.GREEN);
        ctx.out.writeAll(line);
        ctx.out.writeAll(term.RESET);
    }

    if (want_html) |html_path| try writePlayer(ctx, rec, json, html_path);
}

/// Bakes the recording into a copy of the player template, producing a single
/// self-contained HTML file that runs from `file://`.
fn writePlayer(
    ctx: *Context,
    rec: record.Recording,
    json: []const u8,
    html_path: []const u8,
) !void {
    // The template ships next to the player, so accept the usual spellings:
    // an explicit `--template`, `demo/player.template.html` from the repo root,
    // the bare name from inside `demo/`, or the copy that sits two levels above
    // the installed binary (`zig-out/bin/bliz` → repo root).
    const exe_root = std.fs.path.resolve(ctx.arena, &.{ ctx.exe_dir, "..", ".." }) catch ctx.exe_dir;
    const candidates = if (ctx.value("--template")) |explicit|
        &[_][]const u8{explicit}
    else
        &[_][]const u8{
            "demo/player.template.html",
            "player.template.html",
        };

    var template: []const u8 = &.{};
    var tpl_abs: []const u8 = &.{};
    var last_err: anyerror = error.FileNotFound;

    var tried: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        try tried.append(ctx.arena, candidate);
    }
    if (ctx.value("--template") == null) {
        // Exe-relative fallbacks are appended rather than mixed in so an
        // explicit `--template` still means exactly that one path.
        try tried.append(ctx.arena, try std.fs.path.join(ctx.arena, &.{ exe_root, "demo", "player.template.html" }));
        try tried.append(ctx.arena, try std.fs.path.join(ctx.arena, &.{ ctx.exe_dir, "player.template.html" }));
    }

    for (tried.items) |candidate| {
        const abs = if (std.fs.path.isAbsolute(candidate))
            try ctx.arena.dupe(u8, candidate)
        else
            try std.fs.path.join(ctx.arena, &.{ ctx.cwd, candidate });
        if (std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.arena, .limited(2 << 20))) |text| {
            template = text;
            tpl_abs = abs;
            break;
        } else |err| last_err = err;
    }
    if (template.len == 0) {
        ctx.out.writeAll(style.AMBER);
        var eb: [512]u8 = undefined;
        ctx.out.writeAll(std.fmt.bufPrint(&eb, "could not find the player template ({t}) — pass --template <path>\n", .{last_err}) catch "");
        ctx.out.writeAll(term.RESET);
        return last_err;
    }

    const b64 = try record.toGzipBase64(ctx.arena, json);
    const marker = "/*__BLIZ_FRAMES__*/";
    const at = std.mem.find(u8, template, marker) orelse {
        ctx.out.writeAll(style.AMBER);
        ctx.out.writeAll("player template is missing the frames placeholder\n");
        ctx.out.writeAll(term.RESET);
        return error.SkillNotFound;
    };

    var page = bufmod.Buf.init(ctx.arena);
    page.add(template[0..at]);
    page.add("\"");
    page.add(b64);
    page.add("\"");
    page.add(template[at + marker.len ..]);

    const out_abs = if (std.fs.path.isAbsolute(html_path))
        html_path
    else
        try std.fs.path.resolve(ctx.arena, &.{ ctx.cwd, html_path });
    if (std.fs.path.dirname(out_abs)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    const f = try std.Io.Dir.cwd().createFile(ctx.io, out_abs, .{ .truncate = true });
    defer f.close(ctx.io);
    try f.writeStreamingAll(ctx.io, page.bytes());

    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "◇  baked {d} frames into {s} ({d} KB)\n", .{
        rec.frames.len, out_abs, page.bytes().len / 1024,
    }) catch "";
    ctx.out.writeAll(style.GREEN);
    ctx.out.writeAll(line);
    ctx.out.writeAll(term.RESET);
}

// ---------------------------------------------------------------------------

fn cmdHelp(ctx: *Context) !void {
    const o = ctx.out;
    o.writeAll(term.BOLD);
    o.writeAll(style.ACCENT);
    o.writeAll("bliz");
    o.writeAll(term.RESET);
    o.writeAll(style.DIM);
    o.writeAll("  skill manager for the open agent-skills ecosystem\n\n");
    o.writeAll(term.RESET);

    const rows = [_]struct { cmd: []const u8, desc: []const u8 }{
        .{ .cmd = "find [query]", .desc = "browse and select skills in an animated prompt" },
        .{ .cmd = "list [-g|-p]", .desc = "list installed skills, grouped by root" },
        .{ .cmd = "inspect <name>", .desc = "show one skill's metadata and description" },
        .{ .cmd = "install <source>", .desc = "add skills; picks destinations in a prompt" },
        .{ .cmd = "init [name]", .desc = "scaffold a new SKILL.md (-a <agent>, -g)" },
        .{ .cmd = "remove [names...]", .desc = "delete skills, with --yes to confirm" },
        .{ .cmd = "stats", .desc = "skills per root, as a bar chart" },
        .{ .cmd = "agents", .desc = "supported agents and their directories" },
        .{ .cmd = "record --out f.json", .desc = "capture prompt frames for the web player" },
        .{ .cmd = "record --html p.html", .desc = "bake frames into a self-contained player" },
    };
    for (rows) |r| {
        var padbuf: [64]u8 = undefined;
        o.writeAll("  ");
        o.writeAll(style.mixAt(&scratch, 240, 252, 0.95));
        o.writeAll(width.padRight(&padbuf, r.cmd, 22));
        o.writeAll(term.RESET);
        o.writeAll(style.FAINT);
        o.writeAll(r.desc);
        o.writeAll(term.RESET);
        o.writeAll("\n");
    }
    o.writeAll("\n");
    o.writeAll(style.FAINT);
    o.writeAll("  flags:  -g/--global  -p/--project  -a/--agent <key>  --json  --root <dir>\n");
    o.writeAll("          install:  --skill <name>  -l/--list  --all  --force  --dry-run  --ref <ref>\n");
    o.writeAll("                    --yes skips the destination prompt (auto-detect)\n");
    o.writeAll(term.RESET);
}
