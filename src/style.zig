//! Palette and color helpers.
//!
//! The look is deliberately restrained: one accent (blue), one success color
//! (green), one warning (amber), and a wide grayscale ramp used by every fade
//! animation. Ramp-based fades are what let rows, hints and the detail pane
//! animate smoothly instead of snapping between "on" and "off".

const std = @import("std");

pub const ACCENT = "\x1b[38;5;39m";
pub const ACCENT_SOFT = "\x1b[38;5;32m";
pub const GREEN = "\x1b[38;5;42m";
pub const GREEN_SOFT = "\x1b[38;5;35m";
pub const AMBER = "\x1b[38;5;214m";
pub const RED = "\x1b[38;5;203m";
pub const VIOLET = "\x1b[38;5;141m";

pub const TEXT = "\x1b[38;5;252m";
pub const MUTED = "\x1b[38;5;246m";
pub const DIM = "\x1b[38;5;242m";
pub const FAINT = "\x1b[38;5;238m";
pub const GHOST = "\x1b[38;5;235m";

/// 232 (near black) .. 255 (near white) — the terminal grayscale ramp.
pub const GRAY_MIN: u8 = 232;
pub const GRAY_MAX: u8 = 255;

/// Any xterm-256 colour index. Accents live in the 16..231 cube; fades live in
/// the 232..255 ramp. Mixing the two up silently clamps every accent to black,
/// so the two helpers are kept separate and explicit.
pub fn color256(scratch: []u8, index: u8) []const u8 {
    return std.fmt.bufPrint(scratch, "\x1b[38;5;{d}m", .{index}) catch "";
}

/// Formats a grayscale ramp SGR into `scratch` and returns the slice.
pub fn gray(scratch: []u8, level: u8) []const u8 {
    const clamped = @min(@max(level, GRAY_MIN), GRAY_MAX);
    return color256(scratch, clamped);
}

/// Maps 0..1 to the grayscale ramp. Used for stagger/fade animations.
pub fn grayAt(scratch: []u8, t: f32) []const u8 {
    const c = std.math.clamp(t, 0.0, 1.0);
    const level = GRAY_MIN + @as(u8, @intFromFloat(c * @as(f32, @floatFromInt(GRAY_MAX - GRAY_MIN)) + 0.5));
    return gray(scratch, level);
}

/// Interpolates two xterm-256 indices, e.g. ramp positions for a fade or cube
/// colours for an accent pulse.
pub fn mixIndex(lo: u8, hi: u8, t: f32) u8 {
    const c = std.math.clamp(t, 0.0, 1.0);
    const span = @as(f32, @floatFromInt(hi)) - @as(f32, @floatFromInt(lo));
    return @intFromFloat(@as(f32, @floatFromInt(lo)) + span * c + 0.5);
}

pub fn mixAt(scratch: []u8, lo: u8, hi: u8, t: f32) []const u8 {
    return color256(scratch, mixIndex(lo, hi, t));
}

/// The five-step radio used by the reference UI, plus the quarter states we
/// animate through when a row is toggled.
pub const RADIO_ON = "●";
pub const RADIO_OFF = "○";
pub const RADIO_PARTIAL = "◐";
pub const RADIO_FILL = [_][]const u8{ "○", "◔", "◑", "◕", "●" };

pub const SEP = "│";
pub const SEP_H = "─";
pub const SEP_END = "└";
pub const CURSOR = "❯";
pub const BULLET = "•";
pub const TREE_MID = "├─";
pub const TREE_END = "└─";
pub const EXPANDED = "▾";
pub const COLLAPSED = "▸";
pub const CHECK = "✓";
pub const DIAMOND_ACTIVE = "◆";
pub const DIAMOND_SUBMIT = "◇";
pub const DIAMOND_CANCEL = "■";
pub const SCROLL_THUMB = "┃";
pub const SCROLL_TRACK = "│";
pub const CARET = "▏";
pub const ARROW_UP = "↑";
pub const ARROW_DOWN = "↓";
