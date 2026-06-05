//! Compatibility shim for production network frame encoding.
//!
//! New code should import `network/frame.zig` directly.

const impl = @import("network/frame.zig");

pub const node_id_size = impl.node_id_size;
pub const size_size = impl.size_size;
pub const checksum_size = impl.checksum_size;
pub const reserved_size = impl.reserved_size;

pub const size_offset = impl.size_offset;
pub const checksum_header_offset = impl.checksum_header_offset;
pub const checksum_body_offset = impl.checksum_body_offset;
pub const from_offset = impl.from_offset;
pub const to_offset = impl.to_offset;
pub const reserved_offset = impl.reserved_offset;
pub const payload_offset = impl.payload_offset;

pub const header_len = impl.header_len;
pub const max_frame_size = impl.max_frame_size;

pub const FrameError = impl.FrameError;
pub const EncodeOptions = impl.EncodeOptions;
pub const Decoded = impl.Decoded;
pub const Header = impl.Header;

pub const encodedLen = impl.encodedLen;
pub const encode = impl.encode;
pub const decode = impl.decode;
pub const decodeParts = impl.decodeParts;
pub const decodeHeader = impl.decodeHeader;
