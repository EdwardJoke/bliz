//! Animation primitives.
//!
//! Nothing here knows about terminals or skills. It is a small, honest
//! animation toolkit: critically-damped springs, eased tweens, a braille
//! spinner, a shimmer sweep and a stagger scheduler. The frame loop asks
//! "are you still moving?" and stops repainting when the answer is no, which
//! is what keeps an idle prompt at 0% CPU.

const std = @import("std");

pub fn easeOutCubic(t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    const inv = 1.0 - c;
    return 1.0 - inv * inv * inv;
}

pub fn easeOutQuint(t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    const inv = 1.0 - c;
    return 1.0 - inv * inv * inv * inv * inv;
}

pub fn easeInOutCubic(t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    if (c < 0.5) return 4.0 * c * c * c;
    const f = -2.0 * c + 2.0;
    return 1.0 - f * f * f / 2.0;
}

pub fn easeOutBack(t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    const c1: f32 = 1.70158;
    const c3 = c1 + 1.0;
    const inv = c - 1.0;
    return 1.0 + c3 * inv * inv * inv + c1 * inv * inv;
}

/// Critically damped-ish spring. Frame-rate independent because the integrated
/// step is derived from the real frame delta, clamped so a long stall (debugger
/// pause, terminal suspend) can never launch the value into orbit.
pub const Spring = struct {
    value: f32,
    target: f32,
    velocity: f32 = 0,
    stiffness: f32 = 220.0,
    damping: f32 = 26.0,

    pub fn at(v: f32) Spring {
        return .{ .value = v, .target = v };
    }

    pub fn withResponse(v: f32, stiffness: f32, damping: f32) Spring {
        return .{ .value = v, .target = v, .stiffness = stiffness, .damping = damping };
    }

    pub fn setTarget(self: *Spring, t: f32) void {
        self.target = t;
    }

    pub fn snap(self: *Spring, v: f32) void {
        self.value = v;
        self.target = v;
        self.velocity = 0;
    }

    pub fn step(self: *Spring, dt_seconds: f32) void {
        const dt = std.math.clamp(dt_seconds, 0.0, 1.0 / 20.0);
        var remaining = dt;
        // Sub-step for stability; also keeps very fast springs from overshooting.
        while (remaining > 0.0001) {
            const h = @min(remaining, 1.0 / 240.0);
            const force = (self.target - self.value) * self.stiffness;
            self.velocity = (self.velocity + force * h) * (1.0 - self.damping * h);
            self.value += self.velocity * h;
            remaining -= h;
        }
        if (self.settled()) {
            self.value = self.target;
            self.velocity = 0;
        }
    }

    pub fn settled(self: *const Spring) bool {
        return @abs(self.target - self.value) < 0.004 and @abs(self.velocity) < 0.02;
    }
};

/// One-shot eased progress in [0,1] over `duration_ms`, anchored at `start_ms`.
pub const Tween = struct {
    start_ms: i64,
    duration_ms: i64,
    delay_ms: i64 = 0,
    easing: *const fn (f32) f32 = easeOutCubic,

    pub fn begin(self: *Tween, now_ms: i64) void {
        self.start_ms = now_ms;
    }

    pub fn raw(self: *const Tween, now_ms: i64) f32 {
        const elapsed = now_ms - self.start_ms - self.delay_ms;
        if (elapsed <= 0) return 0.0;
        if (elapsed >= self.duration_ms) return 1.0;
        return @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms));
    }

    pub fn progress(self: *const Tween, now_ms: i64) f32 {
        return self.easing(self.raw(now_ms));
    }

    pub fn done(self: *const Tween, now_ms: i64) bool {
        return now_ms - self.start_ms - self.delay_ms >= self.duration_ms;
    }

    pub fn active(self: *const Tween, now_ms: i64) bool {
        return !self.done(now_ms);
    }
};

/// Braille spinner. The frames are visually ordered by weight so the rotation
/// reads as motion rather than flicker.
pub const spinner_frames = [_][]const u8{
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
};

/// A slightly different cadence for the "still working" pulse.
pub const pulse_frames = [_][]const u8{ "·", "•", "●", "•" };

pub fn spinnerFrame(now_ms: i64, period_ms: i64) []const u8 {
    if (period_ms <= 0) return spinner_frames[0];
    const step = @divFloor(now_ms, period_ms);
    const idx: usize = @intCast(@mod(step, @as(i64, @intCast(spinner_frames.len))));
    return spinner_frames[idx];
}

/// Travelling highlight for headers. Returns 0..1 intensity for a cell at
/// position `i` of `len`, given a phase in cells.
pub fn shimmer(i: usize, len: usize, phase: f32, spread: f32) f32 {
    if (len == 0) return 0;
    const center = phase * @as(f32, @floatFromInt(len + @as(usize, @intFromFloat(spread * 2.0))));
    const dist = @abs(@as(f32, @floatFromInt(i)) + spread - center);
    if (dist >= spread) return 0;
    const t = 1.0 - dist / spread;
    return t * t;
}

/// Staggered entrance: cell index -> eased intensity, capped so long lists
/// never take longer than `max_total_ms` to fully appear.
pub fn stagger(index: usize, now_ms: i64, start_ms: i64, per_item_ms: i64, item_ms: i64, max_items: usize) f32 {
    const capped = @min(index, max_items);
    const begin = start_ms + @as(i64, @intCast(capped)) * per_item_ms;
    const elapsed = now_ms - begin;
    if (elapsed <= 0) return 0.0;
    if (elapsed >= item_ms) return 1.0;
    return easeOutCubic(@as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(item_ms)));
}

/// Rolling integer used by counters so a changing value counts up instead of
/// jumping: the displayed number interpolates toward the real one.
pub const Counter = struct {
    shown: f32 = 0,
    target: f32 = 0,
    speed: f32 = 14.0,

    pub fn set(self: *Counter, v: f32) void {
        if (v != self.target) self.target = v;
    }

    pub fn jump(self: *Counter, v: f32) void {
        self.shown = v;
        self.target = v;
    }

    pub fn step(self: *Counter, dt_seconds: f32) void {
        const dt = std.math.clamp(dt_seconds, 0.0, 1.0 / 20.0);
        const diff = self.target - self.shown;
        if (@abs(diff) < 0.01) {
            self.shown = self.target;
            return;
        }
        self.shown += diff * @min(1.0, self.speed * dt);
    }

    pub fn value(self: *const Counter) usize {
        return @intFromFloat(@max(0.0, self.shown) + 0.5);
    }

    pub fn moving(self: *const Counter) bool {
        return @abs(self.target - self.shown) >= 0.01;
    }
};
