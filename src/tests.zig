//! Test aggregator.
//!
//! `zig build test` compiles this file as the test root. Zig only collects the
//! tests of files that are actually referenced, so every module with unit tests
//! has to be named here — adding a test to a module that is missing from this
//! list would silently never run.

const std = @import("std");

test {
    _ = @import("width.zig");
    _ = @import("buf.zig");
    _ = @import("paint.zig");
    _ = @import("tui.zig");
    _ = @import("pick.zig");
    _ = @import("install.zig");
    _ = @import("registry.zig");
}
