//! Marionette's deterministic `std.Io` implementation.

const backend = @import("backend.zig");

pub const FutexWaitResult = backend.FutexWaitResult;
pub const FutexWaitSet = backend.FutexWaitSet;
pub const Backend = backend.Backend;

pub const deinitBackendOpaque = backend.deinitBackendOpaque;
pub const onDiskCrashOpaque = backend.onDiskCrashOpaque;

test {
    _ = backend;
    _ = @import("tests.zig");
}
