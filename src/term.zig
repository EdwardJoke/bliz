//! Terminal primitives.
//!
//! Everything goes through libc / raw POSIX calls so the tool has zero
//! dependencies and no allocator-driven I/O machinery in the hot path.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn isatty(fd: c_int) c_int;

const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

/// `TIOCGWINSZ` — and it is *not* the same number on every POSIX target.
///
/// Getting it wrong fails silently rather than loudly. The ioctl returns an
/// error, `size()` falls back to 80x24, and every layout downstream is then
/// computed for a terminal nobody is using — no message, no exit code, just a
/// frame of the wrong shape. This was Darwin's value on every target until a
/// Linux CI run painted a 100x30 prompt as an 80-column frame, which put the
/// list's ninth row out of view and surfaced as an unrelated picker assertion
/// failing.
///
/// - Linux and the other `asm-generic` targets number ioctls flatly, from
///   `0x5400`: `<asm-generic/ioctls.h>` has `TIOCGWINSZ 0x5413`.
/// - Darwin and the BSDs pack a direction, a type byte and the argument size
///   into the request: `_IOR('t', 104, struct winsize)`, i.e. `_IOC_READ`
///   (`2`) in the top two bits, `'t'` in the next byte, `104` in the low byte
///   and `sizeof(struct winsize)` (`8`) above it.
const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5413, // asm-generic/ioctls.h
    else => 0x40087468, // _IOR('t', 104, struct winsize): Darwin, FreeBSD, NetBSD, OpenBSD
};

pub const Size = struct {
    cols: usize = 80,
    rows: usize = 24,
};

/// The size of the terminal behind `fd`, or the 80x24 default when there is no
/// terminal to ask — a redirected stdout, a CI log, a `| head` pipeline. The
/// prompt only runs on a TTY, so the default is a floor rather than a guess.
pub fn sizeOf(fd: c_int) Size {
    var ws: Winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0) {
        return .{ .cols = ws.col, .rows = ws.row };
    }
    return .{};
}

/// The size of the terminal the *prompt* draws on. Layout is measured in
/// columns of stdout, so that is the fd the kernel is asked about — not stdin,
/// which happens to be the same terminal in the interesting cases but is not
/// the thing being sized.
pub fn size() Size {
    return sizeOf(posix.STDOUT_FILENO);
}

pub fn stdinIsTty() bool {
    return isatty(posix.STDIN_FILENO) == 1;
}

pub fn stdoutIsTty() bool {
    return isatty(posix.STDOUT_FILENO) == 1;
}

/// Wall-clock milliseconds since the Unix epoch — for file ages, not timing.
pub fn wallMs(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Monotonic milliseconds — the frame clock. Never jumps backwards, so
/// spring integration stays stable even if the wall clock is adjusted.
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

pub const ESC = "\x1b";
pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const ITALIC = "\x1b[3m";
pub const UNDERLINE = "\x1b[4m";
pub const INVERSE = "\x1b[7m";
pub const STRIKE = "\x1b[9m";
pub const HIDE_CURSOR = "\x1b[?25l";
pub const SHOW_CURSOR = "\x1b[?25h";
pub const ERASE_BELOW = "\x1b[J";
pub const CLEAR_LINE = "\x1b[2K";
/// DEC 2026: terminals that support it present the frame atomically, which
/// removes the last bit of tearing during animated redraws.
pub const SYNC_BEGIN = "\x1b[?2026h";
pub const SYNC_END = "\x1b[?2026l";

pub fn moveUp(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d}A", .{n}) catch "";
}

pub fn moveToCol(buf: []u8, col: usize) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d}G", .{col}) catch "";
}

/// True when the host terminal understands DEC 2026 synchronized output.
pub fn supportsSyncOutput(env: *const std.process.Environ.Map) bool {
    const program = env.get("TERM_PROGRAM") orelse "";
    const known = [_][]const u8{
        "iTerm.app", "WezTerm",   "ghostty",  "kitty",    "alacritty",
        "vscode",    "Hyper",     "WarpTerminal", "Tabby", "rio",
    };
    for (known) |k| {
        if (std.mem.eql(u8, program, k)) return true;
    }
    const term = env.get("TERM") orelse "";
    if (std.mem.find(u8, term, "kitty") != null) return true;
    if (std.mem.find(u8, term, "ghostty") != null) return true;
    return false;
}

pub fn envTrue(env: *const std.process.Environ.Map, key: []const u8) bool {
    const v = env.get(key) orelse return false;
    if (v.len == 0) return true;
    return !std.mem.eql(u8, v, "0");
}

/// Buffered writer over a file descriptor. Frame text is assembled here and
/// flushed with exactly one `write(2)` so the terminal never sees half a frame.
pub const Out = struct {
    buf: []u8,
    len: usize = 0,
    fd: c_int = posix.STDOUT_FILENO,

    pub fn init(buf: []u8) Out {
        return .{ .buf = buf };
    }

    pub fn writeAll(self: *Out, s: []const u8) void {
        var rest = s;
        while (rest.len > 0) {
            const space = self.buf.len - self.len;
            if (space == 0) {
                self.flush();
                continue;
            }
            const n = @min(space, rest.len);
            @memcpy(self.buf[self.len .. self.len + n], rest[0..n]);
            self.len += n;
            rest = rest[n..];
        }
    }

    pub fn flush(self: *Out) void {
        if (self.len == 0) return;
        var off: usize = 0;
        while (off < self.len) {
            const n = write(self.fd, self.buf.ptr + off, self.len - off);
            if (n <= 0) break;
            off += @intCast(n);
        }
        self.len = 0;
    }
};

/// Puts the controlling terminal into cbreak-ish raw mode and restores it on
/// drop, with a panic-time guard so a crash never leaves a wedged shell.
pub const RawMode = struct {
    fd: c_int,
    saved: posix.termios,
    active: bool = false,

    pub fn enable() ?RawMode {
        const fd = posix.STDIN_FILENO;
        if (isatty(fd) != 1) return null;
        const saved = posix.tcgetattr(fd) catch return null;
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = true;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(fd, .NOW, raw) catch return null;
        return .{ .fd = fd, .saved = saved, .active = true };
    }

    pub fn restore(self: *RawMode) void {
        if (!self.active) return;
        posix.tcsetattr(self.fd, .NOW, self.saved) catch {};
        self.active = false;
    }

    pub fn deinit(self: *RawMode) void {
        self.restore();
    }
};

var restore_hook: ?*anyopaque = null;

/// Installs a SIGINT/SIGTERM handler that restores the terminal before exiting.
pub fn installSignalGuard(raw: *RawMode) void {
    restore_hook = raw;
    var act = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    if (restore_hook) |p| {
        const raw: *RawMode = @ptrCast(@alignCast(p));
        raw.restore();
    }
    const seq = "\x1b[?25h\x1b[0m\n";
    _ = write(posix.STDOUT_FILENO, seq.ptr, seq.len);
    std.process.exit(@intCast(128 + @intFromEnum(sig)));
}

var resize_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn installResizeHandler() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = handleResize },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

fn handleResize(_: posix.SIG) callconv(.c) void {
    resize_flag.store(true, .release);
}

pub fn takeResize() bool {
    return resize_flag.swap(false, .acquire);
}

/// Waits for input, or for `timeout_ms` to elapse. `null` means block forever.
pub fn pollInput(timeout_ms: ?i32) bool {
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const n = posix.poll(&fds, timeout_ms orelse -1) catch return false;
    return n > 0;
}

pub fn readInput(buf: []u8) usize {
    return posix.read(posix.STDIN_FILENO, buf) catch 0;
}

test "the window-size request is encoded for the target, not copied from Darwin" {
    // Asserted as a *property* rather than by restating the table, because the
    // table is the thing that was wrong. The two encodings are structurally
    // different, so a constant that looks like one and is used as the other is
    // the bug — decode the BSD form and show the split is real.
    //
    // BSD packs it as `_IOC(dir, 't', 104, sizeof(struct winsize))`: a direction
    // in the top two bits, then one argument size, then the type, then the
    // number. Bit 30 is `IOC_OUT` here — the kernel *writes* the struct back
    // through the pointer — not "read" in the syscall sense.
    const bsd: c_ulong = 0x40087468;
    const flat: c_ulong = 0x5413;

    try std.testing.expect(bsd != flat);
    try std.testing.expectEqual(@as(c_ulong, 1), bsd >> 30); // IOC_OUT
    try std.testing.expectEqual(@as(c_ulong, 't'), (bsd >> 8) & 0xff); // the tty group
    try std.testing.expectEqual(@as(c_ulong, 104), bsd & 0xff); // the request number
    try std.testing.expectEqual(@as(c_ulong, 8), (bsd >> 16) & 0x3fff); // sizeof(struct winsize)

    switch (builtin.os.tag) {
        .linux => try std.testing.expectEqual(flat, TIOCGWINSZ),
        else => try std.testing.expectEqual(bsd, TIOCGWINSZ),
    }
}

test "the no-terminal fallback is 80x24, which is what a wrong request gets" {
    // `sizeOf` cannot fail; it reports the default instead, which is exactly why
    // a mis-encoded ioctl is invisible downstream — the layout simply becomes
    // the shape of a terminal nobody is using. Pin the value, and note that the
    // real end-to-end guard is the PTY harness, which asserts the prompt painted
    // at the size the terminal was set to. (There is no portable way to hand
    // this test a non-TTY fd in 0.16: `std.posix.pipe` is gone.)
    try std.testing.expectEqual(@as(usize, 80), (Size{}).cols);
    try std.testing.expectEqual(@as(usize, 24), (Size{}).rows);
}
