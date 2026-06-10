//! Translation from Marionette fault errors to `std.Io` error vocabularies.

const std = @import("std");
const disk_module = @import("../disk/root.zig");
const Io = std.Io;

pub fn mapNetworkReadError(err: anyerror) Io.net.Stream.Reader.Error {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        else => error.NetworkDown,
    };
}

pub fn mapNetworkWriteError(err: anyerror) Io.net.Stream.Writer.Error {
    return switch (err) {
        error.OutOfMemory,
        error.EventQueueFull,
        => error.SystemResources,
        error.InvalidNode => error.NetworkUnreachable,
        error.NetworkUnavailable,
        error.InvalidDuration,
        error.InvalidRate,
        => error.NetworkDown,
        else => error.NetworkDown,
    };
}

pub fn mapDiskReadError(err: disk_module.DiskError) Io.File.ReadPositionalError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        else => error.InputOutput,
    };
}

pub fn mapDiskWriteError(err: disk_module.DiskError) Io.File.WritePositionalError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        else => error.InputOutput,
    };
}

pub fn mapDiskSyncError(err: disk_module.DiskError) Io.File.SyncError {
    return switch (err) {
        error.DiskUnavailable,
        error.FileNotFound,
        error.DiskCrashed,
        error.WriteError,
        error.ReadError,
        error.InvalidAlignment,
        error.InvalidDuration,
        error.InvalidPath,
        error.InvalidRate,
        error.InvalidRange,
        error.OutOfMemory,
        error.InvalidTracePayload,
        => error.InputOutput,
    };
}

pub fn mapDiskOpenError(err: disk_module.DiskError) Io.File.OpenError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.FileNotFound,
        else => error.SystemResources,
    };
}

pub fn mapDiskSetLengthError(err: disk_module.DiskError) Io.File.SetLengthError {
    return switch (err) {
        error.OutOfMemory => error.InputOutput,
        error.FileNotFound => error.AccessDenied,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.AccessDenied,
        else => error.InputOutput,
    };
}

pub fn mapDiskDeleteError(err: disk_module.DiskError) Io.Dir.DeleteFileError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.FileNotFound,
        else => error.FileSystem,
    };
}

pub fn mapDiskRenameError(err: disk_module.DiskError) Io.Dir.RenameError {
    return switch (err) {
        error.OutOfMemory => error.SystemResources,
        error.FileNotFound => error.FileNotFound,
        error.InvalidPath,
        error.InvalidAlignment,
        error.InvalidRange,
        => error.FileNotFound,
        else => error.HardwareFailure,
    };
}
