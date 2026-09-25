//! The interactive prompt — an animated, searchable, grouped multiselect.
//!
//! Design lineage: the reference tool's `searchMultiselect` prompt (clack-style
//! rails and symbols, full-frame erase + redraw, a fixed-height detail pane so
//! the layout never jumps). Everything added on top is motion that carries
//! information rather than decoration:
//!
//!   * roots are scanned incrementally, so the spinner counts real progress
//!   * rows stagger in, and each row's marker is a real spring-driven radio
//!     that fills through four frames when toggled
//!   * scrolling is a spring, not a jump — holding ↓ glides
//!   * groups collapse by animating their child count toward zero
//!   * the selection counter counts up instead of snapping
//!
//! Two invariants keep it honest:
//!
//!   1. `render()` is pure — state in, bytes out. That is what lets
//!      `bliz record` replay identical pixels with no terminal attached,
//!      and what makes an idle prompt cost zero writes.
//!   2. Every line goes through `emitRow`, which truncates to the terminal
//!      width and pads to it. A line can therefore never soft-wrap, so one
//!      logical line is always exactly one terminal row and the
//!      "move up N, erase, redraw" repaint stays exact.

const std = @import("std");
const term = @import("term.zig");
const style = @import("style.zig");
const width = @import("width.zig");
const anim = @import("anim.zig");
const bufmod = @import("buf.zig");
const paint = @import("paint.zig");
const discover = @import("discover.zig");

pub const Phase = enum { loading, ready, submitting, submitted, cancelled };

pub const Options = struct {
    message: []const u8 = "Select skills",
    /// Right-hand side of the header, e.g. "global".
    badge: []const u8 = "",
    detail_lines: usize = 3,
    select_all: bool = true,
    searchable: bool = true,
    /// Refuse to submit with an empty selection (the summary nudges instead).
    require_selection: bool = false,
    /// Force a layout size instead of reading the terminal (used by `record`).
    force_cols: usize = 0,
    force_rows: usize = 0,
    /// Text to pre-fill the search box with (`bliz find react`).
    initial_query: []const u8 = "",
    /// Minimum time the loading phase is shown, so a fast scan does not flash.
    min_load_ms: i64 = 420,
};

pub const Outcome = union(enum) {
    submitted: []usize,
    cancelled,
};

const Kind = enum { select_all, group, skill };

const Entry = struct {
    kind: Kind,
    group: usize = 0,
    skill: usize = 0,
};

const GroupView = struct {
    root_index: usize,
    label: []const u8,
    path: []const u8,
    /// Skill indices matching the current query, in display order.
    items: []usize,
    /// Total skills in this group, matched or not.
    total: usize,
    collapsed: bool,
};

const rail_lo: u8 = 236;
const rail_hi: u8 = 244;
const max_detail_cache = 4;

pub const Prompt = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
    home: []const u8,
    opts: Options,

    roots: []discover.RootCandidate,
    skills_list: std.ArrayList(discover.Skill) = .empty,
    skills: []discover.Skill = &.{},
    search_blob: std.ArrayList([]const u8) = .empty,
    hint: std.ArrayList([]const u8) = .empty,

    phase: Phase = .loading,
    started_ms: i64 = 0,
    scan_cursor: usize = 0,
    visited_roots: usize = 0,
    scan_complete: bool = false,
    /// Frame clock. The driver owns it so recordings are deterministic.
    now: i64 = 0,

    query: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    selected: std.ArrayList(bool) = .empty,

    matched: std.ArrayList(usize) = .empty,
    groups: std.ArrayList(GroupView) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    settled: std.ArrayList(Entry) = .empty,

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
    /// key because the wrap width is derived from `cols`, so a resize has to
    /// invalidate it — otherwise the pane keeps the old line breaks until the
    /// cursor happens to move.
    detail_cols: usize = 0,
    detail_valid: bool = false,
    detail_cache: [max_detail_cache][]const u8 = .{ "", "", "", "" },
    detail_group: bool = false,
    /// Backing store for the wrapped detail text. `ensureDetail` resets this
    /// rather than allocating from the long-lived arena: the detail string is
    /// rebuilt on every cursor move, so arena allocation there would grow
    /// without bound for as long as the session lasts.
    detail_arena: std.heap.ArenaAllocator,
    collapse: anim.Tween,
    nudge: anim.Tween,
    flash: std.ArrayList(i64) = .empty,

    cols: usize = 80,
    rows: usize = 24,
    frame: bufmod.Buf,
    row: bufmod.Buf,
    right_buf: [160]u8 = undefined,
    /// Scratch for `style.mixAt` codes. Slices returned from these live only
    /// long enough to be appended to `row`, which is always done immediately.
    scratch_a: [16]u8 = undefined,
    scratch_b: [16]u8 = undefined,
    /// A row's right-aligned hint is computed while the row body is built and
    /// consumed by `emitRow`.
    pending_right: []const u8 = "",
    pending_right_color: []const u8 = "",
    frame_rows: usize = 0,
    /// True once a frame has been painted, so the next `flush` knows it must
    /// walk the cursor back up before erasing.
    wrote_frame: bool = false,
    /// Height of the frame currently on screen — the distance `flush` walks
    /// back up.
    painted_rows: usize = 0,
    dirty: bool = true,
    outcome: ?Outcome = null,
    error_count: usize = 0,

    pub fn init(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        roots: []discover.RootCandidate,
        opts_in: Options,
        cwd: []const u8,
    ) Prompt {
        var opts = opts_in;
        opts.detail_lines = @min(opts.detail_lines, max_detail_cache);
        return .{
            .arena = arena,
            .gpa = gpa,
            .io = io,
            .env = env,
            .cwd = cwd,
            .home = env.get("HOME") orelse "",
            .opts = opts,
            .roots = roots,
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
    }

    pub fn deinit(self: *Prompt) void {
        self.skills_list.deinit(self.arena);
        self.search_blob.deinit(self.arena);
        self.hint.deinit(self.arena);
        self.query.deinit(self.arena);
        self.selected.deinit(self.arena);
        self.matched.deinit(self.arena);
        self.groups.deinit(self.arena);
        self.entries.deinit(self.arena);
        self.settled.deinit(self.arena);
        self.expand.deinit(self.arena);
        self.radio.deinit(self.arena);
        self.flash.deinit(self.arena);
        self.frame.deinit();
        self.row.deinit();
        self.detail_arena.deinit();
    }

    // ---------------------------------------------------------------- loading

    /// Scans at most `budget` *existing* roots. Returns true when every root
    /// has been visited. Missing roots are skipped without consuming budget,
    /// so the spinner's cost reflects real work on this machine rather than the
    /// size of the registry.
    pub fn loadTick(self: *Prompt, budget: usize) bool {
        var scanned: usize = 0;
        while (self.scan_cursor < self.roots.len and scanned < budget) {
            const root_index = self.scan_cursor;
            const root = &self.roots[root_index];
            self.scan_cursor += 1;
            self.visited_roots += 1;
            self.dirty = true;
            if (!root.exists) continue;
            scanned += 1;

            var errs: std.ArrayList([]const u8) = .empty;
            discover.scanRoot(self.arena, self.io, self.gpa, root, self.home, self.cwd, &errs) catch {};
            self.error_count += errs.items.len;
            for (root.skills) |s| {
                var skill = s;
                skill.root_index = root_index;
                self.skills_list.append(self.arena, skill) catch {};
                self.search_blob.append(self.arena, lowerAlloc(self.arena, skill.name, skill.description, skill.display_dir)) catch {};
            }
        }
        if (self.scan_cursor >= self.roots.len) self.scan_complete = true;
        return self.scan_complete;
    }

    /// Publishes the scanned set and starts the reveal animations.
    pub fn finalizeLoad(self: *Prompt) void {
        self.skills = self.skills_list.items;
        const n = self.skills.len;
        const now = self.now;

        self.selected.clearRetainingCapacity();
        self.radio.clearRetainingCapacity();
        self.flash.clearRetainingCapacity();
        self.hint.clearRetainingCapacity();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = self.skills[i];
            const age = discover.ageLabel(self.arena, s.mtime_ms, now);
            self.selected.append(self.arena, false) catch {};
            self.radio.append(self.arena, anim.Spring.withResponse(0, 320, 30)) catch {};
            self.flash.append(self.arena, 0) catch {};
            self.hint.append(self.arena, std.fmt.allocPrint(self.arena, "{d} file{s} · {s}", .{
                s.files,
                if (s.files == 1) "" else "s",
                age,
            }) catch "") catch {};
        }

        self.groups.clearRetainingCapacity();
        var idx: usize = 0;
        while (idx < n) {
            const root_index = self.skills[idx].root_index;
            var end = idx;
            while (end < n and self.skills[end].root_index == root_index) end += 1;
            var lbuf: [160]u8 = undefined;
            const label = std.fmt.allocPrint(self.arena, "{s}", .{self.roots[root_index].label(&lbuf)}) catch "group";
            self.groups.append(self.arena, .{
                .root_index = root_index,
                .label = label,
                .path = self.roots[root_index].display,
                .items = &.{},
                .total = end - idx,
                .collapsed = false,
            }) catch {};
            idx = end;
        }

        self.expand.clearRetainingCapacity();
        for (self.groups.items) |_| {
            self.expand.append(self.arena, anim.Spring.withResponse(1, 260, 28)) catch {};
        }

        self.query.clearRetainingCapacity();
        if (self.opts.initial_query.len > 0) {
            self.query.appendSlice(self.arena, self.opts.initial_query) catch {};
        }
        self.cursor = 0;
        self.rebuild();
        self.sel_counter.jump(@floatFromInt(self.selectionCount()));
        self.entrance_ms = now;
        self.filter_ms = now;
        self.phase = .ready;
        self.header_shimmer.begin(now);
        self.dirty = true;
    }

    // ------------------------------------------------------------- derivations

    fn matches(self: *Prompt, skill_index: usize) bool {
        if (self.query.items.len == 0) return true;
        const blob = self.search_blob.items[skill_index];
        // `blob` is pre-lowered, so compare case-insensitively rather than
        // demanding the user type in lower case.
        var it = std.mem.tokenizeScalar(u8, self.query.items, ' ');
        while (it.next()) |token| {
            if (!bufmod.containsIgnoreCase(blob, token)) return false;
        }
        return true;
    }

    /// Children of `group` currently drawn. Honours the collapse spring, so a
    /// closing group shrinks row by row instead of vanishing.
    fn shownChildren(self: *Prompt, group_index: usize, animated: bool) usize {
        const g = self.groups.items[group_index];
        const n = g.items.len;
        if (!animated) return if (g.collapsed) 0 else n;
        const p = std.math.clamp(self.expand.items[group_index].value, 0.0, 1.0);
        return @intFromFloat(p * @as(f32, @floatFromInt(n)) + 0.5);
    }

    pub fn rebuild(self: *Prompt) void {
        self.matched.clearRetainingCapacity();
        for (self.skills, 0..) |_, i| {
            if (self.matches(i)) self.matched.append(self.arena, i) catch {};
        }
        for (self.groups.items) |*group| {
            var list: std.ArrayList(usize) = .empty;
            for (self.matched.items) |skill_index| {
                if (self.skills[skill_index].root_index == group.root_index) {
                    list.append(self.arena, skill_index) catch {};
                }
            }
            group.items = list.items;
        }
        self.refreshEntries();
    }

    /// Rebuilds both entry lists. Cheap enough to run per frame (it is O(groups ×
    /// matched)), and it *has* to run per frame: the animated list is what turns
    /// a group's collapse spring into a shrinking child count, so refreshing it
    /// only on input would freeze the children in place while the chevron flipped.
    pub fn refreshEntries(self: *Prompt) void {
        self.buildEntries(false);
        self.buildEntries(true);
        self.clampCursor();
        self.dirty = true;
    }

    fn buildEntries(self: *Prompt, animated: bool) void {
        const list = if (animated) &self.entries else &self.settled;
        list.clearRetainingCapacity();
        if (self.opts.select_all and !animated) {
            list.append(self.arena, .{ .kind = .select_all }) catch {};
        }
        for (self.groups.items, 0..) |group, gi| {
            if (group.items.len == 0) continue;
            list.append(self.arena, .{ .kind = .group, .group = gi }) catch {};
            const shown = self.shownChildren(gi, animated);
            var k: usize = 0;
            while (k < shown and k < group.items.len) : (k += 1) {
                list.append(self.arena, .{ .kind = .skill, .group = gi, .skill = group.items[k] }) catch {};
            }
        }
    }

    fn clampCursor(self: *Prompt) void {
        const max = if (self.settled.items.len == 0) 0 else self.settled.items.len - 1;
        if (self.cursor > max) self.cursor = max;
    }

    /// `settled` carries the Select-all row; the animated entry list does not
    /// (it is never animated). Everything that maps `cursor` onto `entries`
    /// has to shift by this much.
    fn cursorOffset(self: *Prompt) usize {
        return if (self.opts.select_all) 1 else 0;
    }

    pub fn selectionCount(self: *Prompt) usize {
        var n: usize = 0;
        for (self.selected.items) |s| {
            if (s) n += 1;
        }
        return n;
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

    fn onQueryChanged(self: *Prompt) void {
        self.rebuild();
        self.filter_ms = self.now;
        self.cursor = 0;
        self.scroll.snap(0);
        self.dirty = true;
    }

    fn clearQuery(self: *Prompt) void {
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
        if (entry.kind == .select_all) return;
        const gi = entry.group;
        self.groups.items[gi].collapsed = !expanded;
        if (!expanded and entry.kind == .skill) {
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
            .select_all => self.toggleAll(),
            .group => {
                var all = true;
                for (self.groups.items[entry.group].items) |s| {
                    if (!self.selected.items[s]) all = false;
                }
                for (self.groups.items[entry.group].items) |s| {
                    self.selected.items[s] = !all;
                    self.flash.items[s] = self.now + 260;
                }
            },
            .skill => {
                self.selected.items[entry.skill] = !self.selected.items[entry.skill];
                self.flash.items[entry.skill] = self.now + 260;
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

    fn submit(self: *Prompt) void {
        if (self.phase != .ready) return;
        if (self.opts.require_selection and self.selectionCount() == 0) {
            self.nudge.begin(self.now);
            return;
        }
        self.phase = .submitting;
        self.collapse.begin(self.now);
        self.dirty = true;
    }

    fn cancel(self: *Prompt) void {
        if (self.phase == .submitted or self.phase == .cancelled) return;
        self.phase = .cancelled;
        // The outcome has to be recorded here. `run` loops until it sees one,
        // and the submitting path is the only other writer — so a cancel that
        // left this null painted "cancelled" and then parked in an infinite
        // poll with the cursor hidden, swallowing every later keystroke
        // (including a second Ctrl-C, which returns early above).
        self.outcome = .cancelled;
        self.dirty = true;
    }

    // --------------------------------------------------------------- animation

    /// Integrates every spring. `dt` is the real frame delta, in seconds.
    pub fn update(self: *Prompt, dt: f32) void {
        self.scroll.setTarget(self.scrollTarget());
        self.scroll.step(dt);

        for (self.groups.items, 0..) |group, i| {
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
        self.sel_counter.set(@floatFromInt(self.selectionCount()));
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
        if (self.phase == .loading or self.phase == .submitting) return true;
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

    /// Description rows shown at the current terminal height, so a short
    /// terminal gives its space to the list instead of clipping the frame.
    fn detailRows(self: *Prompt) usize {
        if (self.rows < 18) return 0;
        return self.opts.detail_lines;
    }

    fn showHints(self: *Prompt) bool {
        return self.rows >= 16;
    }

    fn listHeight(self: *Prompt) usize {
        // Mirrors the emit plan exactly:
        //   header, rail, [search, hints, rail], [select all], separator,
        //   [label, detail×d], summary, footer
        var chrome: usize = 2; // header + rail
        if (self.opts.searchable) {
            chrome += 2;
            if (self.showHints()) chrome += 1;
        }
        if (self.opts.select_all) chrome += 1;
        chrome += 1; // separator
        const d = self.detailRows();
        if (d > 0) chrome += 1 + d;
        chrome += 2; // summary + footer
        if (self.rows > chrome + 2) return self.rows - chrome - 1;
        return 3;
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
            self.frame_rows = countRows(self.frame.bytes());
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
                self.row.addFmt("{d} skill{s} selected", .{ n, if (n == 1) "" else "s" });
            }
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            self.frame_rows = countRows(self.frame.bytes());
            self.dirty = false;
            return;
        }

        const collapse_p = if (self.phase == .submitting) self.collapse.progress(self.now) else 0.0;
        const alpha = 1.0 - collapse_p;

        self.renderHeader(collapse_p);
        if (self.phase == .loading) {
            self.renderLoading();
        } else if (alpha > 0.02) {
            self.renderSearch();
            self.renderSelectAll(alpha);
            self.renderSeparator(alpha);
            self.renderList(alpha);
            if (self.detailRows() > 0) self.renderDetail(alpha);
            self.renderSummary(alpha);
            self.renderFooter(alpha);
        }
        self.frame_rows = countRows(self.frame.bytes());
        self.dirty = false;
    }

    fn rail(self: *Prompt) void {
        self.row.add(self.railColor());
        self.row.add(style.SEP);
        self.row.add(term.RESET);
    }

    fn railColor(self: *Prompt) []const u8 {
        if (self.phase == .loading) {
            const pulse = 0.5 + 0.5 * @sin(@as(f32, @floatFromInt(@mod(self.now, 1200))) / 1200.0 * 6.283);
            return style.mixAt(&self.scratch_a, rail_lo, 45, pulse);
        }
        return style.mixAt(&self.scratch_b, rail_lo, rail_hi, 0.4);
    }

    /// Emits the buffered row and enforces the invariant the whole repaint
    /// strategy rests on: the finished line measures exactly `cols` cells. A
    /// longer line would soft-wrap onto a second terminal row and desynchronise
    /// the `move up N` arithmetic for every row below it.
    ///
    /// `offset` slides the right-aligned block horizontally (negative = left);
    /// that is what the validation nudge and the collapse animation animate.
    fn emitRow(self: *Prompt, right: []const u8, right_color: []const u8, offset: f32) void {
        paint.emitRow(self.arena, &self.frame, &self.row, self.cols, right, right_color, offset);
    }

    fn renderHeader(self: *Prompt, collapse_p: f32) void {
        self.row.clear();
        const symbol = switch (self.phase) {
            .loading, .ready, .submitting => style.DIAMOND_ACTIVE,
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
            // The shimmer colours per character, but adjacent characters almost
            // always land on the same ramp step. Emitting one SGR per *run*
            // instead of per character cuts the frame (and the recording) by
            // roughly an order of magnitude, and is what the terminal would
            // have collapsed to anyway.
            var i: usize = 0;
            while (i < text.len) {
                const run_index = style.mixIndex(247, 255, 0.35 + anim.shimmer(i, text.len, p, 8.0) * 0.65);
                // Consume at least one character before testing whether the run
                // continues, otherwise a boundary at the current position would
                // exit with `end == i` and spin forever.
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
            .loading => std.fmt.bufPrint(&self.right_buf, "{s}  {d}/{d}", .{
                anim.spinnerFrame(self.now, 80), self.visited_roots, self.roots.len,
            }) catch "",
            .submitted => "done",
            .cancelled => "cancelled",
            else => std.fmt.bufPrint(&self.right_buf, "{s}", .{self.opts.badge}) catch "",
        };
        const status_color = if (self.phase == .loading) style.ACCENT_SOFT else style.DIM;
        self.emitRow(status, status_color, collapse_p * 8.0);
    }

    /// The loading state is a real skeleton: it shows skills as they are found
    /// and a spinner bound to the number of roots actually visited.
    fn renderLoading(self: *Prompt) void {
        self.rail();
        self.row.add("  ");
        self.row.add(style.ACCENT);
        self.row.add(anim.spinnerFrame(self.now, 80));
        self.row.add(term.RESET);
        self.row.add(" ");
        self.row.add(style.mixAt(&self.scratch_a, 240, 248, 0.9));
        self.row.addFmt("scanning {d} agent roots", .{self.roots.len});
        self.row.add(term.RESET);
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 236, 242, 0.8));
        self.row.addFmt("{d} root{s} visited · {d} skill{s} found", .{
            self.visited_roots,
            if (self.visited_roots == 1) "" else "s",
            self.skills_list.items.len,
            if (self.skills_list.items.len == 1) "" else "s",
        });
        self.row.add(term.RESET);
        self.emitRow("", style.DIM, 0);
        self.rail();
        self.emitRow("", style.DIM, 0);

        const lh = self.listHeight();
        const n = self.skills_list.items.len;
        var i: usize = 0;
        while (i < lh) : (i += 1) {
            self.rail();
            if (i < n) {
                const s = self.skills_list.items[i];
                // Same cursor + connector slots as a real row, so the skeleton
                // does not shift when the list lands.
                self.row.add("   ");
                self.row.add("   ");
                self.row.add(style.mixAt(&self.scratch_a, 238, 246, 1.0));
                self.row.add(style.RADIO_OFF);
                self.row.add(term.RESET);
                self.row.add(" ");
                self.row.add(style.mixAt(&self.scratch_a, 236, 244, 0.9));
                self.row.add(s.name);
                self.row.add(term.RESET);
                const cache = std.fmt.bufPrint(&self.right_buf, "{d} files", .{s.files}) catch "";
                self.emitRow(cache, style.FAINT, 0);
            } else {
                // Placeholder shimmer while the scan is still running.
                const p = @as(f32, @floatFromInt(@mod(self.now + @as(i64, @intCast(i)) * 120, 1500))) / 1500.0;
                const intensity = anim.shimmer(i * 6, lh * 6, p, 10.0);
                self.row.add("  ");
                self.row.add(style.mixAt(&self.scratch_a, 234, 239, 0.25 + intensity * 0.6));
                self.row.add("· · ·");
                self.row.add(term.RESET);
                self.emitRow("", style.DIM, 0);
            }
        }
    }

    fn renderSearch(self: *Prompt) void {
        self.rail();
        self.emitRow("", style.DIM, 0);
        if (!self.opts.searchable) return;

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
            self.row.add("↑↓ move   space select   ←→ group   tab next   ↵ confirm   esc cancel");
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
        }

        self.rail();
        self.emitRow("", style.DIM, 0);
    }

    /// Full-width rule that separates the controls from the list.
    fn renderSeparator(self: *Prompt, alpha: f32) void {
        self.rail();
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 234, 239, alpha));
        self.hRepeat(style.SEP_H, if (self.cols > 3) self.cols - 3 else 1);
        self.row.add(term.RESET);
        self.emitRow("", style.DIM, 0);
    }

    fn renderSelectAll(self: *Prompt, alpha: f32) void {
        if (!self.opts.select_all) return;

        const is_cursor = self.cursor == 0;
        self.rail();
        self.row.add(" ");
        self.cursorGlyph(is_cursor);
        self.row.add(" ");
        self.connector(.select_all, false, false, 1.0, alpha);

        const state = self.selectAllState();
        const fill: f32 = switch (state) {
            .all => 1.0,
            .partial => 0.5,
            .none => 0.0,
        };
        self.radioGlyph(fill, state == .all or state == .partial, 0, 1.0, alpha);

        if (is_cursor) self.row.add(term.UNDERLINE);
        self.row.add(term.BOLD);
        self.row.add(style.mixAt(&self.scratch_a, 240, 252, if (is_cursor) 1.0 else 0.85 * alpha + 0.15));
        self.row.add("Select all");
        self.row.add(term.RESET);

        const right = std.fmt.bufPrint(&self.right_buf, "{d}/{d}", .{
            self.sel_counter.value(), self.skills.len,
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

    fn hRepeat(self: *Prompt, s: []const u8, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.row.add(s);
    }

    fn renderList(self: *Prompt, alpha: f32) void {
        const lh = self.listHeight();
        const total = self.entries.items.len;

        if (total == 0) {
            self.rail();
            self.row.add("  ");
            self.row.add(style.mixAt(&self.scratch_a, 240, 245, alpha));
            self.row.add(if (self.query.items.len > 0) "no skills match that filter" else "no skills found in this scope");
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
                .skill => self.renderSkillRow(entry, is_cursor, fade, alpha),
                .group => self.renderGroupRow(entry, is_cursor, fade, alpha),
                .select_all => {},
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

    /// Three-cell slot between the cursor and the radio. Groups show a
    /// disclosure triangle and children show a tree elbow; both occupy exactly
    /// three cells so every radio lands in the same column.
    fn connector(self: *Prompt, kind: Kind, collapsed: bool, is_last: bool, fade: f32, alpha: f32) void {
        self.row.add(style.mixAt(&self.scratch_b, 236, 240, fade * alpha));
        switch (kind) {
            .group => {
                self.row.add(if (collapsed) style.COLLAPSED else style.EXPANDED);
                self.row.add("  ");
            },
            .skill => {
                self.row.add(if (is_last) style.TREE_END else style.TREE_MID);
                self.row.add(" ");
            },
            else => self.row.add("   "),
        }
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

    fn renderSkillRow(self: *Prompt, entry: Entry, is_cursor: bool, fade: f32, alpha: f32) void {
        const s = self.skills[entry.skill];
        const group = self.groups.items[entry.group];
        const pos = indexIn(group.items, entry.skill);
        const is_last = pos + 1 == group.items.len;

        self.connector(.skill, false, is_last, fade, alpha);

        const selected = self.selected.items[entry.skill];
        const rp = self.radio.items[entry.skill].value;
        self.radioGlyph(rp, selected, self.flash.items[entry.skill], fade, alpha);

        if (is_cursor) self.row.add(term.UNDERLINE);
        if (selected) self.row.add(term.BOLD);
        self.row.add(style.mixAt(&self.scratch_a, if (selected) @as(u8, 246) else 240, if (is_cursor) @as(u8, 255) else 250, if (is_cursor) 1.0 else fade * alpha));
        self.row.add(s.name);
        self.row.add(term.RESET);

        if (s.title.len > 0) {
            self.row.add("  ");
            self.row.add(style.mixAt(&self.scratch_a, 235, 241, fade * alpha));
            self.row.add(s.title);
            self.row.add(term.RESET);
        }
        if (!s.has_frontmatter) {
            self.row.add(" ");
            self.row.add(style.AMBER);
            self.row.add("!");
            self.row.add(term.RESET);
        }
        self.pending_right = self.hint.items[entry.skill];
        self.pending_right_color = style.mixAt(&self.scratch_b, 236, 243, fade * alpha);
    }

    fn renderGroupRow(self: *Prompt, entry: Entry, is_cursor: bool, fade: f32, alpha: f32) void {
        const gi = entry.group;
        const group = self.groups.items[gi];

        self.connector(.group, group.collapsed, false, fade, alpha);

        const sel = groupSelection(self, gi);
        const full = sel.n == sel.total and sel.total > 0;
        const partial = sel.n > 0 and !full;
        const fill: f32 = if (full) 1.0 else if (partial) 0.5 else 0.0;
        self.radioGlyph(fill, full or partial, 0, fade, alpha);

        if (is_cursor) self.row.add(term.UNDERLINE);
        self.row.add(term.BOLD);
        self.row.add(style.mixAt(&self.scratch_a, 241, 253, if (is_cursor) 1.0 else fade * alpha));
        self.row.add(group.label);
        self.row.add(term.RESET);
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 234, 239, fade * alpha));
        self.row.add(group.path);
        self.row.add(term.RESET);

        if (sel.n > 0) {
            self.pending_right = std.fmt.bufPrint(&self.right_buf, "{d}/{d}", .{ sel.n, sel.total }) catch "";
            self.pending_right_color = style.mixAt(&self.scratch_b, 34, 42, fade * alpha);
        }
    }

    /// Flushes the right-aligned hint a row stashed while its body was built.
    fn emitRowRightRow(self: *Prompt) void {
        const right = self.pending_right;
        const color = self.pending_right_color;
        self.pending_right = "";
        self.pending_right_color = "";
        self.emitRow(right, color, 0);
    }

    fn renderDetail(self: *Prompt, alpha: f32) void {
        self.ensureDetail();

        self.rail();
        self.row.add("  ");
        self.row.add(style.mixAt(&self.scratch_a, 237, 242, 0.75 * alpha));
        self.row.add("Description");
        self.row.add(term.RESET);
        if (self.detail_group) {
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
        if (self.detail_valid and
            self.detail_key == @as(i64, @intCast(self.cursor)) and
            self.detail_cols == self.cols) return;
        self.detail_key = @intCast(self.cursor);
        self.detail_cols = self.cols;
        self.detail_valid = true;
        self.detail_anim.begin(self.now);
        self.detail_group = false;

        // Everything below is rebuilt from scratch, so the previous detail text
        // is dead. Reset — keeping the capacity — instead of accumulating.
        _ = self.detail_arena.reset(.retain_capacity);
        const da = self.detail_arena.allocator();

        var text: []const u8 = "";
        if (self.cursor < self.settled.items.len) {
            const entry = self.settled.items[self.cursor];
            switch (entry.kind) {
                .select_all => text = std.fmt.allocPrint(da, "Select or clear every skill the current filter matches ({d} of {d}).", .{
                    self.matched.items.len, self.skills.len,
                }) catch "",
                .group => {
                    const g = self.groups.items[entry.group];
                    self.detail_group = true;
                    const root = self.roots[g.root_index];
                    if (root.agents.len > 1) {
                        var list = bufmod.Buf.init(da);
                        list.addFmt("{d} skills at {s}, shared by ", .{ g.total, g.path });
                        const shown = @min(root.agents.len, 4);
                        for (root.agents[0..shown], 0..) |name, i| {
                            if (i > 0) list.add(", ");
                            list.add(name);
                        }
                        if (root.agents.len > shown) {
                            list.addFmt(" and {d} more agents", .{root.agents.len - shown});
                        } else {
                            list.add(".");
                        }
                        text = list.bytes();
                    } else {
                        text = std.fmt.allocPrint(da, "{d} skills installed for {s} at {s}.", .{
                            g.total, g.label, g.path,
                        }) catch "";
                    }
                },
                .skill => {
                    const s = self.skills[entry.skill];
                    var b = bufmod.Buf.init(da);
                    b.add(s.description);
                    if (s.extras.len > 0) b.addFmt("  Bundles {s}.", .{s.extras});
                    if (s.license.len > 0) b.addFmt("  License {s}.", .{s.license});
                    if (s.scope == .global) b.add("  Installed globally.") else b.add("  Committed with this project.");
                    if (!s.has_frontmatter) b.add("  No frontmatter block, so agents cannot index it.");
                    text = b.bytes();
                },
            }
        }

        const w = if (self.cols > 8) self.cols - 5 else 20;
        // `wrapLines` allocates from `da` too, so the slices it returns stay
        // valid until the next reset — which only happens on the next recompute.
        const lines = width.wrapLines(da, text, w, self.opts.detail_lines) catch &.{};
        var i: usize = 0;
        while (i < self.opts.detail_lines and i < max_detail_cache) : (i += 1) {
            self.detail_cache[i] = if (i < lines.len) lines[i] else "";
        }
    }

    fn renderSummary(self: *Prompt, alpha: f32) void {
        self.rail();
        self.row.add("  ");

        const n = self.selectionCount();
        if (n == 0) {
            self.row.add(style.mixAt(&self.scratch_a, 238, 244, alpha));
            self.row.add(if (self.opts.require_selection) "Selection  none — pick at least one to continue" else "Selection  none");
            self.row.add(term.RESET);
            self.emitRow("", style.DIM, 0);
            return;
        }

        self.row.add(style.GREEN);
        self.row.add("Selection");
        self.row.add(term.RESET);
        self.row.add("  ");

        var shown: usize = 0;
        var used: usize = 0;
        for (self.selected.items, 0..) |s, i| {
            if (!s) continue;
            if (shown == 3) break;
            if (used > 0) {
                self.row.add(", ");
                used += 2;
            }
            self.row.add(style.mixAt(&self.scratch_a, 244, 250, alpha));
            self.row.add(self.skills[i].name);
            self.row.add(term.RESET);
            used += width.width(self.skills[i].name);
            shown += 1;
            if (used > 58) break;
        }
        if (n > shown) {
            self.row.add(style.mixAt(&self.scratch_a, 35, 42, alpha));
            self.row.addFmt(" +{d} more", .{n - shown});
            self.row.add(term.RESET);
        }
        self.emitRow("", style.DIM, 0);
    }

    fn renderFooter(self: *Prompt, alpha: f32) void {
        self.row.add(style.mixAt(&self.scratch_a, 235, 239, alpha));
        self.row.add(style.SEP_END);
        self.row.add(term.RESET);
        if (self.error_count > 0) {
            self.row.add("  ");
            self.row.add(style.AMBER);
            self.row.addFmt("{d} warning{s}", .{ self.error_count, if (self.error_count == 1) "" else "s" });
            self.row.add(term.RESET);
        }
        const total = std.fmt.bufPrint(&self.right_buf, "{d} skill{s} in {d} root{s}", .{
            self.skills.len,
            if (self.skills.len == 1) "" else "s",
            self.groups.items.len,
            if (self.groups.items.len == 1) "" else "s",
        }) catch "";
        self.emitRow(total, style.FAINT, 0);
    }

    /// Writes the frame with a full erase-and-redraw. The whole frame goes out
    /// in a single `write()` (plus DEC 2026 sync markers where supported) so
    /// the terminal never renders a half-updated prompt.
    ///
    /// The cursor walks up over the frame that is *currently on screen* — its
    /// height, not the new one's — which anchors the frame at its top. Using
    /// the new height instead would move the top down whenever the layout
    /// shrank, stranding the rows above it and redrawing them forever.
    pub fn flush(self: *Prompt, out: *term.Out, sync: bool) void {
        paint.flush(out, sync, self.frame.bytes(), &self.wrote_frame, &self.painted_rows, self.frame_rows);
    }

    /// Verifies the one-line-one-row invariant the repaint depends on: every
    /// row must measure exactly `cols` cells, otherwise it would soft-wrap and
    /// the `move up N` arithmetic would drift.
    pub fn checkFrame(self: *Prompt) FrameCheck {
        return paint.checkFrame(self.frame.bytes(), self.cols);
    }
};

pub const FrameCheck = paint.FrameCheck;

pub const RunResult = struct {
    outcome: Outcome,
    skills: []discover.Skill,
};

/// Drives the prompt against a real terminal.
///
/// The loop only repaints when something changed or something is still moving.
/// While idle it parks in `poll()` with an infinite timeout, so a prompt left
/// open costs no CPU — the animation system is what makes that possible
/// (`wantsAnimation` is the single source of truth).
pub fn run(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    roots: []discover.RootCandidate,
    opts: Options,
    out: *term.Out,
    sync: bool,
    cwd: []const u8,
) !RunResult {
    const p = try arena.create(Prompt);
    p.* = Prompt.init(arena, gpa, io, env, roots, opts, cwd);
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

        if (p.phase == .loading) {
            _ = p.loadTick(2);
            if (p.scan_complete and now - p.started_ms >= p.opts.min_load_ms) p.finalizeLoad();
        }

        const animating = p.wantsAnimation();
        // Never park while a frame is pending, or the prompt would sit blank
        // until the user pressed a key. The loading phase normally keeps this
        // from mattering, but relying on that would be fragile.
        const ready = term.pollInput(if (animating or p.dirty) 16 else null);

        if (ready) {
            const n = term.readInput(&inbuf);
            if (n > 0) p.handleInput(inbuf[0..n]);
        }

        // `pollInput` may have blocked, so re-read the clock before
        // integrating: `dt` has to cover the time we actually spent waiting.
        const now2 = term.nowMs(io);
        p.now = now2;
        const dt = @as(f32, @floatFromInt(@min(@max(now2 - last, 0), 100))) / 1000.0;
        last = now2;

        if (p.dirty or animating) {
            if (p.phase == .loading) {
                _ = p.loadTick(2);
                if (p.scan_complete and now2 - p.started_ms >= p.opts.min_load_ms) p.finalizeLoad();
            }
            p.update(dt);
            p.render();
            p.flush(out, sync);
        }

        if (p.outcome) |oc| {
            out.writeAll(term.RESET);
            out.writeAll(term.SHOW_CURSOR);
            out.flush();
            if (raw) |*r| r.restore();
            return .{ .outcome = oc, .skills = p.skills };
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

const GroupSel = struct { n: usize, total: usize };

fn groupSelection(self: *Prompt, gi: usize) GroupSel {
    const g = self.groups.items[gi];
    var n: usize = 0;
    for (g.items) |s| {
        if (self.selected.items[s]) n += 1;
    }
    return .{ .n = n, .total = g.total };
}

fn addSpaces(b: *bufmod.Buf, n: usize) void {
    paint.addSpaces(b, n);
}

fn countRows(bytes: []const u8) usize {
    return paint.countRows(bytes);
}

fn lowerAlloc(arena: std.mem.Allocator, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    // One separator space is written after each part.
    const total = a.len + b.len + c.len + 3;
    const out = arena.alloc(u8, total) catch return "";
    var i: usize = 0;
    for ([_][]const u8{ a, b, c }) |part| {
        for (part) |ch| {
            out[i] = std.ascii.toLower(ch);
            i += 1;
        }
        out[i] = ' ';
        i += 1;
    }
    return out[0..i];
}

test "filters compose with AND" {
    const testing = std.testing;
    try testing.expect(containsAll("frontend design system", "design frontend"));
    try testing.expect(!containsAll("frontend design system", "backend"));
}

test "escape always produces an outcome" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/bliz-tui-test");

    var p = Prompt.init(arena, testing.allocator, testing.io, &env, &.{}, .{
        .force_cols = 80,
        .force_rows = 24,
    }, "/tmp");
    defer p.deinit();

    p.handleInput("\x1b");
    // `run` loops until it sees an outcome, so a cancel that only set the phase
    // would paint "cancelled" and then park in `poll()` with the cursor hidden,
    // swallowing every later keystroke.
    try testing.expect(p.outcome != null);
    try testing.expect(p.outcome.? == .cancelled);
}

fn containsAll(haystack: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |token| {
        if (std.mem.find(u8, haystack, token) == null) return false;
    }
    return true;
}
