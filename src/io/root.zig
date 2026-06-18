//! Marionette's deterministic `std.Io` implementation.

const backend = @import("backend.zig");
const task = @import("task.zig");

/// Process-scoped deterministic `std.Io` runtime exposed through
/// `World.Simulation.io_runtime`.
pub const ProcessRuntime = backend.ProcessRuntime;

/// Internal composition hooks for Marionette's world, scheduler, and backend.
pub const internal = struct {
    pub const FutexWaitResult = backend.FutexWaitResult;
    pub const FutexWaitSet = backend.FutexWaitSet;
    pub const ProcessId = task.ProcessId;
    pub const TaskRuntime = task.TaskRuntime;
    pub const TaskControl = task.TaskControl;
    pub const ProcessTaskControl = task.ProcessTaskControl;
    pub const Backend = backend.Backend;
    pub const ProcessRegistry = backend.ProcessRegistry;
    pub const ProcessRuntime = backend.ProcessRuntime;

    pub const deinitBackendOpaque = backend.deinitBackendOpaque;
    pub const onDiskCrashOpaque = backend.onDiskCrashOpaque;
    pub const deinitProcessRuntimeOpaque = backend.deinitProcessRuntimeOpaque;
    pub const onProcessRuntimeDiskCrashOpaque = backend.onProcessRuntimeDiskCrashOpaque;
};

test {
    _ = backend;
    _ = task;
    _ = @import("tests.zig");
}
