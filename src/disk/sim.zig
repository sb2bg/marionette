//! Deterministic in-memory disk implementation and its behavioral tests.

const std = @import("std");

const clock_module = @import("../clock.zig");
const env_module = @import("../env.zig");
const model = @import("model.zig");
const World = @import("../world.zig").World;
const traceField = @import("../world.zig").traceField;

const Disk = model.Disk;
const DiskControl = @import("control.zig").DiskControl;
const DiskCrash = model.DiskCrash;
const DiskError = model.DiskError;
const DiskFaultOptions = model.DiskFaultOptions;
const DiskLatencyRuntime = model.DiskLatencyRuntime;
const DiskOptions = model.DiskOptions;
const DiskRead = model.DiskRead;
const DiskRestart = model.DiskRestart;
const DiskSync = model.DiskSync;
const DiskSyncDir = model.DiskSyncDir;
const DiskWrite = model.DiskWrite;
const validateByteRange = model.validateByteRange;
const validateLogicalPath = model.validateLogicalPath;

/// Deterministic simulated disk: an in-memory sector store with seeded
/// latency, probabilistic faults, and crash/recovery semantics over pending
/// writes and metadata. Built by `World.simulate`; harnesses drive it
/// through `sim.control.disk`.
pub const SimDisk = struct {
    const Self = @This();
    const ResolvedOptions = struct {
        sector_size: u64,
        min_latency_ns: clock_module.Duration,
        latency_jitter_ns: clock_module.Duration,
    };

    pub const Read = DiskRead;
    pub const Write = DiskWrite;
    pub const Sync = DiskSync;
    pub const SyncDir = DiskSyncDir;
    pub const Crash = DiskCrash;
    pub const Restart = DiskRestart;

    const FileId = u64;
    const DirId = u64;

    const File = struct {
        id: FileId,
        inode: u64,
        path: []u8,
        len: u64 = 0,
        metadata_durable: bool = true,
        sectors: std.ArrayList(Sector) = .empty,

        fn deinit(self: *File, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            for (self.sectors.items) |*sector| sector.deinit(allocator);
            self.sectors.deinit(allocator);
            self.* = undefined;
        }
    };

    const Sector = struct {
        index: u64,
        bytes: []u8,
        corrupt: bool = false,

        fn deinit(self: *Sector, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    const Directory = struct {
        id: DirId,
        path: []u8,
        mtime_ns: u64,
        metadata_durable: bool = true,

        fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.* = undefined;
        }
    };

    const PendingWrite = struct {
        op_id: u64,
        inode: u64,
        path: []u8,
        offset: u64,
        bytes: []u8,
        logical_len: ?u64,

        fn deinit(self: *PendingWrite, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };

    const PendingMetadata = struct {
        op_id: u64,
        dir: []u8,
        other_dir: ?[]u8 = null,
        dir_synced: bool = false,
        other_dir_synced: bool = false,
        kind: Kind,

        const Kind = union(enum) {
            create: FileId,
            create_dir: DirId,
            delete: ?File,
            rename: RenameUndo,
        };

        const RenameUndo = struct {
            file_id: FileId,
            old_path: ?[]u8,
            replaced: ?File = null,

            fn deinit(self: *RenameUndo, allocator: std.mem.Allocator) void {
                if (self.old_path) |path| allocator.free(path);
                if (self.replaced) |*file| file.deinit(allocator);
                self.* = undefined;
            }
        };

        fn deinit(self: *PendingMetadata, allocator: std.mem.Allocator) void {
            allocator.free(self.dir);
            if (self.other_dir) |dir| allocator.free(dir);
            switch (self.kind) {
                .create, .create_dir => {},
                .delete => |*file| if (file.*) |*owned| owned.deinit(allocator),
                .rename => |*undo| undo.deinit(allocator),
            }
            self.* = undefined;
        }
    };

    /// Two-phase hook coordinated with a crash landing. A disk crash models
    /// a machine crash, which also kills the process; layers caching
    /// disk-derived state (such as the `std.Io` file backend) register here.
    /// `prepare` publishes any fallible observer trace before the disk
    /// transition; `commit` then invalidates caches and open handles without
    /// failure.
    pub const CrashObserver = struct {
        ptr: *anyopaque,
        prepare: *const fn (*anyopaque) DiskError!void,
        commit: *const fn (*anyopaque) void,
    };

    world: *World,
    options: ResolvedOptions,
    faults: DiskFaultOptions = .{},
    files: std.ArrayList(File) = .empty,
    directories: std.ArrayList(Directory) = .empty,
    pending_writes: std.ArrayList(PendingWrite) = .empty,
    pending_metadata: std.ArrayList(PendingMetadata) = .empty,
    next_op_id: u64 = 0,
    next_file_id: FileId = 1,
    next_file_inode: u64 = 2,
    next_dir_id: DirId = 1,
    crashed: bool = false,
    /// Remaining data/metadata operations before an armed structural crash
    /// fires. Armed by `control.disk.crashAfterOps`; the crash triggers at
    /// the operation boundary, before the first operation past the budget
    /// does any work. Any crash disarms it.
    armed_crash_budget: ?u64 = null,
    crash_observer: ?CrashObserver = null,
    latency_runtime: ?DiskLatencyRuntime = null,

    /// Construct an empty simulated disk over the world's clock, random
    /// stream, and trace. Latency values must be tick-aligned.
    pub fn init(world: *World, options: DiskOptions) DiskError!Self {
        const resolved_options = try resolveOptions(world, options);
        try world.recordFields("disk.model", &.{
            traceField("contract", .{ .literal = @tagName(model.disk_semantic_contract) }),
            traceField("version", .{ .uint = model.disk_semantic_version }),
            traceField("sector_size", .{ .uint = resolved_options.sector_size }),
            traceField("torn_write", .{ .literal = "sector_prefix" }),
            traceField("reorder", .{ .literal = "crash_global_reverse" }),
            traceField("lifecycle", .{ .literal = "commit_pending" }),
        });
        return .{
            .world = world,
            .options = resolved_options,
        };
    }

    /// Return the app-facing disk handle.
    pub fn disk(self: *Self) Disk {
        return .{ .ptr = self, .vtable = &disk_vtable };
    }

    /// Return the harness-facing fault and crash control handle.
    pub fn control(self: *Self) DiskControl {
        return .{ .ptr = self, .vtable = &control_vtable };
    }

    /// The configured sector size in bytes.
    pub fn sectorSize(self: *const Self) u64 {
        return self.options.sector_size;
    }

    /// Register the single observer notified after each crash lands.
    pub fn setCrashObserver(self: *Self, observer: CrashObserver) void {
        self.crash_observer = observer;
    }

    /// Attach the simulation scheduler used to park task-side disk calls.
    /// Bare callers keep the synchronous `World.runFor` behavior.
    pub fn attachLatencyRuntime(self: *Self, runtime: DiskLatencyRuntime) void {
        self.latency_runtime = runtime;
    }

    /// Free all in-memory files, directories, and pending operations.
    pub fn deinit(self: *Self) void {
        for (self.files.items) |*file| file.deinit(self.world.allocator);
        self.files.deinit(self.world.allocator);
        for (self.directories.items) |*directory| directory.deinit(self.world.allocator);
        self.directories.deinit(self.world.allocator);
        for (self.pending_writes.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_writes.deinit(self.world.allocator);
        for (self.pending_metadata.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_metadata.deinit(self.world.allocator);
        self.* = undefined;
    }

    fn setFaults(self: *Self, faults: DiskFaultOptions) DiskError!void {
        try faults.read_error_rate.validate();
        try faults.write_error_rate.validate();
        try faults.corrupt_read_rate.validate();
        try faults.crash_lost_write_rate.validate();
        try faults.crash_torn_write_rate.validate();
        try faults.crash_reordered_write_rate.validate();
        try faults.crash_lost_metadata_rate.validate();
        self.faults = faults;
    }

    fn corruptSector(self: *Self, path: []const u8, offset: u64) DiskError!void {
        try self.validatePath(path);
        try self.validateRange(offset, @intCast(self.options.sector_size));

        if (self.visibleLength(path) == null) return error.FileNotFound;
        const file = try self.getOrCreateFile(path, null);
        const sector = try self.getOrCreateSector(file, offset / self.options.sector_size);
        sector.corrupt = true;

        try self.world.recordFields("disk.fault", &.{
            traceField("path", .{ .text = path }),
            traceField("offset", .{ .uint = offset }),
            traceField("kind", .{ .literal = "scripted_corruption" }),
        });
    }

    fn read(self: *Self, options: Read) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.buffer.len);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();

        if (try self.rollFault(op_id, options.path, "read_error", self.faults.read_error_rate)) {
            try self.recordRangeOp(
                "disk.read",
                op_id,
                options.path,
                options.offset,
                options.buffer.len,
                "io_error",
                latency_ns,
            );
            return error.ReadError;
        }

        @memset(options.buffer, 0);

        if (self.findFile(options.path)) |file| {
            try self.readSectors(file, options.offset, options.buffer);
        }
        self.overlayPendingWrites(options.path, options.offset, options.buffer);

        const corrupt = self.rangeHasCorruption(options.path, options.offset, options.buffer.len) or
            try self.rollFault(op_id, options.path, "corrupt_read", self.faults.corrupt_read_rate);
        const status = if (corrupt) "corrupt" else "ok";
        if (corrupt and options.buffer.len > 0) {
            options.buffer[0] ^= 0xff;
        }

        try self.recordRangeOp(
            "disk.read",
            op_id,
            options.path,
            options.offset,
            options.buffer.len,
            status,
            latency_ns,
        );
    }

    fn write(self: *Self, options: Write) DiskError!void {
        try self.validatePath(options.path);
        try self.validateRange(options.offset, options.bytes.len);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        if (try self.rollFault(op_id, options.path, "write_error", self.faults.write_error_rate)) {
            try self.recordRangeOp(
                "disk.write",
                op_id,
                options.path,
                options.offset,
                options.bytes.len,
                "io_error",
                latency_ns,
            );
            return error.WriteError;
        }

        try self.appendPendingWrite(
            op_id,
            options.path,
            options.offset,
            options.bytes,
            options.logical_len,
        );

        try self.recordRangeOp(
            "disk.write",
            op_id,
            options.path,
            options.offset,
            options.bytes.len,
            "ok",
            latency_ns,
        );
    }

    fn sync(self: *Self, options: Sync) DiskError!void {
        try self.validatePath(options.path);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.path);

        try self.world.recordFields("disk.sync", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("committed_writes", .{ .uint = committed }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn syncDir(self: *Self, options: SyncDir) DiskError!void {
        try validateLogicalPath(options.path, .directory);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = self.commitPendingMetadata(options.path);

        try self.world.recordFields("disk.sync_dir", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("committed_metadata", .{ .uint = committed }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn stat(self: *Self, options: Disk.Stat) DiskError!Disk.StatResult {
        try self.validatePath(options.path);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const size = self.visibleLength(options.path) orelse {
            try self.recordPathOp("disk.stat", op_id, options.path, "not_found", latency_ns);
            return error.FileNotFound;
        };
        const inode = self.visibleInode(options.path) orelse unreachable;

        try self.world.recordFields("disk.stat", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("status", .{ .literal = "ok" }),
            traceField("size", .{ .uint = size }),
            traceField("latency_ns", .{ .uint = latency_ns }),
            traceField("inode", .{ .uint = inode }),
        });
        return .{ .inode = inode, .size = size };
    }

    fn createDir(self: *Self, options: Disk.CreateDir) DiskError!void {
        try validateLogicalPath(options.path, .directory);
        if (std.mem.eql(u8, options.path, ".")) return error.PathAlreadyExists;
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        if (self.findDirectory(options.path) != null or self.visibleLength(options.path) != null) {
            try self.recordPathOp("disk.create_dir", op_id, options.path, "exists", latency_ns);
            return error.PathAlreadyExists;
        }
        const parent = std.fs.path.dirname(options.path) orelse ".";
        if (!std.mem.eql(u8, parent, ".") and self.findDirectory(parent) == null) {
            try self.recordPathOp("disk.create_dir", op_id, options.path, "parent_not_found", latency_ns);
            return error.FileNotFound;
        }

        const owned_path = try self.world.allocator.dupe(u8, options.path);
        errdefer self.world.allocator.free(owned_path);
        const owned_parent = try self.world.allocator.dupe(u8, parent);
        errdefer self.world.allocator.free(owned_parent);
        try self.directories.ensureUnusedCapacity(self.world.allocator, 1);
        try self.pending_metadata.ensureUnusedCapacity(self.world.allocator, 1);

        const id = self.next_dir_id;
        self.next_dir_id += 1;
        self.directories.appendAssumeCapacity(.{
            .id = id,
            .path = owned_path,
            .mtime_ns = self.world.now(),
            .metadata_durable = false,
        });
        self.pending_metadata.appendAssumeCapacity(.{
            .op_id = op_id,
            .dir = owned_parent,
            .kind = .{ .create_dir = id },
        });
        try self.recordPathOp("disk.create_dir", op_id, options.path, "ok", latency_ns);
    }

    fn statDir(self: *Self, options: Disk.StatDir) DiskError!Disk.StatDirResult {
        try validateLogicalPath(options.path, .directory);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        if (std.mem.eql(u8, options.path, ".")) {
            try self.recordPathOp("disk.stat_dir", op_id, options.path, "ok", latency_ns);
            return .{ .inode = 1, .mtime_ns = 0 };
        }
        const directory = self.findDirectory(options.path) orelse {
            try self.recordPathOp("disk.stat_dir", op_id, options.path, "not_found", latency_ns);
            return error.FileNotFound;
        };
        try self.recordPathOp("disk.stat_dir", op_id, options.path, "ok", latency_ns);
        return .{
            .inode = directoryInode(directory.id),
            .mtime_ns = directory.mtime_ns,
        };
    }

    fn readDir(self: *Self, options: Disk.ReadDir) DiskError!Disk.DirList {
        try validateLogicalPath(options.path, .directory);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        if (!std.mem.eql(u8, options.path, ".") and self.findDirectory(options.path) == null) {
            try self.recordPathOp("disk.read_dir", op_id, options.path, "not_found", latency_ns);
            return error.FileNotFound;
        }

        var entries: std.ArrayList(Disk.DirEntry) = .empty;
        errdefer {
            for (entries.items) |entry| options.allocator.free(entry.name);
            entries.deinit(options.allocator);
        }
        for (self.directories.items) |directory| {
            const name = directChildName(options.path, directory.path) orelse continue;
            try entries.append(options.allocator, .{
                .name = try options.allocator.dupe(u8, name),
                .kind = .directory,
                .inode = directoryInode(directory.id),
            });
        }
        for (self.files.items) |file| {
            const name = directChildName(options.path, file.path) orelse continue;
            try entries.append(options.allocator, .{
                .name = try options.allocator.dupe(u8, name),
                .kind = .file,
                .inode = file.inode,
            });
        }
        for (self.pending_writes.items) |pending| {
            if (self.findFile(pending.path) != null) continue;
            const name = directChildName(options.path, pending.path) orelse continue;
            var already_listed = false;
            for (entries.items) |entry| {
                if (entry.kind == .file and std.mem.eql(u8, entry.name, name)) {
                    already_listed = true;
                    break;
                }
            }
            if (already_listed) continue;
            try entries.append(options.allocator, .{
                .name = try options.allocator.dupe(u8, name),
                .kind = .file,
                .inode = pending.inode,
            });
        }
        try self.recordPathOp("disk.read_dir", op_id, options.path, "ok", latency_ns);
        return .{
            .allocator = options.allocator,
            .entries = try entries.toOwnedSlice(options.allocator),
        };
    }

    fn readSome(self: *Self, options: Disk.ReadSome) DiskError!usize {
        try self.validatePath(options.path);
        try validateByteRange(options.offset, options.buffer.len);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const size = self.visibleLength(options.path) orelse {
            try self.recordRangeOp(
                "disk.read_some",
                op_id,
                options.path,
                options.offset,
                options.buffer.len,
                "not_found",
                latency_ns,
            );
            return error.FileNotFound;
        };

        if (try self.rollFault(op_id, options.path, "read_error", self.faults.read_error_rate)) {
            try self.recordRangeOp(
                "disk.read_some",
                op_id,
                options.path,
                options.offset,
                options.buffer.len,
                "io_error",
                latency_ns,
            );
            return error.ReadError;
        }

        const read_len: usize = if (options.offset >= size)
            0
        else
            @intCast(@min(@as(u64, @intCast(options.buffer.len)), size - options.offset));

        if (read_len > 0) {
            @memset(options.buffer[0..read_len], 0);
            if (self.findFile(options.path)) |file| {
                try self.readBytes(file, options.offset, options.buffer[0..read_len]);
            }
            self.overlayPendingWrites(options.path, options.offset, options.buffer[0..read_len]);
        }

        const corrupt = read_len > 0 and
            (self.rangeHasCorruptionBytes(options.path, options.offset, read_len) or
                try self.rollFault(op_id, options.path, "corrupt_read", self.faults.corrupt_read_rate));
        const status = if (corrupt) "corrupt" else "ok";
        if (corrupt) {
            options.buffer[0] ^= 0xff;
        }

        try self.world.recordFields("disk.read_some", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = options.path }),
            traceField("offset", .{ .uint = options.offset }),
            traceField("requested_len", .{ .uint = @intCast(options.buffer.len) }),
            traceField("read_len", .{ .uint = @intCast(read_len) }),
            traceField("status", .{ .literal = status }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
        return read_len;
    }

    fn setLength(self: *Self, options: Disk.SetLength) DiskError!void {
        try self.validatePath(options.path);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        if (self.visibleLength(options.path) == null) {
            try self.recordMetadataOp("disk.set_length", op_id, options.path, options.len, 0, "not_found", latency_ns);
            return error.FileNotFound;
        }

        // Commit pending writes, zero/truncate storage, and publish the trace
        // before replacing live media. A failed setLength therefore cannot
        // leave disk-visible length or bytes ahead of the std.Io metadata
        // cache that still reports the old length.
        var staged = try self.cloneMediaState();
        defer staged.deinit();
        var committed: u64 = 0;
        for (self.pending_writes.items) |*pending| {
            if (!std.mem.eql(u8, pending.path, options.path)) continue;
            try staged.applyFullWrite(pending);
            committed += 1;
        }
        const file = staged.findFile(options.path).?;

        try staged.truncateFile(file, options.len);
        file.len = options.len;
        try self.recordMetadataOp("disk.set_length", op_id, options.path, options.len, committed, "ok", latency_ns);

        std.mem.swap(std.ArrayList(File), &self.files, &staged.files);
        std.mem.swap(std.ArrayList(Directory), &self.directories, &staged.directories);
        std.mem.swap(std.ArrayList(PendingMetadata), &self.pending_metadata, &staged.pending_metadata);
        self.next_file_id = staged.next_file_id;
        self.next_file_inode = staged.next_file_inode;
        self.next_dir_id = staged.next_dir_id;
        self.clearPendingWritesFor(options.path);
    }

    fn delete(self: *Self, options: Disk.Delete) DiskError!void {
        try self.validatePath(options.path);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.path);
        const index = self.findFileIndex(options.path) orelse {
            try self.recordLifecycleOp("disk.delete", op_id, options.path, null, committed, "not_found", latency_ns);
            return error.FileNotFound;
        };

        const dir = try self.ownedParentDir(options.path);
        var dir_owned = true;
        errdefer if (dir_owned) self.world.allocator.free(dir);
        try self.pending_metadata.ensureUnusedCapacity(self.world.allocator, 1);

        const deleted = self.files.orderedRemove(index);
        self.pending_metadata.appendAssumeCapacity(.{
            .op_id = op_id,
            .dir = dir,
            .kind = .{ .delete = deleted },
        });
        dir_owned = false;
        self.clearPendingWritesFor(options.path);
        try self.recordLifecycleOp("disk.delete", op_id, options.path, null, committed, "ok", latency_ns);
    }

    fn rename(self: *Self, options: Disk.Rename) DiskError!void {
        try self.validatePath(options.old_path);
        try self.validatePath(options.new_path);
        try self.beginOp();

        const op_id = self.consumeOpId();
        const latency_ns = try self.advanceLatency();
        const committed = try self.commitPendingWrites(options.old_path);
        const old_index = self.findFileIndex(options.old_path) orelse {
            try self.recordLifecycleOp("disk.rename", op_id, options.old_path, options.new_path, committed, "not_found", latency_ns);
            return error.FileNotFound;
        };
        if (std.mem.eql(u8, options.old_path, options.new_path)) {
            try self.recordLifecycleOp("disk.rename", op_id, options.old_path, options.new_path, committed, "ok", latency_ns);
            return;
        }

        const owned_old_path = try self.world.allocator.dupe(u8, options.old_path);
        var old_path_owned = true;
        errdefer if (old_path_owned) self.world.allocator.free(owned_old_path);
        const owned_new_path = try self.world.allocator.dupe(u8, options.new_path);
        var new_path_owned = true;
        errdefer if (new_path_owned) self.world.allocator.free(owned_new_path);
        const old_dir = try self.ownedParentDir(options.old_path);
        var old_dir_owned = true;
        errdefer if (old_dir_owned) self.world.allocator.free(old_dir);
        const new_dir = try self.ownedParentDir(options.new_path);
        var new_dir_owned = true;
        errdefer if (new_dir_owned) self.world.allocator.free(new_dir);
        try self.pending_metadata.ensureUnusedCapacity(self.world.allocator, 1);

        self.clearPendingWritesFor(options.new_path);

        var file_id: FileId = self.files.items[old_index].id;
        var replaced: ?File = null;
        if (self.findFileIndex(options.new_path)) |new_index| {
            if (new_index != old_index) {
                var old_index_adjusted = old_index;
                replaced = self.files.orderedRemove(new_index);
                if (new_index < old_index_adjusted) old_index_adjusted -= 1;
                file_id = self.files.items[old_index_adjusted].id;
                self.world.allocator.free(self.files.items[old_index_adjusted].path);
                self.files.items[old_index_adjusted].path = owned_new_path;
                new_path_owned = false;
            }
        } else {
            self.world.allocator.free(self.files.items[old_index].path);
            self.files.items[old_index].path = owned_new_path;
            new_path_owned = false;
        }

        self.pending_metadata.appendAssumeCapacity(.{
            .op_id = op_id,
            .dir = old_dir,
            .other_dir = if (std.mem.eql(u8, old_dir, new_dir)) null else new_dir,
            .kind = .{ .rename = .{
                .file_id = file_id,
                .old_path = owned_old_path,
                .replaced = replaced,
            } },
        });
        old_path_owned = false;
        old_dir_owned = false;
        if (std.mem.eql(u8, old_dir, new_dir)) {
            self.world.allocator.free(new_dir);
        }
        new_dir_owned = false;

        try self.recordLifecycleOp("disk.rename", op_id, options.old_path, options.new_path, committed, "ok", latency_ns);
    }

    fn crash(self: *Self, _: Crash) DiskError!void {
        // A control action, not a data operation: it must neither consume
        // armed-crash budget nor recursively trigger itself.
        try self.ensureRunning();

        // Crash is one externally visible transaction. Build the recovered
        // durable state off to the side while recording every seeded choice
        // and classification under one world checkpoint. Only after the
        // final summary and observer trace succeed do we swap the staged
        // state in and notify process-local owners.
        const checkpoint = self.world.transactionCheckpoint();
        errdefer self.world.rollbackTransaction(checkpoint);
        var staged = try self.cloneMediaState();
        defer staged.deinit();

        const pending_count = self.pending_writes.items.len;
        var landed: u64 = 0;
        var lost: u64 = 0;
        var torn: u64 = 0;
        var reordered: u64 = 0;
        const CrashLanding = struct { index: usize };
        var landing = std.ArrayList(CrashLanding).empty;
        defer landing.deinit(self.world.allocator);
        var reorder_requested = false;

        for (self.pending_writes.items, 0..) |*pending, index| {
            if (try self.rollFault(
                pending.op_id,
                pending.path,
                "crash_lost_write",
                self.faults.crash_lost_write_rate,
            )) {
                lost += 1;
                try self.recordCrashWrite(pending, "lost");
                continue;
            }

            if (try self.rollFault(
                pending.op_id,
                pending.path,
                "crash_torn_write",
                self.faults.crash_torn_write_rate,
            )) {
                try staged.applyTornWrite(pending);
                torn += 1;
                try self.recordCrashWrite(pending, "torn");
                continue;
            }

            if (try self.rollFault(
                pending.op_id,
                pending.path,
                "crash_reordered_write",
                self.faults.crash_reordered_write_rate,
            )) {
                reorder_requested = true;
            }

            try landing.append(self.world.allocator, .{ .index = index });
        }

        const apply_reordered = reorder_requested and landing.items.len > 1;
        if (apply_reordered) {
            reordered = @intCast(landing.items.len);
            var index = landing.items.len;
            while (index > 0) {
                index -= 1;
                const item = landing.items[index];
                const pending = &self.pending_writes.items[item.index];
                try staged.applyFullWrite(pending);
                try self.recordCrashWrite(pending, "reordered");
            }
        } else {
            landed = @intCast(landing.items.len);
            for (landing.items) |item| {
                const pending = &self.pending_writes.items[item.index];
                try staged.applyFullWrite(pending);
                try self.recordCrashWrite(pending, "landed");
            }
        }
        const pending_metadata_count = staged.pending_metadata.items.len;
        var metadata_kept: u64 = 0;
        var metadata_lost: u64 = 0;
        var index = staged.pending_metadata.items.len;
        while (index > 0) {
            index -= 1;
            const pending = &staged.pending_metadata.items[index];
            if (try self.rollFault(
                pending.op_id,
                pending.dir,
                "crash_lost_metadata",
                self.faults.crash_lost_metadata_rate,
            )) {
                try staged.rollbackPendingMetadata(pending);
                metadata_lost += 1;
                try self.recordCrashMetadata(pending, "lost");
            } else {
                staged.markMetadataDurable(pending);
                metadata_kept += 1;
                try self.recordCrashMetadata(pending, "kept");
            }
        }
        staged.clearPendingMetadata();

        try self.world.recordFields("disk.crash", &.{
            traceField("pending_writes", .{ .uint = @intCast(pending_count) }),
            traceField("landed", .{ .uint = landed }),
            traceField("lost", .{ .uint = lost }),
            traceField("torn", .{ .uint = torn }),
            traceField("reordered", .{ .uint = reordered }),
            traceField("pending_metadata", .{ .uint = @intCast(pending_metadata_count) }),
            traceField("metadata_kept", .{ .uint = metadata_kept }),
            traceField("metadata_lost", .{ .uint = metadata_lost }),
        });

        if (self.crash_observer) |observer| try observer.prepare(observer.ptr);

        std.mem.swap(std.ArrayList(File), &self.files, &staged.files);
        std.mem.swap(std.ArrayList(Directory), &self.directories, &staged.directories);
        self.next_file_id = staged.next_file_id;
        self.next_file_inode = staged.next_file_inode;
        self.next_dir_id = staged.next_dir_id;
        self.clearPendingWrites();
        self.clearPendingMetadata();
        self.armed_crash_budget = null;
        self.crashed = true;

        if (self.crash_observer) |observer| observer.commit(observer.ptr);
    }

    fn restart(self: *Self, _: Restart) DiskError!void {
        self.crashed = false;
        try self.world.recordFields("disk.restart", &.{
            traceField("status", .{ .literal = "ok" }),
        });
    }

    fn resolveOptions(world: *World, options: DiskOptions) DiskError!ResolvedOptions {
        if (options.sector_size == 0) return error.InvalidAlignment;
        if (options.sector_size > std.math.maxInt(usize)) return error.InvalidRange;
        const min_latency_ns = options.min_latency_ns orelse world.clock().tick_ns;
        const tick_ns = world.clock().tick_ns;
        if (min_latency_ns % tick_ns != 0) return error.InvalidDuration;
        if (options.latency_jitter_ns % tick_ns != 0) return error.InvalidDuration;
        return .{
            .sector_size = options.sector_size,
            .min_latency_ns = min_latency_ns,
            .latency_jitter_ns = options.latency_jitter_ns,
        };
    }

    fn validatePath(_: *const Self, path: []const u8) DiskError!void {
        try validateLogicalPath(path, .file);
    }

    fn ensureRunning(self: *const Self) DiskError!void {
        if (self.crashed) return error.DiskCrashed;
    }

    /// Entry gate for every data and metadata operation. An armed
    /// operation-count crash fires here, at the boundary between
    /// operations: the operation that finds the budget exhausted crashes
    /// the disk before doing any work and fails like any post-crash
    /// operation.
    fn beginOp(self: *Self) DiskError!void {
        try self.ensureRunning();
        if (self.armed_crash_budget) |budget| {
            if (budget == 0) {
                try self.crash(.{});
                return error.DiskCrashed;
            }
            self.armed_crash_budget = budget - 1;
        }
    }

    fn crashAfterOps(self: *Self, ops: u64) DiskError!void {
        try self.ensureRunning();
        self.armed_crash_budget = ops;
        try self.world.recordFields("disk.fault", &.{
            traceField("kind", .{ .literal = "armed_crash" }),
            traceField("after_ops", .{ .uint = ops }),
        });
    }

    fn validateRange(self: *const Self, offset: u64, len: usize) DiskError!void {
        const len_u64: u64 = @intCast(len);
        if (offset % self.options.sector_size != 0) return error.InvalidAlignment;
        if (len_u64 % self.options.sector_size != 0) return error.InvalidAlignment;
        if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
    }

    fn ownedParentDir(self: *Self, path: []const u8) DiskError![]u8 {
        const parent = std.fs.path.dirname(path) orelse ".";
        return try self.world.allocator.dupe(u8, parent);
    }

    fn consumeOpId(self: *Self) u64 {
        const op_id = self.next_op_id;
        self.next_op_id += 1;
        return op_id;
    }

    fn advanceLatency(self: *Self) DiskError!clock_module.Duration {
        const latency_ns = try self.latency();
        if (latency_ns == 0) return latency_ns;
        if (std.math.maxInt(clock_module.Timestamp) - self.world.now() < latency_ns) {
            return error.InvalidDuration;
        }
        const deadline_ns = self.world.now() + latency_ns;
        if (self.latency_runtime) |runtime| {
            if (runtime.inTask()) {
                runtime.waitUntil(deadline_ns);
                std.debug.assert(self.world.now() >= deadline_ns);
                return latency_ns;
            }
        }
        try self.world.runFor(latency_ns);
        return latency_ns;
    }

    fn latency(self: *Self) DiskError!clock_module.Duration {
        const jitter_ns = self.options.latency_jitter_ns;
        if (jitter_ns == 0) return self.options.min_latency_ns;

        const tick_ns = self.world.clock().tick_ns;
        const jitter_ticks = try self.world.randomIntLessThan(
            clock_module.Duration,
            jitter_ns / tick_ns + 1,
        );
        return self.options.min_latency_ns + jitter_ticks * tick_ns;
    }

    fn rollFault(
        self: *Self,
        op_id: u64,
        path: []const u8,
        kind: []const u8,
        rate: env_module.BuggifyRate,
    ) DiskError!bool {
        try rate.validate();
        if (rate.numerator == 0) return false;

        const roll = try self.world.randomIntLessThan(u32, rate.denominator);
        const fired = roll < rate.numerator;

        var rate_buffer: [32]u8 = undefined;
        const rate_literal = std.fmt.bufPrint(
            &rate_buffer,
            "{}/{}",
            .{ rate.numerator, rate.denominator },
        ) catch unreachable;

        try self.world.recordFields("disk.fault", &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("kind", .{ .literal = kind }),
            traceField("rate", .{ .literal = rate_literal }),
            traceField("roll", .{ .uint = roll }),
            traceField("fired", .{ .literal = if (fired) "true" else "false" }),
        });

        return fired;
    }

    fn findFile(self: *Self, path: []const u8) ?*File {
        for (self.files.items) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }

    fn findDirectory(self: *Self, path: []const u8) ?*Directory {
        for (self.directories.items) |*directory| {
            if (std.mem.eql(u8, directory.path, path)) return directory;
        }
        return null;
    }

    fn findDirectoryIndexById(self: *Self, id: DirId) ?usize {
        for (self.directories.items, 0..) |directory, index| {
            if (directory.id == id) return index;
        }
        return null;
    }

    fn findFileIndex(self: *Self, path: []const u8) ?usize {
        for (self.files.items, 0..) |*file, index| {
            if (std.mem.eql(u8, file.path, path)) return index;
        }
        return null;
    }

    fn findFileById(self: *Self, id: FileId) ?*File {
        for (self.files.items) |*file| {
            if (file.id == id) return file;
        }
        return null;
    }

    fn findFileIndexById(self: *Self, id: FileId) ?usize {
        for (self.files.items, 0..) |*file, index| {
            if (file.id == id) return index;
        }
        return null;
    }

    fn getOrCreateFile(self: *Self, path: []const u8, inode: ?u64) DiskError!*File {
        if (self.findFile(path)) |file| return file;

        const owned_path = try self.world.allocator.dupe(u8, path);
        errdefer self.world.allocator.free(owned_path);

        const id = self.next_file_id;
        self.next_file_id += 1;
        try self.files.append(self.world.allocator, .{
            .id = id,
            .inode = inode orelse self.allocateFileInode(),
            .path = owned_path,
            .metadata_durable = false,
        });
        return &self.files.items[self.files.items.len - 1];
    }

    fn allocateFileInode(self: *Self) u64 {
        const inode = self.next_file_inode;
        self.next_file_inode += 1;
        return inode;
    }

    fn ensurePendingCreate(self: *Self, op_id: u64, file: *const File) DiskError!void {
        if (file.metadata_durable) return;
        for (self.pending_metadata.items) |pending| switch (pending.kind) {
            .create => |id| if (id == file.id) return,
            .create_dir, .delete, .rename => {},
        };

        const dir = try self.ownedParentDir(file.path);
        errdefer self.world.allocator.free(dir);
        try self.pending_metadata.append(self.world.allocator, .{
            .op_id = op_id,
            .dir = dir,
            .kind = .{ .create = file.id },
        });
    }

    fn appendPendingWrite(
        self: *Self,
        op_id: u64,
        path: []const u8,
        offset: u64,
        bytes: []const u8,
        logical_len: ?u64,
    ) DiskError!void {
        const existing_inode = self.visibleInode(path);
        const inode = existing_inode orelse self.next_file_inode;
        const owned_path = try self.world.allocator.dupe(u8, path);
        errdefer self.world.allocator.free(owned_path);

        const owned_bytes = try self.world.allocator.dupe(u8, bytes);
        errdefer self.world.allocator.free(owned_bytes);

        try self.pending_writes.append(self.world.allocator, .{
            .op_id = op_id,
            .inode = inode,
            .path = owned_path,
            .offset = offset,
            .bytes = owned_bytes,
            .logical_len = logical_len,
        });
        if (existing_inode == null) self.next_file_inode += 1;
    }

    fn clearPendingWritesFor(self: *Self, path: []const u8) void {
        var index: usize = 0;
        while (index < self.pending_writes.items.len) {
            if (!std.mem.eql(u8, self.pending_writes.items[index].path, path)) {
                index += 1;
                continue;
            }
            var pending = self.pending_writes.orderedRemove(index);
            pending.deinit(self.world.allocator);
        }
    }

    fn commitPendingWrites(self: *Self, path: []const u8) DiskError!u64 {
        var committed: u64 = 0;
        var index: usize = 0;
        while (index < self.pending_writes.items.len) {
            if (!std.mem.eql(u8, self.pending_writes.items[index].path, path)) {
                index += 1;
                continue;
            }

            try self.applyFullWrite(&self.pending_writes.items[index]);
            var pending = self.pending_writes.orderedRemove(index);
            pending.deinit(self.world.allocator);
            committed += 1;
        }

        return committed;
    }

    fn clearPendingWrites(self: *Self) void {
        for (self.pending_writes.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_writes.clearRetainingCapacity();
    }

    fn commitPendingMetadata(self: *Self, dir: []const u8) u64 {
        var committed: u64 = 0;
        var index: usize = 0;
        while (index < self.pending_metadata.items.len) {
            const pending = &self.pending_metadata.items[index];
            if (!markPendingMetadataDirSynced(pending, dir)) {
                index += 1;
                continue;
            }

            if (!pendingMetadataSynced(pending)) {
                index += 1;
                continue;
            }

            self.markMetadataDurable(pending);
            var removed = self.pending_metadata.orderedRemove(index);
            removed.deinit(self.world.allocator);
            committed += 1;
        }
        return committed;
    }

    fn markPendingMetadataDirSynced(pending: *PendingMetadata, dir: []const u8) bool {
        var matched = false;
        if (std.mem.eql(u8, pending.dir, dir)) {
            pending.dir_synced = true;
            matched = true;
        }
        if (pending.other_dir) |other_dir| {
            if (std.mem.eql(u8, other_dir, dir)) {
                pending.other_dir_synced = true;
                matched = true;
            }
        }
        return matched;
    }

    fn pendingMetadataSynced(pending: *const PendingMetadata) bool {
        return pending.dir_synced and (pending.other_dir == null or pending.other_dir_synced);
    }

    fn clearPendingMetadata(self: *Self) void {
        for (self.pending_metadata.items) |*pending| pending.deinit(self.world.allocator);
        self.pending_metadata.clearRetainingCapacity();
    }

    fn markMetadataDurable(self: *Self, pending: *const PendingMetadata) void {
        switch (pending.kind) {
            .create => |id| {
                if (self.findFileById(id)) |file| file.metadata_durable = true;
            },
            .create_dir => |id| {
                if (self.findDirectoryIndexById(id)) |index| {
                    self.directories.items[index].metadata_durable = true;
                }
            },
            .delete => {},
            .rename => |rename_undo| {
                if (self.findFileById(rename_undo.file_id)) |file| file.metadata_durable = true;
            },
        }
    }

    fn rollbackPendingMetadata(self: *Self, pending: *PendingMetadata) DiskError!void {
        switch (pending.kind) {
            .create => |id| {
                if (self.findFileIndexById(id)) |index| {
                    var file = self.files.orderedRemove(index);
                    file.deinit(self.world.allocator);
                }
            },
            .create_dir => |id| {
                if (self.findDirectoryIndexById(id)) |index| {
                    const path = try self.world.allocator.dupe(
                        u8,
                        self.directories.items[index].path,
                    );
                    defer self.world.allocator.free(path);
                    self.removeDirectoryTree(path);
                }
            },
            .delete => |*deleted| {
                if (deleted.*) |file| {
                    try self.files.append(self.world.allocator, file);
                    deleted.* = null;
                }
            },
            .rename => |*rename_undo| {
                if (self.findFileById(rename_undo.file_id)) |file| {
                    if (rename_undo.old_path) |old_path| {
                        self.world.allocator.free(file.path);
                        file.path = old_path;
                        rename_undo.old_path = null;
                    }
                }
                if (rename_undo.replaced) |file| {
                    try self.files.append(self.world.allocator, file);
                    rename_undo.replaced = null;
                }
            },
        }
    }

    fn removeDirectoryTree(self: *Self, path: []const u8) void {
        var file_index: usize = 0;
        while (file_index < self.files.items.len) {
            if (!isDescendantOrSelf(path, self.files.items[file_index].path)) {
                file_index += 1;
                continue;
            }
            var file = self.files.orderedRemove(file_index);
            file.deinit(self.world.allocator);
        }

        var dir_index: usize = 0;
        while (dir_index < self.directories.items.len) {
            if (!isDescendantOrSelf(path, self.directories.items[dir_index].path)) {
                dir_index += 1;
                continue;
            }
            var directory = self.directories.orderedRemove(dir_index);
            directory.deinit(self.world.allocator);
        }
    }

    fn directChildName(base: []const u8, path: []const u8) ?[]const u8 {
        const relative = if (std.mem.eql(u8, base, "."))
            path
        else relative: {
            if (!std.mem.startsWith(u8, path, base)) return null;
            if (path.len <= base.len or path[base.len] != '/') return null;
            break :relative path[base.len + 1 ..];
        };
        if (relative.len == 0 or std.mem.indexOfScalar(u8, relative, '/') != null) return null;
        return relative;
    }

    fn isDescendantOrSelf(parent: []const u8, path: []const u8) bool {
        return std.mem.eql(u8, parent, path) or
            (std.mem.startsWith(u8, path, parent) and path.len > parent.len and path[parent.len] == '/');
    }

    fn cloneMediaState(self: *Self) DiskError!Self {
        var staged: Self = .{
            .world = self.world,
            .options = self.options,
            .faults = self.faults,
            .next_op_id = self.next_op_id,
            .next_file_id = self.next_file_id,
            .next_file_inode = self.next_file_inode,
            .next_dir_id = self.next_dir_id,
        };
        errdefer staged.deinit();

        for (self.files.items) |*file| {
            var cloned = try self.cloneFile(file);
            errdefer cloned.deinit(self.world.allocator);
            try staged.files.append(self.world.allocator, cloned);
        }
        for (self.directories.items) |*directory| {
            const cloned_path = try self.world.allocator.dupe(u8, directory.path);
            errdefer self.world.allocator.free(cloned_path);
            try staged.directories.append(self.world.allocator, .{
                .id = directory.id,
                .path = cloned_path,
                .mtime_ns = directory.mtime_ns,
                .metadata_durable = directory.metadata_durable,
            });
        }
        for (self.pending_metadata.items) |*pending| {
            var cloned = try self.clonePendingMetadata(pending);
            errdefer cloned.deinit(self.world.allocator);
            try staged.pending_metadata.append(self.world.allocator, cloned);
        }
        return staged;
    }

    fn cloneFile(self: *Self, source: *const File) DiskError!File {
        const path = try self.world.allocator.dupe(u8, source.path);
        var cloned: File = .{
            .id = source.id,
            .inode = source.inode,
            .path = path,
            .len = source.len,
            .metadata_durable = source.metadata_durable,
        };
        errdefer cloned.deinit(self.world.allocator);

        for (source.sectors.items) |source_sector| {
            const bytes = try self.world.allocator.dupe(u8, source_sector.bytes);
            errdefer self.world.allocator.free(bytes);
            try cloned.sectors.append(self.world.allocator, .{
                .index = source_sector.index,
                .bytes = bytes,
                .corrupt = source_sector.corrupt,
            });
        }
        return cloned;
    }

    fn clonePendingMetadata(self: *Self, source: *const PendingMetadata) DiskError!PendingMetadata {
        const dir = try self.world.allocator.dupe(u8, source.dir);
        errdefer self.world.allocator.free(dir);
        const other_dir = if (source.other_dir) |path|
            try self.world.allocator.dupe(u8, path)
        else
            null;
        errdefer if (other_dir) |path| self.world.allocator.free(path);

        const kind: PendingMetadata.Kind = switch (source.kind) {
            .create => |id| .{ .create = id },
            .create_dir => |id| .{ .create_dir = id },
            .delete => |deleted| .{ .delete = if (deleted) |*file|
                try self.cloneFile(file)
            else
                null },
            .rename => |*rename_undo| .{ .rename = try self.cloneRenameUndo(rename_undo) },
        };
        return .{
            .op_id = source.op_id,
            .dir = dir,
            .other_dir = other_dir,
            .dir_synced = source.dir_synced,
            .other_dir_synced = source.other_dir_synced,
            .kind = kind,
        };
    }

    fn cloneRenameUndo(self: *Self, source: *const PendingMetadata.RenameUndo) DiskError!PendingMetadata.RenameUndo {
        const old_path = if (source.old_path) |path|
            try self.world.allocator.dupe(u8, path)
        else
            null;
        errdefer if (old_path) |path| self.world.allocator.free(path);
        const replaced = if (source.replaced) |*file|
            try self.cloneFile(file)
        else
            null;
        return .{
            .file_id = source.file_id,
            .old_path = old_path,
            .replaced = replaced,
        };
    }

    fn directoryInode(id: DirId) u64 {
        return std.math.maxInt(u64) - id;
    }

    fn applyFullWrite(self: *Self, pending: *const PendingWrite) DiskError!void {
        const file = try self.getOrCreateFile(pending.path, pending.inode);
        try self.ensurePendingCreate(pending.op_id, file);
        try self.writeBytes(file, pending.offset, pending.bytes);
        const physical_end = try endOffset(pending.offset, pending.bytes.len);
        file.len = @max(file.len, pending.logical_len orelse physical_end);
    }

    fn applyTornWrite(self: *Self, pending: *const PendingWrite) DiskError!void {
        const sector_size: usize = @intCast(self.options.sector_size);
        const midpoint = pending.bytes.len / 2;
        const torn_len = midpoint - midpoint % sector_size;
        if (torn_len == 0) return;

        const file = try self.getOrCreateFile(pending.path, pending.inode);
        try self.ensurePendingCreate(pending.op_id, file);
        try self.writeBytes(file, pending.offset, pending.bytes[0..torn_len]);
        const torn_end = try endOffset(pending.offset, torn_len);
        const logical_end = if (pending.logical_len) |logical_len|
            @min(logical_len, torn_end)
        else
            torn_end;
        file.len = @max(file.len, logical_end);
    }

    fn findSector(_: *Self, file: *File, index: u64) ?*Sector {
        for (file.sectors.items) |*sector| {
            if (sector.index == index) return sector;
        }
        return null;
    }

    fn getOrCreateSector(self: *Self, file: *File, index: u64) DiskError!*Sector {
        if (self.findSector(file, index)) |sector| return sector;

        const bytes = try self.world.allocator.alloc(u8, @intCast(self.options.sector_size));
        errdefer self.world.allocator.free(bytes);
        @memset(bytes, 0);

        try file.sectors.append(self.world.allocator, .{
            .index = index,
            .bytes = bytes,
        });
        return &file.sectors.items[file.sectors.items.len - 1];
    }

    fn readSectors(self: *Self, file: *File, offset: u64, buffer: []u8) DiskError!void {
        var remaining = buffer;
        var sector_index = offset / self.options.sector_size;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            if (self.findSector(file, sector_index)) |sector| {
                @memcpy(remaining[0..sector_size], sector.bytes);
            }
            remaining = remaining[sector_size..];
            sector_index += 1;
        }
    }

    fn readBytes(self: *Self, file: *File, offset: u64, buffer: []u8) DiskError!void {
        var remaining = buffer;
        var cursor = offset;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            const sector_index = cursor / self.options.sector_size;
            const sector_offset: usize = @intCast(cursor % self.options.sector_size);
            const readable = @min(sector_size - sector_offset, remaining.len);
            if (self.findSector(file, sector_index)) |sector| {
                @memcpy(remaining[0..readable], sector.bytes[sector_offset..][0..readable]);
            }
            remaining = remaining[readable..];
            cursor += readable;
        }
    }

    fn rangeHasCorruption(self: *Self, path: []const u8, offset: u64, len: usize) bool {
        const file = self.findFile(path) orelse return false;
        var remaining = len;
        var sector_index = offset / self.options.sector_size;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining > 0) {
            if (self.findSector(file, sector_index)) |sector| {
                if (sector.corrupt) return true;
            }
            remaining -= sector_size;
            sector_index += 1;
        }

        return false;
    }

    fn rangeHasCorruptionBytes(self: *Self, path: []const u8, offset: u64, len: usize) bool {
        const file = self.findFile(path) orelse return false;
        var remaining = len;
        var cursor = offset;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining > 0) {
            const sector_index = cursor / self.options.sector_size;
            const sector_offset: usize = @intCast(cursor % self.options.sector_size);
            const readable = @min(sector_size - sector_offset, remaining);
            if (self.findSector(file, sector_index)) |sector| {
                if (sector.corrupt) return true;
            }
            remaining -= readable;
            cursor += readable;
        }

        return false;
    }

    fn visibleLength(self: *Self, path: []const u8) ?u64 {
        var found = false;
        var len: u64 = 0;
        if (self.findFile(path)) |file| {
            found = true;
            len = file.len;
        }
        for (self.pending_writes.items) |*pending| {
            if (!std.mem.eql(u8, pending.path, path)) continue;
            found = true;
            const physical_end = endOffset(
                pending.offset,
                pending.bytes.len,
            ) catch std.math.maxInt(u64);
            len = @max(len, pending.logical_len orelse physical_end);
        }
        return if (found) len else null;
    }

    fn visibleInode(self: *Self, path: []const u8) ?u64 {
        if (self.findFile(path)) |file| return file.inode;
        for (self.pending_writes.items) |*pending| {
            if (std.mem.eql(u8, pending.path, path)) return pending.inode;
        }
        return null;
    }

    fn overlayPendingWrites(self: *Self, path: []const u8, offset: u64, buffer: []u8) void {
        const read_start = offset;
        const read_end = read_start + buffer.len;

        for (self.pending_writes.items) |*pending| {
            if (!std.mem.eql(u8, pending.path, path)) continue;

            const write_start = pending.offset;
            const write_end = write_start + pending.bytes.len;
            const overlap_start = @max(read_start, write_start);
            const overlap_end = @min(read_end, write_end);
            if (overlap_start >= overlap_end) continue;

            const dst_start: usize = @intCast(overlap_start - read_start);
            const src_start: usize = @intCast(overlap_start - write_start);
            const overlap_len: usize = @intCast(overlap_end - overlap_start);
            @memcpy(
                buffer[dst_start..][0..overlap_len],
                pending.bytes[src_start..][0..overlap_len],
            );
        }
    }

    fn writeBytes(self: *Self, file: *File, offset: u64, bytes: []const u8) DiskError!void {
        var remaining = bytes;
        var cursor = offset;
        const sector_size: usize = @intCast(self.options.sector_size);

        while (remaining.len > 0) {
            const sector_index = cursor / self.options.sector_size;
            const sector_offset: usize = @intCast(cursor % self.options.sector_size);
            const writable = @min(sector_size - sector_offset, remaining.len);
            const sector = try self.getOrCreateSector(file, sector_index);
            @memcpy(sector.bytes[sector_offset..][0..writable], remaining[0..writable]);
            remaining = remaining[writable..];
            cursor += writable;
        }
    }

    fn truncateFile(self: *Self, file: *File, len: u64) DiskError!void {
        const sector_size = self.options.sector_size;
        const keep_sector_count = if (len == 0) 0 else (len - 1) / sector_size + 1;

        var index: usize = 0;
        while (index < file.sectors.items.len) {
            if (file.sectors.items[index].index < keep_sector_count) {
                index += 1;
                continue;
            }
            var sector = file.sectors.orderedRemove(index);
            sector.deinit(self.world.allocator);
        }

        if (len > 0 and len % sector_size != 0) {
            const last_sector_index = len / sector_size;
            const keep_bytes: usize = @intCast(len % sector_size);
            if (self.findSector(file, last_sector_index)) |sector| {
                @memset(sector.bytes[keep_bytes..], 0);
            }
        }
    }

    fn endOffset(offset: u64, len: usize) DiskError!u64 {
        const len_u64: u64 = @intCast(len);
        if (std.math.maxInt(u64) - offset < len_u64) return error.InvalidRange;
        return offset + len_u64;
    }

    fn recordCrashWrite(
        self: *Self,
        pending: *const PendingWrite,
        result: []const u8,
    ) DiskError!void {
        try self.world.recordFields("disk.crash_write", &.{
            traceField("op", .{ .uint = pending.op_id }),
            traceField("path", .{ .text = pending.path }),
            traceField("offset", .{ .uint = pending.offset }),
            traceField("len", .{ .uint = @intCast(pending.bytes.len) }),
            traceField("result", .{ .literal = result }),
        });
    }

    fn recordCrashMetadata(
        self: *Self,
        pending: *const PendingMetadata,
        result: []const u8,
    ) DiskError!void {
        try self.world.recordFields("disk.crash_metadata", &.{
            traceField("op", .{ .uint = pending.op_id }),
            traceField("dir", .{ .text = pending.dir }),
            traceField("kind", .{ .literal = @tagName(pending.kind) }),
            traceField("result", .{ .literal = result }),
        });
    }

    fn recordPathOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        try self.world.recordFields(name, &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("status", .{ .literal = status }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn recordMetadataOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        len: u64,
        committed: u64,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        try self.world.recordFields(name, &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("len", .{ .uint = len }),
            traceField("status", .{ .literal = status }),
            traceField("committed_writes", .{ .uint = committed }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    fn recordLifecycleOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        new_path: ?[]const u8,
        committed: u64,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        if (new_path) |renamed_to| {
            try self.world.recordFields(name, &.{
                traceField("op", .{ .uint = op_id }),
                traceField("path", .{ .text = path }),
                traceField("new_path", .{ .text = renamed_to }),
                traceField("status", .{ .literal = status }),
                traceField("committed_writes", .{ .uint = committed }),
                traceField("latency_ns", .{ .uint = latency_ns }),
            });
        } else {
            try self.world.recordFields(name, &.{
                traceField("op", .{ .uint = op_id }),
                traceField("path", .{ .text = path }),
                traceField("status", .{ .literal = status }),
                traceField("committed_writes", .{ .uint = committed }),
                traceField("latency_ns", .{ .uint = latency_ns }),
            });
        }
    }

    fn recordRangeOp(
        self: *Self,
        name: []const u8,
        op_id: u64,
        path: []const u8,
        offset: u64,
        len: usize,
        status: []const u8,
        latency_ns: clock_module.Duration,
    ) DiskError!void {
        try self.world.recordFields(name, &.{
            traceField("op", .{ .uint = op_id }),
            traceField("path", .{ .text = path }),
            traceField("offset", .{ .uint = offset }),
            traceField("len", .{ .uint = @intCast(len) }),
            traceField("status", .{ .literal = status }),
            traceField("latency_ns", .{ .uint = latency_ns }),
        });
    }

    const disk_vtable: Disk.VTable = .{
        .read = diskRead,
        .write = diskWrite,
        .sync = diskSync,
        .sync_dir = diskSyncDir,
        .stat = diskStat,
        .read_some = diskReadSome,
        .set_length = diskSetLength,
        .delete = diskDelete,
        .rename = diskRename,
        .create_dir = diskCreateDir,
        .stat_dir = diskStatDir,
        .read_dir = diskReadDir,
    };

    const control_vtable: DiskControl.VTable = .{
        .set_faults = controlSetFaults,
        .corrupt_sector = controlCorruptSector,
        .crash = controlCrash,
        .crash_after_ops = controlCrashAfterOps,
        .restart = controlRestart,
        .disk = controlDisk,
    };

    fn fromOpaque(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn diskRead(ptr: *anyopaque, options: Disk.Read) DiskError!void {
        try fromOpaque(ptr).read(options);
    }

    fn diskWrite(ptr: *anyopaque, options: Disk.Write) DiskError!void {
        try fromOpaque(ptr).write(options);
    }

    fn diskSync(ptr: *anyopaque, options: Disk.Sync) DiskError!void {
        try fromOpaque(ptr).sync(options);
    }

    fn diskSyncDir(ptr: *anyopaque, options: Disk.SyncDir) DiskError!void {
        try fromOpaque(ptr).syncDir(options);
    }

    fn diskStat(ptr: *anyopaque, options: Disk.Stat) DiskError!Disk.StatResult {
        return try fromOpaque(ptr).stat(options);
    }

    fn diskReadSome(ptr: *anyopaque, options: Disk.ReadSome) DiskError!usize {
        return try fromOpaque(ptr).readSome(options);
    }

    fn diskSetLength(ptr: *anyopaque, options: Disk.SetLength) DiskError!void {
        try fromOpaque(ptr).setLength(options);
    }

    fn diskDelete(ptr: *anyopaque, options: Disk.Delete) DiskError!void {
        try fromOpaque(ptr).delete(options);
    }

    fn diskRename(ptr: *anyopaque, options: Disk.Rename) DiskError!void {
        try fromOpaque(ptr).rename(options);
    }

    fn diskCreateDir(ptr: *anyopaque, options: Disk.CreateDir) DiskError!void {
        try fromOpaque(ptr).createDir(options);
    }

    fn diskStatDir(ptr: *anyopaque, options: Disk.StatDir) DiskError!Disk.StatDirResult {
        return try fromOpaque(ptr).statDir(options);
    }

    fn diskReadDir(ptr: *anyopaque, options: Disk.ReadDir) DiskError!Disk.DirList {
        return try fromOpaque(ptr).readDir(options);
    }

    fn controlSetFaults(ptr: *anyopaque, faults: DiskFaultOptions) DiskError!void {
        try fromOpaque(ptr).setFaults(faults);
    }

    fn controlCorruptSector(ptr: *anyopaque, path: []const u8, offset: u64) DiskError!void {
        try fromOpaque(ptr).corruptSector(path, offset);
    }

    fn controlCrash(ptr: *anyopaque) DiskError!void {
        try fromOpaque(ptr).crash(.{});
    }

    fn controlCrashAfterOps(ptr: *anyopaque, ops: u64) DiskError!void {
        try fromOpaque(ptr).crashAfterOps(ops);
    }

    fn controlRestart(ptr: *anyopaque) DiskError!void {
        try fromOpaque(ptr).restart(.{});
    }

    fn controlDisk(ptr: *anyopaque) Disk {
        return fromOpaque(ptr).disk();
    }
};
