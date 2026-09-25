//! Installing skills: resolving where a skill comes from, finding the skills
//! inside it, and copying them into an agent's directory.
//!
//! The source is either a local directory or a git repository. Remote sources
//! are fetched with a shallow `git clone` rather than a bespoke tarball
//! downloader, which means refs, tags, commits, SSH URLs, private repositories
//! and the user's existing git credential helper all work for free.
//!
//! Discovery is container-first, mirroring the reference tool: look in the
//! well-known skill directories (`skills/`, `.claude/skills/`, …) before
//! falling back to a bounded walk of the whole tree. That keeps `examples/`
//! and `test/` fixtures out of the results for well-formed repositories while
//! still finding skills in repositories that ignore the convention.

const std = @import("std");
const registry = @import("registry.zig");
const frontmatter = @import("frontmatter.zig");

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

pub const Source = struct {
    /// Exactly what the user typed, for messages.
    display: []const u8,
    /// A local directory, or the URL to clone.
    location: []const u8,
    /// Subdirectory of the source to search. Set from a `tree/<ref>/<path>` URL.
    sub_path: []const u8 = "",
    /// Git ref to check out after cloning. Empty means the default branch.
    ref: []const u8 = "",
    is_git: bool = false,

    /// The directory name a root-level `SKILL.md` should take its name from.
    /// Clones land in a temp directory, so the repo name is the honest answer.
    pub fn baseName(self: Source) []const u8 {
        if (!self.is_git) return std.fs.path.basename(self.location);
        if (self.sub_path.len > 0) return std.fs.path.basename(self.sub_path);
        var s = self.location;
        if (std.mem.endsWith(u8, s, "/")) s = s[0 .. s.len - 1];
        if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
        return std.fs.path.basename(s);
    }
};

pub const SourceError = error{ UnknownSource, SourceNotFound };

pub fn looksLikePath(spec: []const u8) bool {
    if (spec.len == 0) return false;
    return spec[0] == '/' or spec[0] == '.' or spec[0] == '~';
}

fn looksLikeUrl(spec: []const u8) bool {
    if (std.mem.find(u8, spec, "://") != null) return true;
    if (std.mem.startsWith(u8, spec, "git@")) return true;
    return std.mem.endsWith(u8, spec, ".git");
}

fn isDir(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn resolveLocal(
    arena: std.mem.Allocator,
    spec: []const u8,
    cwd: []const u8,
    home: []const u8,
) ![]const u8 {
    var s = spec;
    if (s.len > 0 and s[0] == '~' and home.len > 0) {
        s = if (s.len == 1)
            home
        else if (s[1] == '/')
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, s[2..] })
        else
            return error.SourceNotFound;
    }
    if (std.fs.path.isAbsolute(s)) return std.fs.path.resolve(arena, &.{s});
    return std.fs.path.resolve(arena, &.{ cwd, s });
}

pub const Github = struct {
    owner: []const u8,
    repo: []const u8,
    ref: []const u8 = "",
    path: []const u8 = "",
};

/// Parses `github.com/owner/repo[/tree/<ref>/<path>]`, with or without a
/// scheme and with an optional `.git` suffix. Returns null for anything else.
pub fn githubParts(spec: []const u8) ?Github {
    var s = spec;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, s, scheme)) {
            s = s[scheme.len..];
            break;
        }
    }
    if (!std.mem.startsWith(u8, s, "github.com/")) return null;
    s = s["github.com/".len..];

    var it = std.mem.splitScalar(u8, s, '/');
    const owner = it.next() orelse return null;
    var repo = it.next() orelse return null;
    if (owner.len == 0 or repo.len == 0) return null;
    if (std.mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
    if (repo.len == 0) return null;

    const third = it.next() orelse return .{ .owner = owner, .repo = repo };
    if (!std.mem.eql(u8, third, "tree")) return .{ .owner = owner, .repo = repo };

    // `<ref>` or `<ref>/<path...>`; refs never contain a slash, paths may.
    const tail = it.rest();
    const slash = std.mem.findScalar(u8, tail, '/') orelse
        return .{ .owner = owner, .repo = repo, .ref = tail };
    return .{
        .owner = owner,
        .repo = repo,
        .ref = tail[0..slash],
        .path = tail[slash + 1 ..],
    };
}

/// True for the `owner/repo` shorthand: exactly one slash, no scheme, no
/// spaces, and only characters that appear in repository names.
pub fn isShorthand(spec: []const u8) bool {
    if (looksLikeUrl(spec) or looksLikePath(spec)) return false;
    var it = std.mem.splitScalar(u8, spec, '/');
    const owner = it.next() orelse return false;
    const repo = it.next() orelse return false;
    if (it.next() != null) return false;
    if (owner.len == 0 or repo.len == 0) return false;
    for (spec) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Resolves a user-supplied source into something fetchable.
///
/// An existing local directory always wins over a remote interpretation, so
/// `bliz install demo/workspace` installs the checkout rather than trying to
/// clone a repository called `demo/workspace`.
pub fn parseSource(
    arena: std.mem.Allocator,
    io: std.Io,
    spec: []const u8,
    cwd: []const u8,
    home: []const u8,
) !Source {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return error.UnknownSource;

    if (looksLikePath(trimmed)) {
        const abs = try resolveLocal(arena, trimmed, cwd, home);
        if (!isDir(io, abs)) return error.SourceNotFound;
        return .{ .display = spec, .location = abs };
    }

    if (!looksLikeUrl(trimmed)) {
        const abs = try std.fs.path.resolve(arena, &.{ cwd, trimmed });
        if (isDir(io, abs)) return .{ .display = spec, .location = abs };
    }

    if (githubParts(trimmed)) |gh| {
        return .{
            .display = spec,
            .location = try std.fmt.allocPrint(arena, "https://github.com/{s}/{s}.git", .{ gh.owner, gh.repo }),
            .sub_path = gh.path,
            .ref = gh.ref,
            .is_git = true,
        };
    }
    if (looksLikeUrl(trimmed)) {
        return .{ .display = spec, .location = try arena.dupe(u8, trimmed), .is_git = true };
    }
    if (isShorthand(trimmed)) {
        return .{
            .display = spec,
            .location = try std.fmt.allocPrint(arena, "https://github.com/{s}.git", .{trimmed}),
            .is_git = true,
        };
    }
    return error.UnknownSource;
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

pub const FetchError = error{ GitNotFound, GitFailed };

fn runGit(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    err_out: *[]const u8,
) !void {
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => return err,
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        err_out.* = std.mem.trim(u8, try arena.dupe(u8, res.stderr), " \t\r\n");
        if (err_out.*.len == 0) err_out.* = "git exited with a non-zero status";
        return error.GitFailed;
    }
}

pub fn tempDir(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    const raw = env.get("TMPDIR") orelse "/tmp";
    const base = std.mem.trimEnd(u8, raw, "/");
    const stamp = std.Io.Clock.real.now(io).toMilliseconds();
    const path = try std.fmt.allocPrint(arena, "{s}/bliz-{d}", .{
        if (base.len == 0) "/tmp" else base,
        stamp,
    });
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

/// Shallow-clones `url` into `dest`, then checks `ref` out if one was asked
/// for. Cloning the default branch first and fetching the ref afterwards (as
/// opposed to `clone --branch`) means a commit SHA works as well as a branch
/// or tag.
pub fn clone(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    ref: []const u8,
    dest: []const u8,
    err_out: *[]const u8,
) !void {
    try runGit(arena, gpa, io, &.{
        "git", "clone", "--depth", "1", "--quiet", "--no-tags", url, dest,
    }, err_out);
    if (ref.len == 0) return;
    try runGit(arena, gpa, io, &.{
        "git", "-C", dest, "fetch", "--depth", "1", "--quiet", "origin", ref,
    }, err_out);
    try runGit(arena, gpa, io, &.{
        "git", "-C", dest, "checkout", "--quiet", "--detach", "FETCH_HEAD",
    }, err_out);
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

pub const Found = struct {
    /// Directory name — the identity that determines the install path.
    name: []const u8,
    /// `name:` from frontmatter when present and different from the directory.
    title: []const u8 = "",
    description: []const u8 = "",
    has_frontmatter: bool = false,
    dir: []const u8,
    /// Path relative to the search root, for display.
    rel: []const u8,
    files: usize = 0,
};

/// Directories that hold skills, relative to a source root. The reference
/// tool's list, plus every agent's project directory from the registry.
const static_containers = [_][]const u8{
    "", // the source root itself
    "skills",
    "skills/.curated",
    "skills/.experimental",
    "skills/.system",
};

const noise = [_][]const u8{
    ".git",         "node_modules", "target", "zig-out", ".zig-cache",
    ".venv",        "vendor",       "dist",   "build",   "__pycache__",
};

fn isNoise(name: []const u8) bool {
    for (noise) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn containerPaths(arena: std.mem.Allocator) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(arena);

    for (static_containers) |c| {
        if (seen.contains(c)) continue;
        try seen.put(c, {});
        try list.append(arena, c);
    }
    for (registry.agents) |a| {
        if (a.project.len == 0) continue;
        if (seen.contains(a.project)) continue;
        try seen.put(a.project, {});
        try list.append(arena, a.project);
    }
    return list.toOwnedSlice(arena);
}

fn countFiles(dir: std.Io.Dir, io: std.Io) usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file) n += 1;
    }
    return n;
}

/// Records `dir_abs` as a skill if it contains a `SKILL.md`. Returns true when
/// it did — the caller then stops descending, so a skill directory's own
/// subdirectories (`references/`, `scripts/`) are never mistaken for skills.
fn recordIfSkill(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Found),
    seen: *std.StringHashMap(void),
    dir_abs: []const u8,
    rel: []const u8,
    name_hint: []const u8,
) !bool {
    var d = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch return false;
    defer d.close(io);

    if (d.statFile(io, "SKILL.md", .{})) |_| {} else |_| return false;

    if (seen.contains(dir_abs)) return true;
    try seen.put(dir_abs, {});

    var title: []const u8 = "";
    var description: []const u8 = "";
    var has_fm = false;
    if (d.readFileAlloc(io, "SKILL.md", gpa, .limited(256 * 1024))) |content| {
        defer gpa.free(content);
        if (frontmatter.parse(arena, content)) |meta| {
            description = meta.description;
            has_fm = meta.has_frontmatter;
            const dirname = if (name_hint.len > 0) name_hint else std.fs.path.basename(dir_abs);
            if (meta.name.len > 0 and !std.mem.eql(u8, meta.name, dirname)) title = meta.name;
        } else |_| {}
    } else |_| {}

    const name = if (name_hint.len > 0) name_hint else std.fs.path.basename(dir_abs);
    try out.append(arena, .{
        .name = try arena.dupe(u8, name),
        .title = title,
        .description = description,
        .has_frontmatter = has_fm,
        .dir = try arena.dupe(u8, dir_abs),
        .rel = try arena.dupe(u8, rel),
        .files = countFiles(d, io),
    });
    return true;
}

fn walk(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Found),
    seen: *std.StringHashMap(void),
    dir_abs: []const u8,
    rel: []const u8,
    depth: usize,
    max_depth: usize,
    root_name: []const u8,
) !void {
    // A directory that *is* a skill shadows everything inside it.
    const hint = if (depth == 0 and rel.len == 0) root_name else "";
    if (try recordIfSkill(arena, io, gpa, out, seen, dir_abs, rel, hint)) return;
    if (depth >= max_depth) return;

    var dir = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isNoise(entry.name)) continue;
        // Directory names come from an iterator scratch buffer.
        const child_name = try arena.dupe(u8, entry.name);
        const child_abs = try std.fs.path.join(arena, &.{ dir_abs, child_name });
        const child_rel = if (rel.len == 0)
            child_name
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, child_name });
        try walk(arena, io, gpa, out, seen, child_abs, child_rel, depth + 1, max_depth, root_name);
    }
}

/// Finds every installable skill below `root`.
///
/// Two passes: the well-known container directories first (depth 3, which
/// covers `skills/<name>`, `skills/<category>/<name>` and
/// `skills/<category>/<category>/<name>`), then a bounded whole-tree walk if
/// that came up empty.
pub fn find(
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    root_name: []const u8,
) ![]Found {
    var out: std.ArrayList(Found) = .empty;
    var seen = std.StringHashMap(void).init(arena);

    for (try containerPaths(arena)) |container| {
        const abs = if (container.len == 0)
            root
        else
            try std.fs.path.join(arena, &.{ root, container });
        if (!isDir(io, abs)) continue;
        try walk(arena, io, gpa, &out, &seen, abs, container, 0, 3, root_name);
    }

    if (out.items.len == 0) {
        try walk(arena, io, gpa, &out, &seen, root, "", 0, 5, root_name);
    }

    std.mem.sort(Found, out.items, {}, struct {
        fn lt(_: void, a: Found, b: Found) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Copying
// ---------------------------------------------------------------------------

pub const CopyStats = struct {
    files: usize = 0,
    bytes: u64 = 0,
    /// Symlinks in the source, which are skipped: following them can escape
    /// the skill directory and pull in unrelated files.
    skipped_links: usize = 0,
};

/// True when `child` is `parent` or lives below it. Used to refuse an install
/// whose destination sits inside its own source, which would recurse forever.
pub fn isInside(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0 or child.len == 0) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return child[parent.len] == '/';
}

pub fn copyTree(
    arena: std.mem.Allocator,
    io: std.Io,
    src: []const u8,
    dst: []const u8,
) !CopyStats {
    return copyTreeDepth(arena, io, src, dst, 0);
}

fn copyTreeDepth(
    arena: std.mem.Allocator,
    io: std.Io,
    src: []const u8,
    dst: []const u8,
    depth: usize,
) !CopyStats {
    var stats: CopyStats = .{};
    if (depth > 32) return stats;

    std.Io.Dir.cwd().createDirPath(io, dst) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var sdir = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer sdir.close(io);
    var ddir = try std.Io.Dir.cwd().openDir(io, dst, .{ .iterate = true });
    defer ddir.close(io);

    var it = sdir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        const name = try arena.dupe(u8, entry.name);
        switch (entry.kind) {
            .file => {
                const size: u64 = if (sdir.statFile(io, name, .{})) |st| st.size else |_| 0;
                try sdir.copyFile(name, ddir, name, io, .{});
                stats.files += 1;
                stats.bytes += size;
            },
            .directory => {
                if (isNoise(name)) continue;
                const sub_src = try std.fs.path.join(arena, &.{ src, name });
                const sub_dst = try std.fs.path.join(arena, &.{ dst, name });
                const sub = try copyTreeDepth(arena, io, sub_src, sub_dst, depth + 1);
                stats.files += sub.files;
                stats.bytes += sub.bytes;
                stats.skipped_links += sub.skipped_links;
            },
            .sym_link => stats.skipped_links += 1,
            else => {},
        }
    }
    return stats;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "githubParts accepts every spelling the reference does" {
    const cases = [_]struct { spec: []const u8, owner: []const u8, repo: []const u8, ref: []const u8, path: []const u8 }{
        .{ .spec = "https://github.com/vercel-labs/skills", .owner = "vercel-labs", .repo = "skills", .ref = "", .path = "" },
        .{ .spec = "http://github.com/a/b.git", .owner = "a", .repo = "b", .ref = "", .path = "" },
        .{ .spec = "github.com/a/b", .owner = "a", .repo = "b", .ref = "", .path = "" },
        .{ .spec = "https://github.com/a/b/", .owner = "a", .repo = "b", .ref = "", .path = "" },
        .{ .spec = "https://github.com/a/b/tree/main", .owner = "a", .repo = "b", .ref = "main", .path = "" },
        .{ .spec = "https://github.com/a/b/tree/main/skills/x", .owner = "a", .repo = "b", .ref = "main", .path = "skills/x" },
        // A ref may itself contain slashes, so only the first segment is the ref.
        .{ .spec = "https://github.com/a/b/tree/feat/thing/skills/x", .owner = "a", .repo = "b", .ref = "feat", .path = "thing/skills/x" },
    };
    for (cases) |c| {
        const got = githubParts(c.spec) orelse {
            std.debug.print("expected a github source from {s}\n", .{c.spec});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(c.owner, got.owner);
        try testing.expectEqualStrings(c.repo, got.repo);
        try testing.expectEqualStrings(c.ref, got.ref);
        try testing.expectEqualStrings(c.path, got.path);
    }
}

test "githubParts rejects non-github sources" {
    const cases = [_][]const u8{
        "gitlab.com/a/b",
        "https://gitlab.com/a/b",
        "vercel-labs/skills",
        "./local",
        "git@github.com:a/b.git",
    };
    for (cases) |c| try testing.expect(githubParts(c) == null);
}

test "isShorthand only matches owner/repo" {
    try testing.expect(isShorthand("vercel-labs/agent-skills"));
    try testing.expect(isShorthand("a/b"));
    try testing.expect(isShorthand("owner_1/repo.2"));
    // Too many segments, a scheme, a path prefix, or punctuation all opt out.
    try testing.expect(!isShorthand("a/b/c"));
    try testing.expect(!isShorthand("a"));
    try testing.expect(!isShorthand("/a/b"));
    try testing.expect(!isShorthand("./a/b"));
    try testing.expect(!isShorthand("https://github.com/a/b"));
    try testing.expect(!isShorthand("a b"));
    try testing.expect(!isShorthand("git@github.com:a/b.git"));
}

test "looksLikePath distinguishes paths from remote specs" {
    try testing.expect(looksLikePath("./skills"));
    try testing.expect(looksLikePath("../skills"));
    try testing.expect(looksLikePath("/abs/skills"));
    try testing.expect(looksLikePath("~/skills"));
    try testing.expect(!looksLikePath("vercel-labs/skills"));
    try testing.expect(!looksLikePath("https://github.com/a/b"));
    try testing.expect(!looksLikePath(""));
}

test "baseName names a root-level skill after the repo, not the temp dir" {
    // Clones land in a temp directory, so the checkout's own name is useless
    // as a skill name; the source has to supply it.
    const src = Source{
        .display = "vercel-labs/agent-skills",
        .location = "https://github.com/vercel-labs/agent-skills.git",
        .is_git = true,
    };
    try testing.expectEqualStrings("agent-skills", src.baseName());

    const with_path = Source{
        .display = "x",
        .location = "https://github.com/a/b.git",
        .sub_path = "skills/web-design",
        .is_git = true,
    };
    try testing.expectEqualStrings("web-design", with_path.baseName());

    const ssh = Source{
        .display = "x",
        .location = "git@github.com:a/b.git",
        .is_git = true,
    };
    try testing.expectEqualStrings("b", ssh.baseName());

    const local = Source{ .display = "x", .location = "/tmp/some/skill" };
    try testing.expectEqualStrings("skill", local.baseName());
}

test "isInside catches a destination nested in its own source" {
    try testing.expect(isInside("/a/b", "/a/b"));
    try testing.expect(isInside("/a/b", "/a/b/c"));
    // A shared prefix is not containment: `/a/bc` is not inside `/a/b`.
    try testing.expect(!isInside("/a/b", "/a/bc"));
    try testing.expect(!isInside("/a/b", "/a"));
    try testing.expect(!isInside("", "/a/b"));
}
