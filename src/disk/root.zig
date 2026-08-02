//! Disk subsystem root.
//!
//! Assembles the public disk API from the focused control, model, simulation,
//! and production modules in this directory.

const control = @import("control.zig");
const model = @import("model.zig");
const real = @import("real.zig");
const sim = @import("sim.zig");

pub const Disk = model.Disk;
pub const DiskControl = control.DiskControl;
pub const DiskCrash = model.DiskCrash;
pub const DiskDelete = model.DiskDelete;
pub const DiskCreateDir = model.DiskCreateDir;
pub const DiskDirEntry = model.DiskDirEntry;
pub const DiskDirEntryKind = model.DiskDirEntryKind;
pub const DiskDirList = model.DiskDirList;
pub const DiskError = model.DiskError;
pub const DiskFaultOptions = model.DiskFaultOptions;
pub const DiskLatencyRuntime = model.DiskLatencyRuntime;
pub const DiskOptions = model.DiskOptions;
pub const DiskRead = model.DiskRead;
pub const DiskReadSome = model.DiskReadSome;
pub const DiskReadDir = model.DiskReadDir;
pub const DiskRename = model.DiskRename;
pub const DiskRestart = model.DiskRestart;
pub const DiskSetLength = model.DiskSetLength;
pub const DiskSemanticContract = model.DiskSemanticContract;
pub const DiskStat = model.DiskStat;
pub const DiskStatResult = model.DiskStatResult;
pub const DiskStatDir = model.DiskStatDir;
pub const DiskStatDirResult = model.DiskStatDirResult;
pub const DiskSync = model.DiskSync;
pub const DiskSyncDir = model.DiskSyncDir;
pub const DiskWrite = model.DiskWrite;
pub const LogicalPathKind = model.LogicalPathKind;
pub const disk_semantic_contract = model.disk_semantic_contract;
pub const disk_semantic_version = model.disk_semantic_version;
pub const RealDisk = real.RealDisk;
pub const SimDisk = sim.SimDisk;
pub const validateLogicalPath = model.validateLogicalPath;

test {
    _ = sim;
    _ = real;
    _ = @import("tests.zig");
}
