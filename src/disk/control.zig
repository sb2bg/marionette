//! Test-only authority for configuring and crashing a disk.

const model = @import("model.zig");

const Disk = model.Disk;
const DiskError = model.DiskError;
const DiskFaultOptions = model.DiskFaultOptions;

pub const DiskControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_faults: *const fn (*anyopaque, DiskFaultOptions) DiskError!void,
        corrupt_sector: *const fn (*anyopaque, []const u8, u64) DiskError!void,
        crash: *const fn (*anyopaque) DiskError!void,
        crash_after_ops: *const fn (*anyopaque, u64) DiskError!void,
        restart: *const fn (*anyopaque) DiskError!void,
        disk: *const fn (*anyopaque) Disk,
    };

    pub fn setFaults(self: DiskControl, faults: DiskFaultOptions) DiskError!void {
        try self.vtable.set_faults(self.ptr, faults);
    }

    pub fn corruptSector(self: DiskControl, path: []const u8, offset: u64) DiskError!void {
        try self.vtable.corrupt_sector(self.ptr, path, offset);
    }

    pub fn crash(self: DiskControl) DiskError!void {
        try self.vtable.crash(self.ptr);
    }

    /// Arm a structural crash: the disk crashes at the operation boundary
    /// after `ops` more data/metadata operations complete, applying the
    /// configured crash fault classes at that point. This places a crash at
    /// a structural point of the workload instead of a measured tick
    /// offset. Re-arming replaces the previous budget; any crash disarms.
    pub fn crashAfterOps(self: DiskControl, ops: u64) DiskError!void {
        try self.vtable.crash_after_ops(self.ptr, ops);
    }

    pub fn restart(self: DiskControl) DiskError!void {
        try self.vtable.restart(self.ptr);
    }

    pub fn disk(self: DiskControl) Disk {
        return self.vtable.disk(self.ptr);
    }
};
