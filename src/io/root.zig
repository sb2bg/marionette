//! Marionette's deterministic `std.Io` implementation.

const backend = @import("backend.zig");

pub const FutexWaitResult = backend.FutexWaitResult;
pub const FutexWaitSet = backend.FutexWaitSet;
pub const ProcessId = @import("task.zig").ProcessId;
pub const TaskRuntime = @import("task.zig").TaskRuntime;
pub const TaskControl = @import("task.zig").TaskControl;
pub const ProcessTaskControl = @import("task.zig").ProcessTaskControl;
pub const Backend = backend.Backend;
pub const ProcessRegistry = backend.ProcessRegistry;
pub const ProcessRuntime = backend.ProcessRuntime;

pub const deinitBackendOpaque = backend.deinitBackendOpaque;
pub const onDiskCrashOpaque = backend.onDiskCrashOpaque;
pub const deinitProcessRuntimeOpaque = backend.deinitProcessRuntimeOpaque;
pub const onProcessRuntimeDiskCrashOpaque = backend.onProcessRuntimeDiskCrashOpaque;

test {
    _ = backend;
    _ = @import("tests.zig");
}
