//! Destination picker.
//!
//! `bliz install` used to answer "where does this go?" from flags and directory
//! probing alone, which left the one question worth asking as the one thing you
//! could not answer interactively. This is that question as a prompt: every
//! distinct destination directory in the current scope, the agents that read it,
//! and the same pre-selection a bare install would have made — so `↵` on the
//! opening frame does exactly what `bliz install <source>` always did, and every
//! other answer is one keystroke away.
//!
//! Relative to the skill multiselect (`tui.zig`) two things are simpler and one
//! is different:
//!
//!   * the rows are known before the first frame, so there is no scan and no
//!     loading phase;
//!   * there are only ever two groups, split on whether the destination
//!     directory already exists;
//!   * the row's payload is a *path*, because that is what the choice is about.
//!
//! Scope — where the skill lives, project or global — is a third *view filter*
//! over the same flat item list, in exactly the sense the search query is: the
//! list carries every destination in every scope the caller asked about, each
//! row tagged with where it sits, and the `scope` row at the top decides which
//! half is on screen. That is deliberate. The selection is one array over the
//! whole list, so a user can tick a project destination, switch tabs, tick a
//! global one, and install to both from a single confirmed answer — whereas a
//! filter that rebuilt the row set on every switch would silently drop the
//! first tick.
//!
//! The rendering rules are not re-derived here — `emitRow`/`flush` come from
//! `paint.zig`, which is where the one-line-one-row invariant and the
//! walk-up-over-the-on-screen-frame rule are written down once.

const std = @import("std");
const term = @import("term.zig");
const style = @import("style.zig");
const width = @import("width.zig");
const anim = @import("anim.zig");
const bufmod = @import("buf.zig");
const paint = @import("paint.zig");

pub const Phase = enum { ready, submitting, submitted, cancelled };

pub const Options = struct {
    message: []const u8 = "Install to",
    /// Right-hand side of the header, e.g. "project" or the source being added.
    badge: []const u8 = "",
    detail_lines: usize = 3,
    select_all: bool = true,
    searchable: bool = true,
    /// Refuse to submit with an empty selection; the summary nudges instead.
    require_selection: bool = true,
    /// Force a layout size instead of reading the terminal (used by `record`).
    force_cols: usize = 0,
    force_rows: usize = 0,
    /// The words this prompt uses for the thing it is picking.
    words: Words = .{},
};

/// The nouns and sentences the prompt says about the thing it is picking.
///
/// The prompt was written for *destinations* — the directories an install
/// writes into — so that is what every default here says, and a caller picking
/// something else replaces them. Skills are the second caller: the two
/// decisions want the same affordances (a filter, a select-all, a per-row
/// detail pane, the same frame arithmetic and repaint protocol), so they share
/// one widget with two vocabularies rather than two widgets kept in step by
/// hand.
///
/// A field left empty means "work it out", which is how the two derived
/// strings — the group heading and its detail sentence — keep their
/// scope-dependent destination wording.
pub const Words = struct {
    /// Detail-pane heading while the cursor is on a row.
    row_heading: []const u8 = "Destination",
    /// Singular noun for every count. Pluralised with a plain `s`, which is
    /// why the two must stay in step: a noun whose plural is not `noun + "s"`
    /// would need this split in two.
    count_noun: []const u8 = "destination",
    /// Heading of a group. Empty derives it from the scope and whether the
    /// group's rows already exist.
    group_heading: []const u8 = "",
    /// Detail-pane sentence under a group heading. Empty derives it.
    group_detail: []const u8 = "",
    /// Detail pane while the cursor is on the "Select all" row.
    select_all_detail: []const u8 = "Toggles every destination the filter currently matches.",
    /// Summary line while nothing is checked.
    none_summary: []const u8 = "Selection  none — pick at least one destination",
    /// Drawn in place of the list when the filter matches nothing.
    no_match: []const u8 = "no agent matches that filter",
    /// The key hints under the search box. Empty picks the built-in variant.
    hints: []const u8 = "",
};

/// The skill prompt's vocabulary: `bliz install <source>` choosing which
/// skills to copy out of a source that holds several.
pub const skill_words = Words{
    .row_heading = "Skill",
    .count_noun = "skill",
    .group_heading = "In this source",
    .group_detail = "— space toggles a row, Select all takes every skill the filter matches.",
    .select_all_detail = "Toggles every skill the filter currently matches.",
    .none_summary = "Selection  none — pick at least one skill",
    .no_match = "no skill matches that filter",
    // One group, so the `←→ group` clause in the default has nothing to do.
    .hints = "↑↓ move   space select   tab next   ↵ install   esc cancel",
};

/// Where a destination lives. Project is the current checkout; global is the
/// user's home, shared by every project they open.
pub const Scope = enum {
    project,
    global,

    /// Display order, and the order `buildItems` emits in.
    pub const all = [_]Scope{ .project, .global };

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .project => "project",
            .global => "global",
        };
    }
};

/// One destination directory, after agents sharing it have been merged.
pub const Item = struct {
    /// Registry key of the agent the row is named after.
    key: []const u8,
    /// The row's name — `Codex`, or `Cursor +20` when the directory is shared.
    label: []const u8,
    /// Absolute destination directory.
    root: []const u8,
    /// Shortened form of `root` for the row's right-aligned hint.
    short_root: []const u8,
    /// Display name of every agent that reads this directory, in registry order.
    agents: []const []const u8,
    /// The directory exists in this scope right now.
    detected: bool,
    /// Pre-checked: part of the set a bare `bliz install` would have picked.
    default_on: bool,
    /// Which half of the view this row belongs to.
    scope: Scope,
    /// Detail-pane text for this row, replacing the destination composition
    /// below. One flowing string, not lines: the pane wraps it to the terminal
    /// and a newline would only be re-flowed away. Empty means "compose it
    /// from `root`, `agents` and `detected`", which is what every destination
    /// row does.
    detail: []const u8 = "",
};

/// A registry agent and its resolved destination, before merging.
pub const Candidate = struct {
    key: []const u8,
    display: []const u8,
    root: []const u8,
    short_root: []const u8,
    detected: bool,
    default_on: bool,
    scope: Scope,
};

const Row = struct {
    key: []const u8,
    display: []const u8,
    root: []const u8,
    short_root: []const u8,
    detected: bool,
    default_on: bool,
    scope: Scope,
    names: std.ArrayList([]const u8) = .empty,
};

fn rankOf(c: Candidate) usize {
    // Pre-checked first, then destinations that already exist, then the rest.
    if (c.default_on) return 0;
    if (c.detected) return 1;
    return 2;
}

/// Merges candidates that resolve to the same directory into one row.
///
/// Two agents sharing `.agents/skills` are one decision, not two — installing
/// to both would copy the same files into the same place. The order is scope
/// first, then pre-checked, then existing, then the rest; within a bucket the
/// caller's order is preserved (bucketing rather than sorting, so it is
/// stable), which lets the caller hand over the registry's tier order
/// unchanged.
///
/// Scope is part of the merge key, not just the ordering: `.agents/skills`
/// relative to the checkout and `~/.agents/skills` are two different
/// directories, and a row that merged them would claim to be one decision when
/// it is two.
pub fn buildItems(arena: std.mem.Allocator, cands: []const Candidate) ![]Item {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |*r| r.names.deinit(arena);
        rows.deinit(arena);
    }

    for (Scope.all) |scope| {
        var bucket: usize = 0;
        while (bucket < 3) : (bucket += 1) {
            for (cands) |c| {
                if (c.scope != scope) continue;
                if (rankOf(c) != bucket) continue;
                var merged = false;
                for (rows.items) |*r| {
                    if (r.scope != scope) continue;
                    if (!std.mem.eql(u8, r.root, c.root)) continue;
                    try r.names.append(arena, c.display);
                    r.detected = r.detected or c.detected;
                    r.default_on = r.default_on or c.default_on;
                    merged = true;
                    break;
                }
                if (merged) continue;
                var r = Row{
                    .key = c.key,
                    .display = c.display,
                    .root = c.root,
                    .short_root = c.short_root,
                    .detected = c.detected,
                    .default_on = c.default_on,
                    .scope = c.scope,
                };
                try r.names.append(arena, c.display);
                try rows.append(arena, r);
            }
        }
    }

    const items = try arena.alloc(Item, rows.items.len);
    for (rows.items, 0..) |r, i| {
        const names = try arena.dupe([]const u8, r.names.items);
        items[i] = .{
            .key = r.key,
            .label = if (names.len <= 1)
                r.display
            else
                try std.fmt.allocPrint(arena, "{s} +{d}", .{ r.display, names.len - 1 }),
            .root = r.root,
            .short_root = r.short_root,
            .agents = names,
            .detected = r.detected,
            .default_on = r.default_on,
            .scope = r.scope,
        };
    }
    return items;
}

const Kind = enum { scope, select_all, group, item };

const Entry = struct {
    kind: Kind,
    group: usize = 0,
    item: usize = 0,
};

const GroupView = struct {
    label: []const u8,
    /// Matched item indices, in display order.
    items: []usize,
    /// Every item in the group, matched or not.
    total: usize,
    /// Which of the two groups this is; drives the wording in the detail pane.
    detected: bool,
    collapsed: bool = false,
};

const rail_lo: u8 = 236;
const rail_hi: u8 = 244;

pub const Outcome = union(enum) {
    submitted: []usize,
    cancelled,
};

pub const Prompt = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    opts: Options,

    items: []Item,
    /// Lowercased `label + agents + path` per item, built once. Rebuilding it
    /// per keystroke would make typing O(items × query).
    blob: []const []const u8,
    groups: std.ArrayList(GroupView) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    settled: std.ArrayList(Entry) = .empty,
    matched: std.ArrayList(usize) = .empty,

    /// The scopes actually present in `items`, in `Scope.all` order, and which
    /// of them the view is filtered to. One scope means there is nothing to
    /// switch between, and the scope row is not drawn.
    scopes: [Scope.all.len]Scope = Scope.all,
    scope_n: usize = 0,
    active: usize = 0,

    phase: Phase = .ready,
    /// Frame clock. The driver owns it so recordings are deterministic.
    now: i64 = 0,
    started_ms: i64 = 0,

    query: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    selected: std.ArrayList(bool) = .empty,

    scroll: anim.Spring,
    expand: std.ArrayList(anim.Spring) = .empty,
    radio: std.ArrayList(anim.Spring) = .empty,
    sel_counter: anim.Counter = .{},
    entrance_ms: i64 = 0,
    filter_ms: i64 = 0,
    header_shimmer: anim.Tween,
    detail_anim: anim.Tween,
    detail_key: i64 = -2,
    /// Column count the cached detail text was wrapped for. Part of the cache
    /// key because the wrap width derives from `cols`, so a resize has to
    /// invalidate it even though the cursor has not moved.
    detail_cols: usize = 0,
    /// Selection count the cached detail was built from — part of the cache key
    /// only while the cursor is on a *group* heading, which is the one detail
    /// that reports it. A space toggles rows without moving the cursor, so
    /// keyed on the cursor alone the pane went on saying "0 selected" while the
    /// heading above it said "3/6" and the summary named the three.
    ///
    /// Deliberately not the raw count for every row: that would rebuild — and
    /// re-fade — an item's detail on every keystroke, even though its text does
    /// not depend on the selection at all.
    detail_sel: usize = 0,
    detail_valid: bool = false,
    detail_cache: [max_detail][]const u8 = .{ "", "", "" },
    detail_kind: Kind = .item,
    /// Backing store for the wrapped detail text, reset on every recompute:
    /// the detail is rebuilt on each cursor move, so allocating it from the
    /// long-lived arena would grow without bound.
    detail_arena: std.heap.ArenaAllocator,
    collapse: anim.Tween,
    nudge: anim.Tween,
    flash: std.ArrayList(i64) = .empty,

    cols: usize = 80,
    rows: usize = 24,
    frame: bufmod.Buf,
    row: bufmod.Buf,
    right_buf: [512]u8 = undefined,
    scratch_a: [16]u8 = undefined,
    scratch_b: [16]u8 = undefined,
    /// A row's right-aligned hint is computed while the row body is built and
    /// consumed by `emitRow`.
    pending_right: []const u8 = "",
    pending_right_color: []const u8 = "",
    frame_rows: usize = 0,
    wrote_frame: bool = false,
    painted_rows: usize = 0,
    dirty: bool = true,
    outcome: ?Outcome = null,

    const max_detail = 3;

    pub fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        items: []Item,
        opts_in: Options,
        cwd: []const u8,
    ) Prompt {
        var opts = opts_in;
        opts.detail_lines = @min(opts.detail_lines, max_detail);
        var p = Prompt{
            .arena = arena,
            .gpa = gpa,
            .io = io,
            .env = env,
            .cwd = cwd,
            .opts = opts,
            .items = items,
            .blob = &.{},
            .scroll = anim.Spring.withResponse(0, 150, 24),
            .header_shimmer = .{ .start_ms = 0, .duration_ms = 900 },
            .detail_anim = .{ .start_ms = 0, .duration_ms = 150 },
            .detail_arena = std.heap.ArenaAllocator.init(gpa),
            .collapse = .{ .start_ms = 0, .duration_ms = 280 },
            .nudge = .{ .start_ms = 0, .duration_ms = 300 },
            .frame = bufmod.Buf.init(arena),
            .row = bufmod.Buf.init(arena),
            .cols = if (opts_in.force_cols > 0) opts_in.force_cols else 80,
            .rows = if (opts_in.force_rows > 0) opts_in.force_rows else 24,
        };
        p.blob = p.buildBlob() catch &.{};
        p.scope_n = p.scopesPresent();
        p.reset();
        return p;
    }

    /// The scopes represented in `items`, in display order. Fills `self.scopes`
    /// with just the present ones, so `active` can index it without a gap.
    ///
    /// `buildItems` emits one contiguous block per scope, and the view filter
    /// only ever shows one block, so "the first scope that appears" is also the
    /// one whose rows are at the top of the list — which is what the cursor
    /// starts on.
    fn scopesPresent(self: *Prompt) usize {
        var n: usize = 0;
        for (Scope.all) |s| {
            for (self.items) |it| {
                if (it.scope != s) continue;
                self.scopes[n] = s;
                n += 1;
                break;
            }
        }
        return n;
    }

    pub fn activeScope(self: *const Prompt) Scope {
        if (self.scope_n == 0) return .project;
        return self.scopes[self.active];
    }

    pub fn scopeCount(self: *const Prompt) usize {
        return self.scope_n;
    }

    pub fn deinit(self: *Prompt) void {
        self.groups.deinit(self.arena);
        self.entries.deinit(self.arena);
        self.settled.deinit(self.arena);
        self.matched.deinit(self.arena);
        self.query.deinit(self.arena);
        self.selected.deinit(self.arena);
        self.expand.deinit(self.arena);
        self.radio.deinit(self.arena);
        self.flash.deinit(self.arena);
        self.frame.deinit();
        self.row.deinit();
        self.detail_arena.deinit();
    }

    fn buildBlob(self: *Prompt) ![]const []const u8 {
        const blob = try self.arena.alloc([]const u8, self.items.len);
        for (self.items, 0..) |it, i| {
            var b = bufmod.Buf.init(self.arena);
            b.add(it.label);
            b.add(" ");
            b.add(it.key);
            b.add(" ");
            b.add(it.short_root);
            for (it.agents) |a| {
                b.add(" ");
                b.add(a);
            }
            const lower = try self.arena.alloc(u8, b.len());
            for (b.bytes(), 0..) |c, k| lower[k] = std.ascii.toLower(c);
            blob[i] = lower;
        }
        return blob;
    }

    /// Everything derived from the initial selection: springs, groups, entries.
    fn reset(self: *Prompt) void {
        self.query.clearRetainingCapacity();
        self.entrance_ms = self.now;
        self.filter_ms = self.now - 1000;
        self.cursor = 0;
        self.scroll.snap(0);

        self.selected.clearRetainingCapacity();
        self.radio.clearRetainingCapacity();
        self.flash.clearRetainingCapacity();
        for (self.items) |it| {
            self.selected.append(self.arena, it.default_on) catch {};
            self.radio.append(self.arena, anim.Spring.at(if (it.default_on) 1 else 0)) catch {};
            self.flash.append(self.arena, 0) catch {};
        }

        self.expand.clearRetainingCapacity();
        for (0..2) |_| self.expand.append(self.arena, anim.Spring.at(1)) catch {};

        self.sel_counter.jump(@floatFromInt(self.scopedSelected()));
        self.rebuild();
        self.dirty = true;
    }

    // ------------------------------------------------------------------ scope

    /// Rows that belong to the scope on screen.
    fn scopedTotal(self: *Prompt) usize {
        var n: usize = 0;
        for (self.items) |it| {
            if (it.scope == self.activeScope()) n += 1;
        }
        return n;
    }

    /// Selected rows in the scope on screen. The frame describes what the user
    /// is looking at, so this — not the cross-scope total — is what the
    /// "Select all" counter and the footer count.
    fn scopedSelected(self: *Prompt) usize {
        var n: usize = 0;
        for (self.selected.items, 0..) |s, i| {
            if (s and self.items[i].scope == self.activeScope()) n += 1;
        }
        return n;
    }

    /// Selections in the scope that is *not* on screen. The summary line is the
    /// one place that reports these, because otherwise a tick made on the other
    /// tab would be invisible until the install already happened.
    fn otherScopeSelected(self: *Prompt) usize {
        return self.selectionCount() - self.scopedSelected();
    }

    fn scopeIndex(self: *Prompt, s: Scope) ?usize {
        for (self.scopes[0..self.scope_n], 0..) |v, i| {
            if (v == s) return i;
        }
        return null;
    }

    /// Switches which half of the list is on screen.
    ///
    /// The selection deliberately survives: it lives on the flat item list, not
    /// on this view. Everything derived from the filter is dropped and rebuilt,
    /// and the entrance stagger is replayed so the new rows fade in rather than
    /// appearing as a jump cut.
    pub fn setScope(self: *Prompt, s: Scope) void {
        const idx = self.scopeIndex(s) orelse return;
        if (idx == self.active) return;
        self.active = idx;
        self.filter_ms = self.now;
        self.scroll.snap(0);
        self.cursor = 0;
        // The detail pane is cached on the cursor, which does not move here, so
        // it would keep describing the scope that just left the screen.
        self.detail_valid = false;
        self.rebuild();
    }

    fn cycleScope(self: *Prompt, delta: i32) void {
        if (self.scope_n < 2) return;
        const n: i32 = @intCast(self.scope_n);
        const next: i32 = @mod(@as(i32, @intCast(self.active)) + delta, n);
        self.setScope(self.scopes[@intCast(next)]);
    }

    // ----------------------------------------------------------------- groups

    /// The wording the two group headings get, which depends on the scope on
    /// screen: "in this project" and "installed on this machine" are the same
    /// fact stated two different ways, and getting it wrong makes the heading
    /// lie about where the rows are.
    fn groupLabel(self: *Prompt, detected: bool) []const u8 {
        // A caller with a single group — the skill prompt has one, because a
        // skill is either in the source or is not — names it outright; the
        // destination prompt names it per scope and per whether the directory
        // already exists.
        if (self.opts.words.group_heading.len > 0) return self.opts.words.group_heading;
        return switch (self.activeScope()) {
            .project => if (detected) "In this project" else "Not here yet",
            .global => if (detected) "Installed" else "Not installed",
        };
    }

    /// Recomputes the filter, the groups and the entry list in one pass.
    ///
    /// The scope participates in the filter exactly like the query does, but
    /// unlike the query it is never empty: every item belongs to one scope and
    /// the view always shows exactly one.
    fn rebuild(self: *Prompt) void {
        self.matched.clearRetainingCapacity();
        const q = self.query.items;
        const scope = self.activeScope();
        for (self.blob, 0..) |hay, i| {
            if (self.items[i].scope != scope) continue;
            if (q.len == 0 or containsAll(hay, q)) {
                self.matched.append(self.arena, i) catch {};
            }
        }

        self.groups.clearRetainingCapacity();
        var detected: std.ArrayList(usize) = .empty;
        var fresh: std.ArrayList(usize) = .empty;
        for (self.matched.items) |i| {
            if (self.items[i].detected) {
                detected.append(self.arena, i) catch {};
            } else {
                fresh.append(self.arena, i) catch {};
            }
        }
        // The "N of M" on a heading counts what the scope holds, so the total
        // has to ignore the other scope's rows.
        var total_detected: usize = 0;
        var total_fresh: usize = 0;
        for (self.items) |it| {
            if (it.scope != scope) continue;
            if (it.detected) total_detected += 1 else total_fresh += 1;
        }
        if (detected.items.len > 0) {
            self.groups.append(self.arena, .{
                .label = self.groupLabel(true),
                .items = detected.toOwnedSlice(self.arena) catch &.{},
                .total = total_detected,
                .detected = true,
            }) catch {};
        }
        if (fresh.items.len > 0) {
            self.groups.append(self.arena, .{
                .label = self.groupLabel(false),
                .items = fresh.toOwnedSlice(self.arena) catch &.{},
                .total = total_fresh,
                .detected = false,
            }) catch {};
        }

        self.buildEntries(false);
        self.buildEntries(true);
        self.clampCursor();
        self.dirty = true;
    }

    fn buildEntries(self: *Prompt, animated: bool) void {
        const list = if (animated) &self.entries else &self.settled;
        list.clearRetainingCapacity();
        // The two head rows are fixed controls drawn outside the scrolling
        // list, so only the settled list carries a placeholder for them. That
        // is what keeps `cursorOffset` a constant difference between the two
        // lists instead of one that varies per row.
        if (!animated) {
            if (self.showScopeRow()) list.append(self.arena, .{ .kind = .scope }) catch {};
            if (self.showSelectAll()) list.append(self.arena, .{ .kind = .select_all }) catch {};
        }
        for (self.groups.items, 0..) |group, gi| {
            if (group.items.len == 0) continue;
            list.append(self.arena, .{ .kind = .group, .group = gi }) catch {};
            const shown = self.shownChildren(gi, animated);
            var k: usize = 0;
            while (k < shown and k < group.items.len) : (k += 1) {
                list.append(self.arena, .{ .kind = .item, .group = gi, .item = group.items[k] }) catch {};
            }
        }
    }

    /// Children materialise as the group's spring opens, so collapsing animates
    /// the count down instead of yanking rows out.
    fn shownChildren(self: *Prompt, gi: usize, animated: bool) usize {
        const group = self.groups.items[gi];
        if (!animated) return group.items.len;
        const p = self.expand.items[gi].value;
        // Round up, so the first frame of the animation already shows one child
        // rather than an empty group with a heading.
        return @intFromFloat(@as(f32, @floatFromInt(group.items.len)) * p + 0.999);
    }

    fn clampCursor(self: *Prompt) void {
        const max = if (self.settled.items.len == 0) 0 else self.settled.items.len - 1;
        if (self.cursor > max) self.cursor = max;
    }

    /// How many fixed rows sit above the scrolling list. Both are placeholders
    /// in the settled list and absent from the animated one, which is what
    /// makes this a constant offset rather than a per-row mapping.
    fn cursorOffset(self: *Prompt) usize {
        return (if (self.showScopeRow()) @as(usize, 1) else 0) +
            (if (self.showSelectAll()) @as(usize, 1) else 0);
    }

    pub fn selectionCount(self: *Prompt) usize {
        var n: usize = 0;
        for (self.selected.items) |s| {
            if (s) n += 1;
        }
        return n;
    }

    /// Indices of the checked rows, in display order.
    pub fn selectionIndices(self: *Prompt) []const usize {
        var list: std.ArrayList(usize) = .empty;
        for (self.selected.items, 0..) |s, i| {
            if (s) list.append(self.arena, i) catch {};
        }
        return list.items;
    }

    // ------------------------------------------------------------------ input

    pub fn handleInput(self: *Prompt, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const c = bytes[i];
            if (c == 0x1b) {
                if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                    var j = i + 2;
                    while (j < bytes.len and !(bytes[j] >= 0x40 and bytes[j] <= 0x7e)) : (j += 1) {}
                    if (j < bytes.len) {
                        self.handleCsi(bytes[j], bytes[i + 2 .. j]);
                        i = j + 1;
                        continue;
                    }
                }
                self.cancel();
                return;
            }
            switch (c) {
                0x0d, 0x0a => self.submit(),
                0x03 => {
                    self.cancel();
                    return;
                },
                0x20 => self.toggleCursor(),
                0x09 => self.jumpGroup(),
                0x7f, 0x08 => self.deleteQueryChar(),
                0x15 => self.clearQuery(),
                0x17 => self.deleteQueryWord(),
                0x01 => self.toggleAll(),
                0x10 => self.move(-1),
                0x0e => self.move(1),
                else => {
                    if (self.opts.searchable and c >= 0x20) {
                        self.query.append(self.arena, c) catch {};
                        self.onQueryChanged();
                    }
                },
            }
            i += 1;
        }
    }

    fn handleCsi(self: *Prompt, final: u8, params: []const u8) void {
        switch (final) {
            'A' => self.move(-1),
            'B' => self.move(1),
            'C' => self.setGroupExpanded(true),
            'D' => self.setGroupExpanded(false),
            'H' => self.setCursor(0),
            'F' => self.setCursor(self.settled.items.len),
            '~' => {
                if (std.mem.eql(u8, params, "5")) {
                    self.page(-1);
                } else if (std.mem.eql(u8, params, "6")) {
                    self.page(1);
                } else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) {
                    self.setCursor(0);
                } else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) {
                    self.setCursor(self.settled.items.len);
                }
            },
            else => {},
        }
    }

    /// The first entry that belongs to the list proper, skipping the fixed head
    /// controls.
    ///
    /// A filter change lands the cursor here rather than on the scope switch:
    /// typing narrows the rows, so the next keystroke should act on a row, and
    /// a space that silently flipped scope halfway through a search would be
    /// the worst kind of surprise. The head rows stay one `↑` away.
    fn firstListEntry(self: *Prompt) usize {
        for (self.settled.items, 0..) |e, i| {
            switch (e.kind) {
                .scope, .select_all => {},
                else => return i,
            }
        }
        // Nothing survived the filter: park on the first control, which at
        // least lets the user switch scope and look somewhere else.
        return 0;
    }

    fn onQueryChanged(self: *Prompt) void {
        self.rebuild();
        self.filter_ms = self.now;
        self.cursor = self.firstListEntry();
        self.scroll.snap(0);
    }

    fn clearQuery(self: *Prompt) void {
        if (self.query.items.len == 0) return;
        self.query.clearRetainingCapacity();
        self.onQueryChanged();
    }

    fn deleteQueryChar(self: *Prompt) void {
        if (self.query.items.len == 0) return;
        var n = self.query.items.len - 1;
        while (n > 0 and (self.query.items[n] & 0xC0) == 0x80) : (n -= 1) {}
        self.query.shrinkRetainingCapacity(n);
        self.onQueryChanged();
    }

    fn deleteQueryWord(self: *Prompt) void {
        var n = self.query.items.len;
        while (n > 0 and self.query.items[n - 1] == ' ') : (n -= 1) {}
        while (n > 0 and self.query.items[n - 1] != ' ') : (n -= 1) {}
        self.query.shrinkRetainingCapacity(n);
        self.onQueryChanged();
    }

    fn move(self: *Prompt, delta: i32) void {
        const len = self.settled.items.len;
        if (len == 0) return;
        var next: i32 = @as(i32, @intCast(self.cursor)) + delta;
        if (next < 0) next = 0;
        if (next >= @as(i32, @intCast(len))) next = @intCast(len - 1);
        self.setCursor(@intCast(next));
    }

    fn page(self: *Prompt, dir: i32) void {
        const step: i32 = @intCast(@max(1, self.listHeight()));
        self.move(dir * step);
    }

    fn setCursor(self: *Prompt, index: usize) void {
        const max = if (self.settled.items.len == 0) 0 else self.settled.items.len - 1;
        self.cursor = @min(index, max);
        self.dirty = true;
    }

    fn jumpGroup(self: *Prompt) void {
        var i = self.cursor + 1;
        while (i < self.settled.items.len) : (i += 1) {
            if (self.settled.items[i].kind == .group) {
                self.setCursor(i);
                return;
            }
        }
        self.setCursor(0);
    }

    fn setGroupExpanded(self: *Prompt, expanded: bool) void {
        if (self.cursor >= self.settled.items.len) return;
        const entry = self.settled.items[self.cursor];
        // On the scope row `←`/`→` pick the scope directly. It is the same
        // gesture as opening a group — left/right chooses — so the row does not
        // need a key of its own to be discoverable.
        if (entry.kind == .scope) {
            self.cycleScope(if (expanded) 1 else -1);
            return;
        }
        if (entry.kind == .select_all) return;
        const gi = entry.group;
        self.groups.items[gi].collapsed = !expanded;
        // Collapsing from inside the group has to land the cursor on its
        // heading, or the cursor would point at a row that no longer exists.
        if (!expanded) {
            for (self.settled.items, 0..) |e, i| {
                if (e.kind == .group and e.group == gi) {
                    self.cursor = i;
                    break;
                }
            }
        }
        self.rebuild();
    }

    fn toggleCursor(self: *Prompt) void {
        if (self.cursor >= self.settled.items.len) return;
        const entry = self.settled.items[self.cursor];
        switch (entry.kind) {
            // Space on the scope row advances to the next scope, the same way
            // space on a destination row flips it. `↵` still submits from
            // anywhere, so the opening frame's promise is untouched.
            .scope => self.cycleScope(1),
            .select_all => self.toggleAll(),
            .group => {
                var all = true;
                for (self.groups.items[entry.group].items) |i| {
                    if (!self.selected.items[i]) all = false;
                }
                for (self.groups.items[entry.group].items) |i| {
                    self.selected.items[i] = !all;
                    self.flash.items[i] = self.now + 260;
                }
            },
            .item => {
                self.selected.items[entry.item] = !self.selected.items[entry.item];
                self.flash.items[entry.item] = self.now + 260;
            },
        }
        self.dirty = true;
    }

    fn toggleAll(self: *Prompt) void {
        const clear = self.selectAllState() == .all;
        // Toggling "all" acts on what the filter currently matches, which is
        // what the counter above it reports.
        for (self.matched.items) |i| {
            self.selected.items[i] = !clear;
            self.flash.items[i] = self.now + 260;
        }
        self.dirty = true;
    }

    const AllState = enum { none, partial, all };

    fn selectAllState(self: *Prompt) AllState {
        const n = self.matched.items.len;
        if (n == 0) return .none;
        var c: usize = 0;
        for (self.matched.items) |i| {
            if (self.selected.items[i]) c += 1;
        }
        if (c == 0) return .none;
        if (c == n) return .all;
        return .partial;
    }

    fn submit(self: *Prompt) void {
        if (self.phase != .ready) return;
        if (self.opts.require_selection and self.selectionCount() == 0) {
            self.nudge.begin(self.now);
            self.dirty = true;
            return;
        }
        self.phase = .submitting;
        self.collapse.begin(self.now);
        self.dirty = true;
    }

    fn cancel(self: *Prompt) void {
        if (self.phase == .submitted or self.phase == .cancelled) return;
        self.phase = .cancelled;
        // The outcome is set here rather than after a repaint: nothing else
        // would ever set it, and the driver loops until it sees one.
        self.outcome = .cancelled;
        self.dirty = true;
    }

    // --------------------------------------------------------------- animation

    /// Integrates every spring. `dt` is the real frame delta, in seconds.
    pub fn update(self: *Prompt, dt: f32) void {
        self.scroll.setTarget(self.scrollTarget());
        self.scroll.step(dt);

        for (self.groups.items, 0..) |group, i| {
            if (i >= self.expand.items.len) break;
            self.expand.items[i].setTarget(if (group.collapsed) 0 else 1);
            self.expand.items[i].step(dt);
        }
        // The child count on screen is a function of those springs, so the entry
        // lists have to be resampled after they move.
        self.refreshEntries();
        for (self.selected.items, 0..) |s, i| {
            self.radio.items[i].setTarget(if (s) 1 else 0);
            self.radio.items[i].step(dt);
        }
        // The counter beside "Select all" counts the scope on screen, so
        // switching tabs tweens it — which is the only cue that the other tab
        // has a selection of its own.
        self.sel_counter.set(@floatFromInt(self.scopedSelected()));
        self.sel_counter.step(dt);

        if (self.phase == .submitting and self.collapse.done(self.now)) {
            self.phase = .submitted;
            const out = self.arena.alloc(usize, self.selectionCount()) catch null;
            if (out) |slice| {
                var k: usize = 0;
                for (self.selected.items, 0..) |s, i| {
                    if (s) {
                        slice[k] = i;
                        k += 1;
                    }
                }
            }
            self.outcome = .{ .submitted = out orelse &.{} };
            self.dirty = true;
        }
    }

    /// Rebuilds the entry lists without touching the filter. Called after the
    /// springs move, because how many children a group shows is a function of
    /// its expand spring.
    pub fn refreshEntries(self: *Prompt) void {
        self.buildEntries(false);
        self.buildEntries(true);
        self.clampCursor();
        self.dirty = true;
    }

    fn scrollTarget(self: *Prompt) f32 {
        const h = self.listHeight();
        const total = self.entries.items.len;
        if (h == 0 or total <= h) return 0;
        const cur: f32 = @floatFromInt(self.cursor -| self.cursorOffset());
        var t = cur - @as(f32, @floatFromInt(h)) / 2.0 + 0.5;
        const max = @as(f32, @floatFromInt(total - h));
        if (t < 0) t = 0;
        if (t > max) t = max;
        return t;
    }

    /// True while anything is still moving. The driver uses this to decide
    /// whether a frame needs emitting at all, which is why an idle prompt
    /// sitting in `poll()` writes nothing and burns no CPU.
    pub fn wantsAnimation(self: *Prompt) bool {
        if (self.phase == .submitting) return true;
        if (!self.scroll.settled()) return true;
        if (self.sel_counter.moving()) return true;
        if (self.header_shimmer.active(self.now)) return true;
        if (self.nudge.active(self.now)) return true;
        if (self.detail_anim.active(self.now)) return true;
        for (self.expand.items) |s| {
            if (!s.settled()) return true;
        }
        for (self.radio.items) |s| {
            if (!s.settled()) return true;
        }
        for (self.flash.items) |t| {
            if (self.now < t) return true;
        }
        const since = self.now - self.filter_ms;
        if (since >= 0 and since < 240) return true;
        return false;
    }

    // ----------------------------------------------------------------- layout

    // Each gate below is read by exactly one `render*` function and by
    // `listHeight`, so the row arithmetic and the emit plan cannot drift apart.
    // A short terminal gives its rows to the list and drops the decoration,
    // because a frame taller than the screen would scroll and desync the
    // repaint for the rest of the session.

    fn showSearchRow(self: *Prompt) bool {
        return self.opts.searchable and self.rows >= 5;
    }

    fn showHints(self: *Prompt) bool {
        return self.rows >= 16;
    }

    /// The scope row is a control rather than a destination, and it sits above
    /// "Select all". It only exists when the caller offered more than one
    /// scope: a segment with one option is not a choice.
    fn showScopeRow(self: *Prompt) bool {
        return self.scope_n > 1 and self.rows >= 10;
    }

    fn showSelectAll(self: *Prompt) bool {
        return self.opts.select_all and self.rows >= 11;
    }

    fn showDetail(self: *Prompt) bool {
        return self.rows >= 18;
    }

    fn showSummary(self: *Prompt) bool {
        return self.rows >= 8;
    }

    fn showFooter(self: *Prompt) bool {
        return self.rows >= 9;
    }

    fn detailRows(self: *Prompt) usize {
        return if (self.showDetail()) self.opts.detail_lines else 0;
    }

    /// Rows the list gets, derived from the emit plan. Every fixed row counted
    /// here is emitted exactly once by `render`, so the frame is always one row
    /// shorter than the terminal.
    fn listHeight(self: *Prompt) usize {
        var chrome: usize = 1; // header
        chrome += if (self.showSearchRow()) 3 else 1; // blank [+ search + blank]
        if (self.showHints()) chrome += 1;
        if (self.showScopeRow()) chrome += 1;
        if (self.showSelectAll()) chrome += 1;
        chrome += 1; // separator
        const d = self.detailRows();
        if (d > 0) chrome += 1 + d;
        if (self.showSummary()) chrome += 1;
        if (self.showFooter()) chrome += 1;
        if (self.rows > chrome + 1) return self.rows - chrome - 1;
        return 1;
    }

    pub fn setSize(self: *Prompt, cols: usize, rows: usize) void {
        if (cols == self.cols and rows == self.rows) return;
        self.cols = cols;
        self.rows = rows;
        self.detail_valid = false;
        self.dirty = true;
    }

    // ----------------------------------------------------------------- render

    pub fn render(self: *Prompt) void {
        self.frame.clear();

        if (self.phase == .cancelled) {
            self.renderHeader(0);
            self.row.clear();
            self.row.add("  ");
            self.row.add(term.STRIKE);
            self.row.add(style.DIM);
            self.row.add("cancelled");
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            self.frame_rows = paint.countRows(self.frame.bytes());
            self.dirty = false;
            return;
        }

        if (self.phase == .submitted) {
            self.renderHeader(1.0);
            self.row.clear();
            self.row.add("  ");
            const n = self.selectionCount();
            if (n == 0) {
                self.row.add(style.DIM);
                self.row.add("nothing selected");
            } else {
                self.row.add(style.mixAt(&self.scratch_a, 240, 250, 1.0));
                self.row.addFmt("{d} destination{s} selected", .{ n, if (n == 1) "" else "s" });
            }
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            self.frame_rows = paint.countRows(self.frame.bytes());
            self.dirty = false;
            return;
        }

        const collapse_p = if (self.phase == .submitting) self.collapse.progress(self.now) else 0.0;
        const alpha = 1.0 - collapse_p;

        self.renderHeader(collapse_p);
        if (alpha > 0.02) {
            self.renderSearch();
            if (self.showScopeRow()) self.renderScope(alpha);
            if (self.showSelectAll()) self.renderSelectAll(alpha);
            self.renderSeparator(alpha);
            self.renderList(alpha);
            if (self.detailRows() > 0) self.renderDetail(alpha);
            if (self.showSummary()) self.renderSummary(alpha);
            if (self.showFooter()) self.renderFooter(alpha);
        }
        self.frame_rows = paint.countRows(self.frame.bytes());
        self.dirty = false;
    }

    fn emitRow(self: *Prompt, right: []const u8, right_color: []const u8, offset: f32) void {
        paint.emitRow(self.arena, &self.frame, &self.row, self.cols, right, right_color, offset);
    }

    fn emitRowRightRow(self: *Prompt) void {
        const right = self.pending_right;
        const color = self.pending_right_color;
        self.pending_right = "";
        self.pending_right_color = "";
        self.emitRow(right, color, 0);
    }

    fn rail(self: *Prompt) void {
        self.row.add(self.railColor());
        self.row.add(style.SEP);
        self.row.add(term.RESET);
    }

    fn railColor(self: *Prompt) []const u8 {
        return style.mixAt(&self.scratch_b, rail_lo, rail_hi, 0.4);
    }

    fn hRepeat(self: *Prompt, s: []const u8, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.row.add(s);
    }

    fn renderHeader(self: *Prompt, collapse_p: f32) void {
        self.row.clear();
        const symbol = switch (self.phase) {
            .ready, .submitting => style.DIAMOND_ACTIVE,
            .submitted => style.DIAMOND_SUBMIT,
            .cancelled => style.DIAMOND_CANCEL,
        };
        const symbol_color = switch (self.phase) {
            .cancelled => style.RED,
            .submitted => style.GREEN,
            else => style.ACCENT,
        };
        self.row.add(symbol_color);
        self.row.add(symbol);
        self.row.add(term.RESET);
        self.row.add("  ");

        const text = self.opts.message;
        if (self.header_shimmer.active(self.now)) {
            const p = self.header_shimmer.raw(self.now);
            // One SGR per *run* of equal intensity rather than per character:
            // adjacent characters almost always land on the same ramp step, so
            // this cuts the frame by roughly an order of magnitude.
            var i: usize = 0;
            while (i < text.len) {
                const run_index = style.mixIndex(247, 255, 0.35 + anim.shimmer(i, text.len, p, 8.0) * 0.65);
                var end = i;
                while (end < text.len) {
                    const ch_len = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
                    end = @min(end + ch_len, text.len);
                    if (end >= text.len) break;
                    const probe = style.mixIndex(247, 255, 0.35 + anim.shimmer(end, text.len, p, 8.0) * 0.65);
                    if (probe != run_index) break;
                }
                self.row.add(term.BOLD);
                self.row.add(style.color256(&self.scratch_a, run_index));
                self.row.add(text[i..end]);
                self.row.add(term.RESET);
                i = end;
            }
        } else {
            self.row.add(term.BOLD);
            self.row.add(style.TEXT);
            self.row.add(text);
            self.row.add(term.RESET);
        }

        const status = switch (self.phase) {
            .submitted => "done",
            .cancelled => "cancelled",
            else => self.opts.badge,
        };
        self.emitRow(status, style.DIM, collapse_p * 8.0);
    }

    fn renderSearch(self: *Prompt) void {
        self.rail();
        self.emitRow("", style.DIM, 0);
        if (!self.showSearchRow()) return;

        self.rail();
        self.row.add("  ");
        self.row.add(style.FAINT);
        self.row.add("⌕ ");
        self.row.add(term.RESET);
        const q = self.query.items;
        if (q.len == 0) {
            self.row.add(style.mixAt(&self.scratch_a, 236, 239, 0.9));
            self.row.add("type to filter");
            self.row.add(term.RESET);
        } else {
            const avail = if (self.cols > 8) self.cols - 8 else 0;
            const shown = if (width.width(q) > avail) q[width.floorBoundary(q, q.len -% avail)..] else q;
            self.row.add(style.TEXT);
            self.row.add(shown);
            self.row.add(term.RESET);
        }
        if (self.phase == .ready and @mod(self.now, 1060) < 660) {
            self.row.add(style.ACCENT);
            self.row.add(style.CARET);
            self.row.add(term.RESET);
        }
        const count = std.fmt.bufPrint(&self.right_buf, "{d} match{s}", .{
            self.matched.items.len,
            if (self.matched.items.len == 1) "" else "es",
        }) catch "";
        self.emitRow(count, style.FAINT, 0);

        if (self.showHints()) {
            self.rail();
            self.row.add("  ");
            self.row.add(style.mixAt(&self.scratch_a, 238, 242, 0.9));
            self.row.add(if (self.opts.words.hints.len > 0)
                self.opts.words.hints
            else if (self.showScopeRow())
                "↑↓ move   space select   ←→ group/scope   tab next   ↵ install   esc cancel"
            else
                "↑↓ move   space select   ←→ group   tab next   ↵ install   esc cancel");
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
        }

        self.rail();
        self.emitRow("", style.DIM, 0);
    }

    fn renderSeparator(self: *Prompt, alpha: f32) void {
        self.rail();
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 234, 239, alpha));
        self.hRepeat(style.SEP_H, if (self.cols > 3) self.cols - 3 else 1);
        self.row.add(term.RESET);
        self.emitRow("", style.DIM, 0);
    }

    /// The scope switch: one focusable row holding both choices.
    ///
    /// It is deliberately the same idiom as the "Select all" row — a control
    /// parked above the list — so it inherits the cursor, the nudge and the
    /// frame arithmetic instead of being a widget with its own rules. The two
    /// segments reuse the destination radio, because "which scope" and "which
    /// rows" are the same kind of decision and should look it.
    fn renderScope(self: *Prompt, alpha: f32) void {
        const is_cursor = self.headCursor(0);
        self.rail();
        self.row.add(" ");
        self.cursorGlyph(is_cursor);
        self.row.add(" ");
        self.placeholderConnector(alpha);

        // Below ~46 columns the label is the first thing to go: the segments
        // say "project"/"global" by themselves, and a truncated "sco" would
        // cost the same cells for less meaning.
        if (self.cols >= 46) {
            if (is_cursor) self.row.add(term.UNDERLINE);
            self.row.add(term.BOLD);
            self.row.add(style.mixAt(&self.scratch_a, 240, 252, if (is_cursor) 1.0 else 0.85 * alpha + 0.15));
            self.row.add("scope");
            self.row.add(term.RESET);
            self.row.add("  ");
        }

        for (self.scopes[0..self.scope_n], 0..) |s, i| {
            const on = i == self.active;
            if (i > 0) self.row.add("   ");
            self.radioGlyph(if (on) 1.0 else 0.0, on, 0, 1.0, alpha);
            if (is_cursor and on) self.row.add(term.UNDERLINE);
            if (on) self.row.add(term.BOLD);
            self.row.add(style.mixAt(
                &self.scratch_a,
                if (on) @as(u8, 246) else 238,
                if (is_cursor and on) @as(u8, 255) else 244,
                if (on) 1.0 else 0.75 * alpha + 0.25,
            ));
            self.row.add(s.label());
            self.row.add(term.RESET);
        }

        self.emitRow(self.scopeRoot(), style.mixAt(&self.scratch_b, 236, 241, alpha), self.nudgeOffset() * 3.0);
    }

    /// What the scope on screen resolves to, for the row's right-hand hint.
    /// Project is the checkout the command was run from; global is the user's
    /// home, which `~` states exactly rather than approximately. The detail pane
    /// is where the difference is actually explained.
    fn scopeRoot(self: *Prompt) []const u8 {
        if (self.activeScope() == .project) return self.cwd;
        return "~";
    }

    /// True when the cursor is on the `n`-th fixed head row. The head rows are
    /// drawn outside the scrolling list, so unlike a list entry they cannot
    /// work out their own focus from `cursorOffset` — and getting it wrong
    /// paints the cursor on two rows at once.
    fn headCursor(self: *Prompt, n: usize) bool {
        return self.cursor == n;
    }

    /// The index of the "Select all" row among the head rows: 1 once the scope
    /// switch is above it, 0 when it is the only control.
    fn selectAllRow(self: *Prompt) usize {
        return if (self.showScopeRow()) 1 else 0;
    }

    fn renderSelectAll(self: *Prompt, alpha: f32) void {
        const is_cursor = self.headCursor(self.selectAllRow());
        self.rail();
        self.row.add(" ");
        self.cursorGlyph(is_cursor);
        self.row.add(" ");
        self.placeholderConnector(alpha);

        const state = self.selectAllState();
        const fill: f32 = switch (state) {
            .all => 1.0,
            .partial => 0.5,
            .none => 0.0,
        };
        self.radioGlyph(fill, state != .none, 0, 1.0, alpha);

        if (is_cursor) self.row.add(term.UNDERLINE);
        self.row.add(term.BOLD);
        self.row.add(style.mixAt(&self.scratch_a, 240, 252, if (is_cursor) 1.0 else 0.85 * alpha + 0.15));
        self.row.add("Select all");
        self.row.add(term.RESET);

        const right = std.fmt.bufPrint(&self.right_buf, "{d}/{d}", .{
            self.sel_counter.value(), self.scopedTotal(),
        }) catch "";
        self.emitRow(right, style.DIM, self.nudgeOffset() * 3.0);
    }

    fn nudgeOffset(self: *Prompt) f32 {
        if (!self.nudge.active(self.now)) return 0;
        const p = self.nudge.progress(self.now);
        return @sin(p * 6.283 * 2.5) * (1.0 - p);
    }

    fn cursorGlyph(self: *Prompt, active: bool) void {
        if (active) {
            const pulse = 0.85 + 0.15 * @sin(@as(f32, @floatFromInt(@mod(self.now, 800))) / 800.0 * 6.283);
            self.row.add(style.mixAt(&self.scratch_a, 39, 51, pulse));
            self.row.add(style.CURSOR);
        } else {
            self.row.add(" ");
        }
        self.row.add(term.RESET);
    }

    /// Three-cell slot between the cursor and the radio, so every radio lands
    /// in the same column whether the row is a heading or a destination.
    fn connector(self: *Prompt, kind: Kind, collapsed: bool, is_last: bool, fade: f32, alpha: f32) void {
        self.row.add(style.mixAt(&self.scratch_b, 236, 240, fade * alpha));
        switch (kind) {
            .group => {
                self.row.add(if (collapsed) style.COLLAPSED else style.EXPANDED);
                self.row.add("  ");
            },
            .item => {
                self.row.add(if (is_last) style.TREE_END else style.TREE_MID);
                self.row.add(" ");
            },
            else => self.row.add("   "),
        }
        self.row.add(term.RESET);
    }

    fn placeholderConnector(self: *Prompt, alpha: f32) void {
        self.row.add(style.mixAt(&self.scratch_b, 236, 240, alpha));
        self.row.add("   ");
        self.row.add(term.RESET);
    }

    /// The radio marker, animated: a toggled row fills through four frames
    /// instead of snapping, and briefly flares brighter.
    fn radioGlyph(self: *Prompt, fill: f32, selected: bool, flash_until: i64, fade: f32, alpha: f32) void {
        const step: usize = @intFromFloat(std.math.clamp(fill, 0.0, 1.0) * 4.0 + 0.5);
        if (selected and self.now < flash_until) {
            self.row.add(style.mixAt(&self.scratch_a, 42, 51, flashAlpha(flash_until, self.now)));
        } else if (selected) {
            self.row.add(style.GREEN);
        } else if (step == 2) {
            self.row.add(style.AMBER);
        } else {
            self.row.add(style.mixAt(&self.scratch_a, 238, 243, fade * alpha));
        }
        self.row.add(style.RADIO_FILL[step]);
        self.row.add(term.RESET);
        self.row.add(" ");
    }

    fn renderList(self: *Prompt, alpha: f32) void {
        const lh = self.listHeight();
        const total = self.entries.items.len;

        if (total == 0) {
            self.rail();
            self.row.add("  ");
            self.row.add(style.mixAt(&self.scratch_a, 240, 245, alpha));
            self.row.add(self.opts.words.no_match);
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            var k: usize = 1;
            while (k < lh) : (k += 1) {
                self.rail();
                self.emitRow("", style.DIM, 0);
            }
            return;
        }

        const start: usize = @intFromFloat(@max(0.0, @floor(self.scroll.value)));
        const end = @min(total, start + lh);
        const has_above = start > 0;
        const has_below = end < total;
        const offset = self.cursorOffset();

        var i = start;
        while (i < end) : (i += 1) {
            const entry = self.entries.items[i];
            const is_cursor = i + offset == self.cursor;
            const edge = (i == start and has_above) or (i == end - 1 and has_below);
            var fade: f32 = if (edge) 0.55 else 1.0;
            fade *= self.entranceAlpha(i);
            if (is_cursor) fade = 1.0;

            self.pending_right = "";
            self.pending_right_color = "";
            self.rail();
            self.row.add(" ");
            self.cursorGlyph(is_cursor);
            self.row.add(" ");
            switch (entry.kind) {
                .item => self.renderItemRow(entry, is_cursor, fade, alpha),
                .group => self.renderGroupRow(entry, is_cursor, fade, alpha),
                // The two head rows are drawn fixed above the list; their
                // entries exist only to give the cursor something to point at,
                // so what the list owes them is a spacer of the same height.
                .scope, .select_all => {},
            }
            self.emitRowRightRow();
        }

        var k = end - start;
        while (k < lh) : (k += 1) {
            self.rail();
            self.emitRow("", style.DIM, 0);
        }
    }

    fn entranceAlpha(self: *Prompt, index: usize) f32 {
        var a = anim.stagger(index, self.now, self.filter_ms, 3, 70, 14);
        a = @max(a, anim.stagger(index, self.now, self.entrance_ms, 5, 90, 12));
        return @max(a, 0.02);
    }

    fn renderItemRow(self: *Prompt, entry: Entry, is_cursor: bool, fade: f32, alpha: f32) void {
        const it = self.items[entry.item];
        const group = self.groups.items[entry.group];
        const pos = indexIn(group.items, entry.item);
        const is_last = pos + 1 == group.items.len;

        self.connector(.item, false, is_last, fade, alpha);

        const selected = self.selected.items[entry.item];
        const rp = self.radio.items[entry.item].value;
        self.radioGlyph(rp, selected, self.flash.items[entry.item], fade, alpha);

        if (is_cursor) self.row.add(term.UNDERLINE);
        if (selected) self.row.add(term.BOLD);
        self.row.add(style.mixAt(&self.scratch_a, if (selected) @as(u8, 246) else 240, if (is_cursor) @as(u8, 255) else 250, if (is_cursor) 1.0 else fade * alpha));
        self.row.add(it.label);
        self.row.add(term.RESET);

        // A destination nobody is looking at yet is worth flagging, because the
        // install would create the directory — that is the one thing this
        // prompt can do that is not trivially reversible.
        if (!it.detected) {
            self.row.add(" ");
            self.row.add(style.mixAt(&self.scratch_a, 240, 214, fade * alpha));
            self.row.add("new");
            self.row.add(term.RESET);
        }
        self.pending_right = it.short_root;
        self.pending_right_color = style.mixAt(&self.scratch_b, 236, 243, fade * alpha);
    }

    fn renderGroupRow(self: *Prompt, entry: Entry, is_cursor: bool, fade: f32, alpha: f32) void {
        const gi = entry.group;
        const group = self.groups.items[gi];

        self.connector(.group, group.collapsed, false, fade, alpha);

        var sel_n: usize = 0;
        for (group.items) |i| {
            if (self.selected.items[i]) sel_n += 1;
        }
        const full = sel_n == group.total and group.total > 0;
        const partial = sel_n > 0 and !full;
        const fill: f32 = if (full) 1.0 else if (partial) 0.5 else 0.0;
        self.radioGlyph(fill, full or partial, 0, fade, alpha);

        if (is_cursor) self.row.add(term.UNDERLINE);
        self.row.add(term.BOLD);
        self.row.add(style.mixAt(&self.scratch_a, 241, 253, if (is_cursor) 1.0 else fade * alpha));
        self.row.add(group.label);
        self.row.add(term.RESET);
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 234, 239, fade * alpha));
        // When a filter is hiding most of the group, the count on the heading
        // has to be the number of rows actually below it, not the group size —
        // otherwise a heading reading "58 destinations" sits above a single row.
        const noun = self.opts.words.count_noun;
        if (group.items.len < group.total) {
            self.row.addFmt("{d} of {d} {s}s", .{ group.items.len, group.total, noun });
        } else {
            self.row.addFmt("{d} {s}{s}", .{ group.total, noun, if (group.total == 1) "" else "s" });
        }
        self.row.add(term.RESET);

        if (sel_n > 0) {
            self.pending_right = std.fmt.bufPrint(&self.right_buf, "{d}/{d}", .{ sel_n, group.total }) catch "";
            self.pending_right_color = style.mixAt(&self.scratch_b, 34, 42, fade * alpha);
        }
    }

    fn renderDetail(self: *Prompt, alpha: f32) void {
        self.ensureDetail();

        self.rail();
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 237, 242, 0.75 * alpha));
        self.row.add(switch (self.detail_kind) {
            // The pane's heading names what the cursor is on, so the "Select
            // all" row explains itself instead of claiming to be a destination.
            .select_all => "Select all",
            .scope => "Scope",
            else => self.opts.words.row_heading,
        });
        self.row.add(term.RESET);
        if (self.detail_kind == .group) {
            self.row.add("  ");
            self.row.add(style.mixAt(&self.scratch_a, 235, 238, alpha));
            self.row.add("group");
            self.row.add(term.RESET);
        }
        self.emitRow("", style.DIM, 0);

        const p = self.detail_anim.progress(self.now);
        var i: usize = 0;
        while (i < self.opts.detail_lines) : (i += 1) {
            self.rail();
            self.row.add("  ");
            self.row.add(style.mixAt(&self.scratch_a, 234, 247, (0.3 + 0.7 * p) * alpha));
            self.row.add(self.detail_cache[i]);
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
        }
    }

    fn ensureDetail(self: *Prompt) void {
        // The wrap width comes from `cols`, so the width is part of the key: a
        // resize has to re-wrap even though the cursor has not moved.
        // A space toggles rows without moving the cursor, and the only detail
        // whose text depends on the selection belongs to a group heading — so
        // that is the one cursor position where the count joins the key.
        const on_group = if (self.cursorEntry()) |e| e.kind == .group else false;
        const sel_key: usize = if (on_group) self.selectionCount() else 0;
        if (self.detail_valid and
            self.detail_key == @as(i64, @intCast(self.cursor)) and
            self.detail_cols == self.cols and
            self.detail_sel == sel_key) return;
        self.detail_key = @intCast(self.cursor);
        self.detail_cols = self.cols;
        self.detail_sel = sel_key;
        self.detail_valid = true;
        self.detail_anim.begin(self.now);

        _ = self.detail_arena.reset(.retain_capacity);
        const da = self.detail_arena.allocator();

        self.detail_kind = .item;
        const w = if (self.cols > 8) self.cols - 5 else 20;

        var text = bufmod.Buf.init(da);
        if (self.cursorEntry()) |entry| switch (entry.kind) {
            .item => {
                const it = self.items[entry.item];
                if (it.detail.len > 0) {
                    text.add(it.detail);
                } else {
                    text.add(it.root);
                    text.add("\n");
                    if (it.agents.len > 1) {
                        text.addFmt("read by {d} agents: {s}", .{ it.agents.len, it.agents[0] });
                        var k: usize = 1;
                        while (k < it.agents.len and k < 4) : (k += 1) {
                            text.add(", ");
                            text.add(it.agents[k]);
                        }
                        if (it.agents.len > k) text.addFmt(" +{d}", .{it.agents.len - k});
                    } else {
                        text.addFmt("dedicated to {s}", .{it.label});
                    }
                    text.add("\n");
                    text.add(if (it.detected) "already in place — nothing is created" else "will be created by this install");
                }
            },
            .group => {
                self.detail_kind = .group;
                const g = self.groups.items[entry.group];
                const noun = self.opts.words.count_noun;
                text.addFmt("{d} {s}{s} · {d} selected", .{
                    g.total,
                    noun,
                    if (g.total == 1) "" else "s",
                    self.selectionCount(),
                });
                text.add("\n");
                text.add(if (self.opts.words.group_detail.len > 0)
                    self.opts.words.group_detail
                else if (g.detected)
                    "the skill lands in a directory that already exists here"
                else
                    "a new directory is created for each destination you pick");
            },
            .select_all => {
                self.detail_kind = .select_all;
                text.add(self.opts.words.select_all_detail);
            },
            // The scope row is the one place where the two directories are the
            // whole explanation, so the pane spells them out. It is one flowing
            // sentence on purpose: `wrapLines` collapses newlines, so anything
            // written as separate lines would re-flow into a run-on.
            .scope => {
                self.detail_kind = .scope;
                text.add(if (self.activeScope() == .project)
                    "showing project — space switches to global. Project installs into this checkout; global installs under your home, shared by every project."
                else
                    "showing global — space switches to project. Project installs into this checkout; global installs under your home, shared by every project.");
            },
        };

        const lines = width.wrapLines(da, text.bytes(), w, self.opts.detail_lines) catch &.{};
        var i: usize = 0;
        while (i < self.opts.detail_lines and i < max_detail) : (i += 1) {
            self.detail_cache[i] = if (i < lines.len) lines[i] else "";
        }
    }

    fn cursorEntry(self: *Prompt) ?Entry {
        if (self.cursor >= self.settled.items.len) return null;
        return self.settled.items[self.cursor];
    }

    /// The label of the scope that is not on screen. Only meaningful when the
    /// caller offered two.
    fn otherScopeLabel(self: *Prompt) []const u8 {
        for (self.scopes[0..self.scope_n]) |s| {
            if (s != self.activeScope()) return s.label();
        }
        return "";
    }

    fn renderSummary(self: *Prompt, alpha: f32) void {
        self.rail();
        self.row.add("  ");

        const n = self.selectionCount();
        if (n == 0) {
            self.row.add(style.mixAt(&self.scratch_a, 238, 244, alpha));
            self.row.add(if (self.opts.require_selection)
                self.opts.words.none_summary
            else
                "Selection  none");
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            return;
        }

        const active_n = self.scopedSelected();
        const other_n = n - active_n;

        self.row.add(style.GREEN);
        self.row.add("Selection");
        self.row.add(term.RESET);
        self.row.add("  ");

        // This line is the only place the other tab's selection is visible, and
        // it is the one that has to be: those rows are not on screen, so they
        // are reported by count rather than by name — a name here would point
        // at something the user cannot see to uncheck.
        if (active_n == 0) {
            self.row.add(style.mixAt(&self.scratch_a, 35, 42, alpha));
            self.row.addFmt("{d} in {s}", .{ other_n, self.otherScopeLabel() });
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            return;
        }

        var shown: usize = 0;
        var used: usize = 0;
        for (self.selected.items, 0..) |s, i| {
            if (!s) continue;
            if (self.items[i].scope != self.activeScope()) continue;
            if (shown == 3) break;
            if (used > 0) {
                self.row.add(", ");
                used += 2;
            }
            self.row.add(style.mixAt(&self.scratch_a, 244, 250, alpha));
            self.row.add(self.items[i].label);
            self.row.add(term.RESET);
            used += width.width(self.items[i].label);
            shown += 1;
            if (used > 58) break;
        }
        if (active_n > shown) {
            self.row.add(style.mixAt(&self.scratch_a, 35, 42, alpha));
            self.row.addFmt(" +{d} more", .{active_n - shown});
            self.row.add(term.RESET);
        }
        if (other_n > 0) {
            self.row.add(style.mixAt(&self.scratch_a, 35, 42, alpha));
            self.row.add("  ·  ");
            self.row.addFmt("+{d} in {s}", .{ other_n, self.otherScopeLabel() });
            self.row.add(term.RESET);
        }
        self.emitRow("", style.DIM, 0);
    }

    fn renderFooter(self: *Prompt, alpha: f32) void {
        self.row.add(style.mixAt(&self.scratch_a, 235, 239, alpha));
        self.row.add(style.SEP_END);
        self.row.add(term.RESET);

        // Naming the count of destinations that would be *created* is the one
        // number that tells the user whether this is a no-op or a commitment.
        // Both counts describe the scope on screen — the summary line is where
        // anything from the other tab is reported.
        const scope = self.activeScope();
        var creating: usize = 0;
        for (self.selected.items, 0..) |s, i| {
            if (!s or self.items[i].scope != scope) continue;
            if (!self.items[i].detected) creating += 1;
        }
        const total = self.scopedTotal();
        const s_count = std.fmt.bufPrint(&self.right_buf, "{d} {s}{s}", .{
            total,
            self.opts.words.count_noun,
            if (total == 1) "" else "s",
        }) catch "";
        if (creating == 0) {
            self.emitRow(s_count, style.FAINT, 0);
            return;
        }
        var r_buf: [96]u8 = undefined;
        const right = std.fmt.bufPrint(&r_buf, "{s} · {d} will be created", .{ s_count, creating }) catch s_count;
        self.emitRow(right, style.FAINT, 0);
    }

    pub fn flush(self: *Prompt, out: *term.Out, sync: bool) void {
        paint.flush(out, sync, self.frame.bytes(), &self.wrote_frame, &self.painted_rows, self.frame_rows);
    }

    pub fn checkFrame(self: *Prompt) paint.FrameCheck {
        return paint.checkFrame(self.frame.bytes(), self.cols);
    }
};

pub const RunResult = struct {
    outcome: Outcome,
    items: []Item,
};

/// Drives the picker against a real terminal.
///
/// Like the skill prompt, the loop only repaints when something changed or
/// something is still moving, and parks in `poll()` with an infinite timeout
/// while idle.
pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    items: []Item,
    opts: Options,
    out: *term.Out,
    sync: bool,
    cwd: []const u8,
) !RunResult {
    const p = try arena.create(Prompt);
    p.* = Prompt.init(arena, gpa, io, env, items, opts, cwd);
    defer p.deinit();

    if (opts.force_cols == 0) {
        const s = term.size();
        p.setSize(s.cols, s.rows);
    }

    var raw = term.RawMode.enable();
    if (raw) |*r| {
        term.installSignalGuard(r);
        term.installResizeHandler();
    }
    out.writeAll(term.HIDE_CURSOR);
    out.flush();

    p.started_ms = term.nowMs(io);
    p.now = p.started_ms;
    // `init` runs before the clock exists, so the entrance timings it derived
    // from `now == 0` have to be re-armed against the real one. Without this
    // the stagger is already long finished by the first frame and the list
    // appears fully formed, while a recording (whose virtual clock really does
    // start at 0) still animates.
    p.entrance_ms = p.now;
    p.filter_ms = p.now - 1000;
    var last = p.now;
    p.dirty = true;
    var inbuf: [256]u8 = undefined;

    while (true) {
        const now = term.nowMs(io);
        p.now = now;

        if (opts.force_cols == 0 and term.takeResize()) {
            const s = term.size();
            p.setSize(s.cols, s.rows);
        }

        const animating = p.wantsAnimation();
        // A dirty prompt has a frame waiting to be painted and must not park in
        // `poll()` waiting for a keypress. This matters more here than for the
        // skill prompt: there is no loading phase, so on the first iteration
        // nothing is animating yet — blocking here would leave the prompt blank
        // until the user happened to press something.
        const ready = term.pollInput(if (animating or p.dirty) 16 else null);
        if (ready) {
            const n = term.readInput(&inbuf);
            if (n > 0) p.handleInput(inbuf[0..n]);
        }

        // `pollInput` may have blocked, so re-read the clock before integrating:
        // `dt` has to cover the time actually spent waiting.
        const now2 = term.nowMs(io);
        p.now = now2;
        const dt = @as(f32, @floatFromInt(@min(@max(now2 - last, 0), 100))) / 1000.0;
        last = now2;

        if (p.dirty or animating) {
            p.update(dt);
            p.render();
            p.flush(out, sync);
        }

        if (p.outcome) |oc| {
            out.writeAll(term.RESET);
            out.writeAll(term.SHOW_CURSOR);
            out.flush();
            if (raw) |*r| r.restore();
            return .{ .outcome = oc, .items = p.items };
        }
    }
}

fn flashAlpha(until_ms: i64, now_ms: i64) f32 {
    const left = until_ms - now_ms;
    if (left <= 0) return 0;
    return @min(1.0, @as(f32, @floatFromInt(left)) / 260.0);
}

fn indexIn(list: []const usize, value: usize) usize {
    for (list, 0..) |v, i| {
        if (v == value) return i;
    }
    return 0;
}

/// Every whitespace-separated token of `query` has to appear in `haystack`.
/// `haystack` is already lowercased by `buildBlob`.
fn containsAll(haystack: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |token| {
        var lower: [128]u8 = undefined;
        if (token.len > lower.len) return false;
        for (token, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        if (std.mem.find(u8, haystack, lower[0..token.len]) == null) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A candidate in the project scope, which is what most of these tests are
/// about; `candIn` names the scope when the test is about the scope.
fn cand(key: []const u8, display: []const u8, root: []const u8, detected: bool, default_on: bool) Candidate {
    return candIn(.project, key, display, root, detected, default_on);
}

fn candIn(
    scope: Scope,
    key: []const u8,
    display: []const u8,
    root: []const u8,
    detected: bool,
    default_on: bool,
) Candidate {
    return .{
        .key = key,
        .display = display,
        .root = root,
        .short_root = root,
        .detected = detected,
        .default_on = default_on,
        .scope = scope,
    };
}

test "buildItems collapses agents that share a destination" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two hub agents pointing at `.agents/skills` plus one of its own.
    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        cand("codex", "Codex", ".agents/skills", true, true),
        cand("claude-code", "Claude Code", ".claude/skills", true, true),
        cand("windsurf", "Windsurf", ".windsurf/skills", false, false),
    });

    try testing.expectEqual(@as(usize, 3), items.len);
    // Pre-checked rows come first, and the merged one is labelled with the
    // first agent plus how many others read the same directory.
    try testing.expectEqualStrings("Cursor +1", items[0].label);
    try testing.expectEqualStrings(".agents/skills", items[0].root);
    try testing.expectEqual(@as(usize, 2), items[0].agents.len);
    try testing.expectEqualStrings("Claude Code", items[1].label);
    try testing.expectEqualStrings("Windsurf", items[2].label);
    // The un-detected destination sinks to the bottom even though it was last
    // in the input; that ordering is what puts the likely answers at the top.
    try testing.expect(!items[2].detected);
}

test "buildItems merges a later agent into a row from an earlier bucket" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `amp` is pre-checked (bucket 0) and `universal` is only detected
    // (bucket 1). They share a directory, so the second must fold into the
    // first rather than producing a duplicate row.
    const items = try buildItems(arena, &.{
        cand("amp", "Amp", ".agents/skills", true, true),
        cand("universal", "Universal", ".agents/skills", true, false),
    });

    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("Amp +1", items[0].label);
    try testing.expect(items[0].default_on);
}

test "the picker pre-selects the rows a bare install would have chosen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", false, true),
        cand("claude-code", "Claude Code", ".claude/skills", false, true),
        cand("windsurf", "Windsurf", ".windsurf/skills", false, false),
    });

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
        .force_cols = 80,
        .force_rows = 24,
    }, "/tmp");
    defer p.deinit();

    try testing.expectEqual(@as(usize, 2), p.selectionCount());
    try testing.expect(p.selected.items[0]);
    try testing.expect(p.selected.items[1]);
    try testing.expect(!p.selected.items[2]);
}

test "typing filters on agent names, paths and the merged siblings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        cand("codex", "Codex", ".agents/skills", true, true),
        cand("claude-code", "Claude Code", ".claude/skills", true, false),
        cand("windsurf", "Windsurf", ".windsurf/skills", true, false),
    });

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
        .force_cols = 80,
        .force_rows = 24,
    }, "/tmp");
    defer p.deinit();

    // "codex" is not the row's label — it is a merged sibling — but a user
    // searching for where Codex reads from has to find it.
    p.handleInput("codex");
    try testing.expectEqual(@as(usize, 1), p.matched.items.len);
    try testing.expectEqualStrings("Cursor +1", p.items[p.matched.items[0]].label);

    // An agent's own name works.
    p.handleInput("\x15"); // ctrl-u
    p.handleInput("windsurf");
    try testing.expectEqual(@as(usize, 1), p.matched.items.len);
    try testing.expectEqualStrings("Windsurf", p.items[p.matched.items[0]].label);

    // So does a fragment of the destination path that no agent name contains.
    p.handleInput("\x15");
    p.handleInput(".claude");
    try testing.expectEqual(@as(usize, 1), p.matched.items.len);
    try testing.expectEqualStrings("Claude Code", p.items[p.matched.items[0]].label);
}

test "filter tokens are ANDed, not ORed" {
    // The haystack is what `buildBlob` produces: already lowercased, with the
    // key, the path and every merged agent name appended.
    const hay = "cursor +1 cursor .agents/skills cursor codex";
    try testing.expect(containsAll(hay, "cursor"));
    try testing.expect(containsAll(hay, "codex"));
    try testing.expect(containsAll(hay, ".agents"));
    // Both tokens have to be present...
    try testing.expect(containsAll(hay, ".agents cursor"));
    try testing.expect(containsAll(hay, "codex cursor"));
    // ...and one missing token is enough to exclude the row.
    try testing.expect(!containsAll(hay, ".agents windsurf"));
    try testing.expect(!containsAll(hay, "windsurf"));
    // An empty query matches everything.
    try testing.expect(containsAll(hay, ""));
    // Tokens are matched case-insensitively.
    try testing.expect(containsAll(hay, "Codex"));
}

test "escape always produces an outcome" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, &.{}, .{
        .force_cols = 80,
        .force_rows = 24,
    }, "/tmp");
    defer p.deinit();

    p.handleInput("\x1b");
    // The driver loops until it sees an outcome; if cancelling did not set one,
    // the prompt would hang with the cursor hidden.
    try testing.expect(p.outcome != null);
    try testing.expect(p.outcome.? == .cancelled);
}

test "an empty selection is refused, then accepted once one is picked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("windsurf", "Windsurf", ".windsurf/skills", false, false),
    });

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
        .force_cols = 80,
        .force_rows = 24,
        .require_selection = true,
    }, "/tmp");
    defer p.deinit();

    p.handleInput("\r");
    try testing.expect(p.outcome == null);

    // Space toggles the row under the cursor. The first row is "Select all",
    // so move down once to land on the destination.
    p.handleInput("\x1b[B");
    p.handleInput(" ");
    try testing.expectEqual(@as(usize, 1), p.selectionCount());

    p.handleInput("\r");
    // Submitting starts the collapse animation; the selection is only handed
    // back once it has finished, which is what `update` advances.
    try testing.expectEqual(Phase.submitting, p.phase);
    try testing.expect(p.outcome == null);

    p.now = p.collapse.start_ms + p.collapse.duration_ms;
    p.update(0.016);
    try testing.expect(p.outcome != null);
    switch (p.outcome.?) {
        .submitted => |indices| {
            try testing.expectEqual(@as(usize, 1), indices.len);
            try testing.expectEqual(@as(usize, 0), indices[0]);
        },
        .cancelled => return error.UnexpectedCancel,
    }
}

test "the frame is always exactly cols cells wide" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        cand("codex", "Codex", ".agents/skills", true, true),
        cand("claude-code", "Claude Code", ".claude/skills", true, true),
        cand("windsurf", "Windsurf", ".windsurf/skills", false, false),
        cand("qoder", "Qoder", ".qoder/skills", false, false),
    });

    // Several widths, because the detail pane wraps and the right-hand path
    // hint competes with the label for the same row.
    for ([_]usize{ 40, 72, 104, 132 }) |cols| {
        var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
            .force_cols = cols,
            .force_rows = 30,
        }, "/tmp");
        defer p.deinit();

        p.now = 5000;
        p.render();
        const chk = p.checkFrame();
        testing.expectEqual(@as(usize, 0), chk.violations) catch |err| {
            std.debug.print("cols={d} worst={d} line={d}\n", .{ cols, chk.worst_width, chk.worst_line });
            return err;
        };

        // ...and again with a filter that empties one of the groups.
        p.handleInput("qoder");
        p.now = 9000;
        p.render();
        try testing.expectEqual(@as(usize, 0), p.checkFrame().violations);
    }
}

test "a short terminal drops the detail pane instead of overflowing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        candIn(.global, "cursor", "Cursor", "/home/u/.agents/skills", true, false),
    });

    for ([_]usize{ 6, 10, 14, 18, 40 }) |rows| {
        var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
            .force_cols = 80,
            .force_rows = rows,
        }, "/tmp");
        defer p.deinit();
        p.render();
        // The frame must never be taller than the terminal, or the terminal
        // scrolls and every subsequent "move up N" is off by the scroll.
        try testing.expect(p.frame_rows <= rows);
        // ...and the scope row is the first thing to go, because a control that
        // costs the only visible destination its row is not worth keeping.
        if (rows < 10) try testing.expect(!p.showScopeRow());
    }
}

// ---------------------------------------------------------------------------
// scope
// ---------------------------------------------------------------------------

test "the same directory name in two scopes stays two rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `.agents/skills` relative to the checkout and `~/.agents/skills` are two
    // different directories that happen to share a tail. Collapsing them into
    // one row would present two decisions as one and keep the root of only one
    // of them, so the scope is part of the merge key even though the rest of
    // the merge is keyed on the path.
    const items = try buildItems(arena, &.{
        candIn(.project, "cursor", "Cursor", ".agents/skills", true, true),
        candIn(.global, "codex", "Codex", "/home/u/.agents/skills", true, false),
    });

    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(Scope.project, items[0].scope);
    try testing.expectEqualStrings(".agents/skills", items[0].root);
    try testing.expectEqual(Scope.global, items[1].scope);
    try testing.expectEqualStrings("/home/u/.agents/skills", items[1].root);
    // The project row keeps its own merge label rather than absorbing the
    // global sibling.
    try testing.expectEqualStrings("Cursor", items[0].label);
    try testing.expect(items[0].default_on);
    try testing.expect(!items[1].default_on);
}

test "switching scope re-filters the view and keeps the other tab's selection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        cand("windsurf", "Windsurf", ".windsurf/skills", true, false),
        candIn(.global, "amp", "Amp", "/home/u/.agents/skills", true, false),
        candIn(.global, "qoder", "Qoder", "/home/u/.qoder/skills", false, false),
    });

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
        .force_cols = 80,
        .force_rows = 24,
    }, "/tmp");
    defer p.deinit();

    try testing.expectEqual(@as(usize, 2), p.scopeCount());
    try testing.expect(p.showScopeRow());
    // The view opens on the first scope the caller offered, which is the one
    // whose rows were pre-checked.
    try testing.expectEqual(Scope.project, p.activeScope());
    try testing.expectEqual(@as(usize, 2), p.scopedTotal());
    try testing.expectEqual(p.scopedTotal(), p.matched.items.len);
    for (p.matched.items) |i| try testing.expectEqual(Scope.project, p.items[i].scope);
    // Only the rows that a bare install would have used are ticked.
    try testing.expectEqual(@as(usize, 1), p.scopedSelected());

    // The cursor starts on the scope row, so four `↓` reaches the second
    // destination: scope → select all → group heading → Cursor → Windsurf.
    p.handleInput("\x1b[B\x1b[B\x1b[B\x1b[B");
    try testing.expectEqual(Kind.item, p.settled.items[p.cursor].kind);
    try testing.expectEqualStrings("Windsurf", p.items[p.settled.items[p.cursor].item].label);
    p.handleInput(" ");
    try testing.expectEqual(@as(usize, 2), p.scopedSelected());

    // Back up to the scope row and switch.
    p.handleInput("\x1b[A\x1b[A\x1b[A\x1b[A");
    try testing.expectEqual(@as(usize, 0), p.cursor);
    p.handleInput(" ");
    try testing.expectEqual(Scope.global, p.activeScope());
    try testing.expectEqual(@as(usize, 2), p.scopedTotal());
    for (p.matched.items) |i| try testing.expectEqual(Scope.global, p.items[i].scope);
    // Both ticks made on the project tab survive the switch: they live on the
    // item list, not on the view. That is the whole reason scope is a filter
    // and not a rebuild.
    try testing.expectEqual(@as(usize, 0), p.scopedSelected());
    try testing.expectEqual(@as(usize, 2), p.otherScopeSelected());

    // Take one here too, and submit: the answer has to name both scopes.
    p.handleInput("\x1b[B\x1b[B\x1b[B");
    try testing.expectEqualStrings("Amp", p.items[p.settled.items[p.cursor].item].label);
    p.handleInput(" ");
    try testing.expectEqual(@as(usize, 3), p.selectionCount());
    p.handleInput("\r");
    p.now = p.collapse.start_ms + p.collapse.duration_ms;
    p.update(0.016);

    const indices = switch (p.outcome.?) {
        .submitted => |list| list,
        .cancelled => return error.UnexpectedCancel,
    };
    try testing.expectEqual(@as(usize, 3), indices.len);
    var project_rows: usize = 0;
    var global_rows: usize = 0;
    for (indices) |i| switch (p.items[i].scope) {
        .project => project_rows += 1,
        .global => global_rows += 1,
    };
    try testing.expectEqual(@as(usize, 2), project_rows);
    try testing.expectEqual(@as(usize, 1), global_rows);
}

test "typing parks the cursor on a row, not on the scope switch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        candIn(.global, "amp", "Amp", "/home/u/.agents/skills", true, false),
    });

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
        .force_cols = 80,
        .force_rows = 24,
    }, "/tmp");
    defer p.deinit();

    // A space pressed right after narrowing must act on the narrowed list, not
    // flip the tab out from under the query.
    p.handleInput("cursor");
    try testing.expectEqual(Kind.group, p.settled.items[p.cursor].kind);
    try testing.expectEqual(Scope.project, p.activeScope());

    // With nothing matched the park is a control, so the user can still switch
    // scope and look elsewhere.
    p.handleInput("\x15");
    p.handleInput("zzzz");
    try testing.expectEqual(@as(usize, 0), p.matched.items.len);
    try testing.expectEqual(@as(usize, 0), p.cursor);
    try testing.expect(p.settled.items[0].kind == .scope);
}

test "the frame is exactly cols wide with both scopes on offer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    const items = try buildItems(arena, &.{
        cand("cursor", "Cursor", ".agents/skills", true, true),
        cand("codex", "Codex", ".agents/skills", true, true),
        candIn(.global, "cursor", "Cursor", "/home/u/.agents/skills", true, false),
        candIn(.global, "qoder", "Qoder", "/home/u/.qoder/skills", false, false),
    });

    // 40 columns is where the "scope" label is dropped and the segments have to
    // carry the row on their own.
    for ([_]usize{ 40, 45, 46, 72, 104, 132 }) |cols| {
        var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
            .force_cols = cols,
            .force_rows = 30,
        }, "/tmp");
        defer p.deinit();

        p.now = 5000;
        p.render();
        testing.expectEqual(@as(usize, 0), p.checkFrame().violations) catch |err| {
            std.debug.print("cols={d} worst={d} line={d}\n", .{ cols, p.checkFrame().worst_width, p.checkFrame().worst_line });
            return err;
        };

        // ...and again on the other tab, where the detail pane says something
        // different.
        p.setScope(.global);
        p.now = 9000;
        p.render();
        try testing.expectEqual(@as(usize, 0), p.checkFrame().violations);
    }
}

/// True when any cached detail line contains `needle`.
fn detailHas(p: *const Prompt, needle: []const u8) bool {
    for (p.detail_cache) |line| {
        if (std.mem.find(u8, line, needle) != null) return true;
    }
    return false;
}

test "the group detail follows the selection, not just the cursor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-pick-test");

    // Present but not pre-checked, so the count the pane reports starts at zero.
    // Three distinct directories: agents that share one merge into a single row,
    // which would make this a two-row group.
    const items = try buildItems(arena, &.{
        cand("claude-code", "Claude Code", ".claude/skills", true, false),
        cand("codex", "Codex", ".codex/skills", true, false),
        cand("windsurf", "Windsurf", ".windsurf/skills", true, false),
    });

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, items, .{
        .force_cols = 100,
        .force_rows = 30,
    }, "/tmp");
    defer p.deinit();
    p.now = 5000;

    // One down from "Select all" is the group heading, whose detail reports how
    // many rows beneath it are ticked.
    p.handleInput("\x1b[B");
    p.ensureDetail();
    try testing.expect(detailHas(&p, "0 selected"));

    // A space toggles the whole group *without moving the cursor*, so a cache
    // keyed on the cursor alone went on saying "0 selected" while the heading
    // beside it said "3/3" and the summary named all three.
    p.handleInput(" ");
    try testing.expectEqual(@as(usize, 3), p.selectionCount());
    p.ensureDetail();
    try testing.expect(detailHas(&p, "3 selected"));
}
