//! Test-only authority for configuring and crashing a disk.

const model = @import("model.zig");

const Disk = model.Disk;
const DiskError = model.DiskError;
const DiskFaultOptions = model.DiskFaultOptions;

/// Simulator-control view over the simulated disk, obtained as
/// `sim.control.disk`. See `docs/disk-fault-model.md` for the fault and
/// recovery vocabulary these operations implement.
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

    /// Replace the disk's probabilistic fault rates. Invalid rates return
    /// `error.InvalidRate`. Zero rates consume no randomness and emit no
    /// trace when rolled.
    pub fn setFaults(self: DiskControl, faults: DiskFaultOptions) DiskError!void {
        try self.vtable.set_faults(self.ptr, faults);
    }

    /// Explicitly corrupt one sector so the next read of it fails. This is
    /// a destructive fault: it may damage durable truth, unlike crash
    /// fault classes, which only affect pending writes. Traced as
    /// `disk.fault`.
    pub fn corruptSector(self: DiskControl, path: []const u8, offset: u64) DiskError!void {
        try self.vtable.corrupt_sector(self.ptr, path, offset);
    }

    /// Crash the disk now: pending writes land, tear, reorder, or vanish
    /// according to the configured crash fault rates, pending metadata
    /// commits or rolls back, and every live logical process is killed.
    /// Until `restart`, disk operations return `error.DiskCrashed`.
    /// Traced as `disk.crash`.
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

    /// Bring a crashed disk back up. Only the disk recovers; killed
    /// logical processes restart separately through
    /// `sim.control.process.restart`. Traced as `disk.restart`.
    pub fn restart(self: DiskControl) DiskError!void {
        try self.vtable.restart(self.ptr);
    }

    /// Return the app-facing disk handle this control drives.
    pub fn disk(self: DiskControl) Disk {
        return self.vtable.disk(self.ptr);
    }
};
