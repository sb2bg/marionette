//! Compatibility shim for production network transport helpers.
//!
//! New code should import `network/transport.zig` directly.

const impl = @import("network/transport.zig");

pub const TransportError = impl.TransportError;
pub const ReceivedFrame = impl.ReceivedFrame;

pub const frameLen = impl.frameLen;
pub const sendFrame = impl.sendFrame;
pub const receiveFrame = impl.receiveFrame;
