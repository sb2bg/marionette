const std = @import("std");

const clock_module = @import("../clock.zig");
const DiskFaultOptions = @import("model.zig").DiskFaultOptions;
const SimDisk = @import("sim.zig").SimDisk;
const World = @import("../world.zig").World;

test "disk: writes and reads sector-aligned logical files" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{
        .path = "wal.log",
        .offset = 4,
        .bytes = "abcd",
    });

    var buffer: [8]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("\x00\x00\x00\x00abcd", &buffer);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.write op=0 path=wal.log offset=4 len=4 status=ok latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=8 status=ok latency_ns=10") != null);
}

test "disk: lifecycle operations are deterministic and trace-visible" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();
    const app_disk = disk.disk();

    try app_disk.write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try std.testing.expectEqual(@as(u64, 4), (try app_disk.stat(.{ .path = "wal.log" })).size);

    var small: [2]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 2), try app_disk.readSome(.{
        .path = "wal.log",
        .offset = 2,
        .buffer = &small,
    }));
    try std.testing.expectEqualStrings("cd", &small);

    var eof_buffer: [4]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 0), try app_disk.readSome(.{
        .path = "wal.log",
        .offset = 4,
        .buffer = &eof_buffer,
    }));
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0xff)), &eof_buffer);

    try app_disk.setLength(.{ .path = "wal.log", .len = 2 });
    try std.testing.expectEqual(@as(u64, 2), (try app_disk.stat(.{ .path = "wal.log" })).size);

    try app_disk.rename(.{ .old_path = "wal.log", .new_path = "archive/wal.log" });
    try std.testing.expectError(error.FileNotFound, app_disk.stat(.{ .path = "wal.log" }));
    try std.testing.expectEqual(@as(u64, 2), (try app_disk.stat(.{ .path = "archive/wal.log" })).size);

    try app_disk.delete(.{ .path = "archive/wal.log" });
    try std.testing.expectError(error.FileNotFound, app_disk.stat(.{ .path = "archive/wal.log" }));

    const trace = world.traceBytes();
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.stat op=1 path=wal.log status=ok size=4 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.read_some op=2 path=wal.log offset=2 requested_len=2 read_len=2 status=ok latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.set_length op=4 path=wal.log len=2 status=ok committed_writes=1 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.rename op=6 path=wal.log new_path=archive/wal.log status=ok committed_writes=0 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "disk.delete op=9 path=archive/wal.log status=ok committed_writes=0 latency_ns=10") != null);
}

test "disk: sync consumes operation ids and escapes logical paths" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{});
    defer disk.deinit();

    try disk.disk().sync(.{ .path = "dir/wal 1.log" });

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync op=0 path=dir/wal%201.log status=ok committed_writes=0 latency_ns=1") != null);
}

test "disk: rejects invalid paths, ranges, and latency options" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    try std.testing.expectError(
        error.InvalidAlignment,
        SimDisk.init(&world, .{ .sector_size = 0 }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        SimDisk.init(&world, .{ .min_latency_ns = 11 }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        SimDisk.init(&world, .{ .min_latency_ns = clock_module.default_tick_ns }),
    );

    var disk = try SimDisk.init(&world, .{ .sector_size = 4, .min_latency_ns = 10 });
    defer disk.deinit();

    var buffer: [4]u8 = @splat(0);
    try std.testing.expectError(error.InvalidPath, disk.disk().read(.{
        .path = "",
        .offset = 0,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.InvalidAlignment, disk.disk().read(.{
        .path = "wal.log",
        .offset = 1,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.InvalidAlignment, disk.disk().write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "abc",
    }));
}

test "disk: latency jitter is deterministic and traced" {
    var a = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer b.deinit();

    var disk_a = try SimDisk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try SimDisk.init(&b, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_b.deinit();

    try disk_a.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk_b.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
    try std.testing.expect(std.mem.indexOf(u8, a.traceBytes(), "world.random_int_less_than type=u64 less_than=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, a.traceBytes(), "disk.write op=0 path=wal.log offset=0 len=4 status=ok latency_ns=") != null);
}

test "disk: write errors do not mutate durable sectors" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.control().setFaults(.{ .write_error_rate = .always() });
    try std.testing.expectError(error.WriteError, disk.disk().write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "zzzz",
    }));

    try disk.control().setFaults(.{});
    var buffer: [4]u8 = @splat(0xff);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=wal.log kind=write_error rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.write op=0 path=wal.log offset=0 len=4 status=io_error latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=ok latency_ns=10") != null);
}

test "disk: read errors return before filling buffer" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .read_error_rate = .always() });

    var buffer = [_]u8{ 'x', 'x', 'x', 'x' };
    try std.testing.expectError(error.ReadError, disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    }));

    try std.testing.expectEqualStrings("xxxx", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=1 path=wal.log kind=read_error rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=io_error latency_ns=10") != null);
}

test "disk: corrupt read faults do not mutate durable sectors" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .corrupt_read_rate = .always() });

    var corrupt_buffer: [4]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &corrupt_buffer,
    });
    try std.testing.expect(!std.mem.eql(u8, "abcd", &corrupt_buffer));

    try disk.control().setFaults(.{});
    var clean_buffer: [4]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &clean_buffer,
    });
    try std.testing.expectEqualStrings("abcd", &clean_buffer);

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=1 path=wal.log kind=corrupt_read rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=corrupt latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=2 path=wal.log offset=0 len=4 status=ok latency_ns=10") != null);
}

test "disk: scripted sector corruption persists across reads" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().corruptSector("wal.log", 0);

    var buffer: [4]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expect(!std.mem.eql(u8, "abcd", &buffer));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault path=wal.log offset=0 kind=scripted_corruption") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=corrupt latency_ns=10") != null);
}

test "disk: rejects invalid fault rates" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{});
    defer disk.deinit();
    const control = disk.control();

    try std.testing.expectError(error.InvalidRate, control.setFaults(.{
        .read_error_rate = .{ .numerator = 1, .denominator = 0 },
    }));
    try std.testing.expectError(error.InvalidRate, control.setFaults(.{
        .write_error_rate = .{ .numerator = 2, .denominator = 1 },
    }));
}

test "disk: fault traces are deterministic for the same seed" {
    var a = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer b.deinit();

    var disk_a = try SimDisk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try SimDisk.init(&b, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_b.deinit();

    const faults: DiskFaultOptions = .{
        .read_error_rate = .oneIn(2),
        .write_error_rate = .oneIn(2),
        .corrupt_read_rate = .oneIn(2),
    };
    try disk_a.control().setFaults(faults);
    try disk_b.control().setFaults(faults);

    disk_a.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" }) catch |err| switch (err) {
        error.WriteError => {},
        else => return err,
    };
    disk_b.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" }) catch |err| switch (err) {
        error.WriteError => {},
        else => return err,
    };

    var buffer_a: [4]u8 = @splat(0);
    disk_a.disk().read(.{ .path = "wal.log", .offset = 0, .buffer = &buffer_a }) catch |err| switch (err) {
        error.ReadError => {},
        else => return err,
    };

    var buffer_b: [4]u8 = @splat(0);
    disk_b.disk().read(.{ .path = "wal.log", .offset = 0, .buffer = &buffer_b }) catch |err| switch (err) {
        error.ReadError => {},
        else => return err,
    };

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
}

test "disk: sync makes pending writes survive crash" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.disk().sync(.{ .path = "wal.log" });
    try disk.control().setFaults(.{ .crash_lost_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer: [4]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync op=1 path=wal.log status=ok committed_writes=1 latency_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=0 landed=0 lost=0 torn=0") != null);
}

test "disk: crash can lose file metadata without directory sync" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.disk().sync(.{ .path = "wal.log" });
    try std.testing.expectEqual(@as(u64, 4), (try disk.disk().stat(.{ .path = "wal.log" })).size);

    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectError(error.FileNotFound, disk.disk().stat(.{ .path = "wal.log" }));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=. kind=crash_lost_metadata rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_metadata op=0 dir=. kind=create result=lost") != null);
}

test "disk: directory sync makes file metadata survive crash" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.disk().sync(.{ .path = "wal.log" });
    try disk.disk().syncDir(.{ .path = "." });
    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectEqual(@as(u64, 4), (try disk.disk().stat(.{ .path = "wal.log" })).size);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.sync_dir op=2 path=. status=ok committed_metadata=1 latency_ns=10") != null);
}

test "disk: crash can roll back unsynced delete and rename metadata" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.disk().sync(.{ .path = "wal.log" });
    try disk.disk().syncDir(.{ .path = "." });

    try disk.disk().rename(.{ .old_path = "wal.log", .new_path = "archive/wal.log" });
    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectEqual(@as(u64, 4), (try disk.disk().stat(.{ .path = "wal.log" })).size);
    try std.testing.expectError(error.FileNotFound, disk.disk().stat(.{ .path = "archive/wal.log" }));

    try disk.control().setFaults(.{});
    try disk.disk().rename(.{ .old_path = "wal.log", .new_path = "archive/wal.log" });
    try disk.disk().syncDir(.{ .path = "." });
    try disk.disk().syncDir(.{ .path = "archive" });
    try disk.disk().delete(.{ .path = "archive/wal.log" });
    try disk.control().setFaults(.{ .crash_lost_metadata_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    try std.testing.expectEqual(@as(u64, 4), (try disk.disk().stat(.{ .path = "archive/wal.log" })).size);
}

test "disk: crash can lose unflushed pending writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .crash_lost_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer: [4]u8 = @splat(0xff);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=wal.log kind=crash_lost_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write op=0 path=wal.log offset=0 len=4 result=lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=1 landed=0 lost=1 torn=0") != null);
}

test "disk: crash can tear unflushed pending writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "wxyz" });
    try disk.disk().sync(.{ .path = "wal.log" });
    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk.control().setFaults(.{ .crash_torn_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer: [4]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("abyz", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=2 path=wal.log kind=crash_torn_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write op=2 path=wal.log offset=0 len=4 result=torn") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=1 landed=0 lost=0 torn=1") != null);
}

test "disk: crash can reorder unflushed pending writes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "1111" });
    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "2222" });
    try disk.control().setFaults(.{ .crash_reordered_write_rate = .always() });
    try disk.control().crash();
    try disk.control().restart();

    var buffer: [4]u8 = @splat(0);
    try disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("1111", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.fault op=0 path=wal.log kind=crash_reordered_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash_write op=1 path=wal.log offset=0 len=4 result=reordered") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.crash pending_writes=2 landed=0 lost=0 torn=0 reordered=2") != null);
}

test "disk: crashed disk rejects operations until restart" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var disk = try SimDisk.init(&world, .{
        .sector_size = 4,
        .min_latency_ns = 10,
    });
    defer disk.deinit();

    try disk.control().crash();

    var buffer: [4]u8 = @splat(0);
    try std.testing.expectError(error.DiskCrashed, disk.disk().read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    }));
    try std.testing.expectError(error.DiskCrashed, disk.disk().write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "abcd",
    }));
    try std.testing.expectError(error.DiskCrashed, disk.disk().sync(.{ .path = "wal.log" }));

    try disk.control().restart();
    try disk.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
}

test "disk: crash traces are deterministic for the same seed" {
    var a = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 99, .tick_ns = 10 });
    defer b.deinit();

    var disk_a = try SimDisk.init(&a, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_a.deinit();
    var disk_b = try SimDisk.init(&b, .{
        .sector_size = 4,
        .min_latency_ns = 10,
        .latency_jitter_ns = 20,
    });
    defer disk_b.deinit();

    const faults: DiskFaultOptions = .{
        .crash_lost_write_rate = .oneIn(2),
        .crash_torn_write_rate = .oneIn(2),
    };
    try disk_a.control().setFaults(faults);
    try disk_b.control().setFaults(faults);

    try disk_a.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk_b.disk().write(.{ .path = "wal.log", .offset = 0, .bytes = "abcd" });
    try disk_a.control().crash();
    try disk_b.control().crash();

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
}
