//! Compatibility shim for the network IO seam.
//!
//! New code should import `network/io.zig` directly.

const impl = @import("network/io.zig");

pub const NetworkIoError = impl.NetworkIoError;
pub const NetworkIo = impl.NetworkIo;
pub const Listener = impl.Listener;
pub const Connection = impl.Connection;
pub const Host = impl.Host;
pub const Fake = impl.Fake;

pub const readExact = impl.readExact;
pub const writeAll = impl.writeAll;
