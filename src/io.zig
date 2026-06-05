//! Compatibility shim for Marionette's deterministic `std.Io` backend.
//!
//! New implementation work should live under `io/`.

const backend = @import("io/backend.zig");

pub const FutexWaitResult = backend.FutexWaitResult;
pub const FutexWaitSet = backend.FutexWaitSet;
pub const Backend = backend.Backend;

pub const deinitBackendOpaque = backend.deinitBackendOpaque;
