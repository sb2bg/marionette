//! External validation for Ochi's unmodified storage implementation.
//!
//! Ochi uses a process-global atomic counter for temporary file names, so this
//! target runs one checked simulation instead of Marionette's in-process
//! two-pass replay runner. Separate process invocations remain reproducible.

const std = @import("std");
const mar = @import("marionette");
const OchiStore = @import("ochi_store");
const OchiLogging = @import("ochi_logging");

const store_init_info = @typeInfo(@TypeOf(OchiStore.init)).@"fn";
const Conf = @typeInfo(store_init_info.params[2].type.?).pointer.child;
const Runtime = @typeInfo(store_init_info.params[3].type.?).pointer.child;
const Layout = store_init_info.params[4].type.?;

const add_lines_info = @typeInfo(@TypeOf(OchiStore.addLines)).@"fn";
const Line = @typeInfo(add_lines_info.params[3].type.?).pointer.child;
const Field = @typeInfo(add_lines_info.params[4].type.?).pointer.child;
const SID = add_lines_info.params[6].type.?;
const query_lines_info = @typeInfo(@TypeOf(OchiStore.queryLines)).@"fn";
const Query = query_lines_info.params[5].type.?;

const store_path = "/ochi";
const day_ns = 24 * 60 * 60 * 1_000_000_000;
const start_ns = 31 * day_ns;

fn noopProcessRestart(_: *anyopaque, _: mar.Env) anyerror!void {}

const OchiApp = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conf: *Conf,
    store: *OchiStore,
    layout_buffer: []u8,

    fn init(sim: mar.Sim) !OchiApp {
        const allocator = std.testing.allocator;
        const io = sim.env.io();

        try OchiLogging.setup(io, allocator, .{
            .level = .None,
            .pool_size = 0,
            .buffer_size = 0,
            .pool_strategy = .noop,
            .large_buffer_count = 0,
            .large_buffer_size = 0,
            .large_buffer_strategy = .drop,
        });
        errdefer OchiLogging.deinit();

        const conf = try allocator.create(Conf);
        errdefer allocator.destroy(conf);
        conf.* = Conf.default(allocator);
        conf.app.storePath = store_path;

        const runtime = try allocator.create(Runtime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{
            .maxMem = 1024 * 1024 * 1024,
            .cacheSize = 512 * 1024 * 1024,
            .diskSpace = .{
                .total = 1024 * 1024 * 1024,
                .free = 1024 * 1024 * 1024,
                .updatedAtMs = start_ns / 1_000_000,
            },
            .path = store_path,
            .cpus = 4,
            .httpThreads = 4,
            .workerThreads = 4,
        };

        const layout_buffer = try allocator.alloc(u8, std.fs.max_path_bytes);
        errdefer allocator.free(layout_buffer);
        try sim.env.record(
            "ochi.frontier phase=layout.make requires=dir_access,dir_create,dir_open",
            .{},
        );
        const layout = try Layout.make(io, store_path, layout_buffer);
        defer layout.partitionsDir.close(io);

        const store = try allocator.create(OchiStore);
        errdefer allocator.destroy(store);
        try sim.env.record(
            "ochi.frontier phase=store.init requires=dir_iterate,file_lock,file_stat",
            .{},
        );
        store.* = try OchiStore.init(io, allocator, conf, runtime, layout);

        return .{
            .allocator = allocator,
            .io = io,
            .conf = conf,
            .store = store,
            .layout_buffer = layout_buffer,
        };
    }

    pub fn deinit(self: *OchiApp) void {
        self.store.deinit(self.io, self.allocator);
        self.allocator.destroy(self.store);
        self.allocator.destroy(self.conf);
        self.allocator.free(self.layout_buffer);
        OchiLogging.deinit();
    }
};

const Case = mar.SimCase(OchiApp);

fn scenario(case: *Case) !void {
    try case.env().record(
        "ochi.frontier phase=store.start requires=group_concurrent,group_await,sleep",
        .{},
    );
    try case.app.store.start(case.app.io, case.app.allocator);

    var fields = [_]Field{
        .{ .key = "", .value = "hello from marionette" },
    };
    var lines = [_]Line{
        .{ .timestampNs = start_ns, .fields = &fields },
    };
    const no_tags = [_]Field{};
    const encoded_no_tags = [_]u8{0};
    const sid: SID = .{ .tenantID = 1, .id = 1 };

    try case.env().record(
        "ochi.frontier phase=store.add_lines requires=directories,semaphores,groups,file_io",
        .{},
    );
    try case.app.store.addLines(
        case.app.io,
        case.app.allocator,
        &lines,
        &no_tags,
        &encoded_no_tags,
        sid,
    );
    try case.env().record(
        "ochi.frontier phase=store.flush requires=atomic_rename,file_sync,dir_sync",
        .{},
    );
    try case.app.store.flush(case.app.io, case.app.allocator);
}

fn deinitQueriedLines(allocator: std.mem.Allocator, lines: *std.ArrayList(Line)) void {
    for (lines.items) |line| {
        for (line.fields) |field| {
            allocator.free(field.key);
            allocator.free(field.value);
        }
        allocator.free(line.fields);
    }
    lines.deinit(allocator);
}

fn expectStoredLine(app: *OchiApp) !void {
    const stream_ids = [_]u128{1};
    var lines = try app.store.queryLines(
        app.io,
        app.allocator,
        app.allocator,
        1,
        Query{
            .streamIDs = &stream_ids,
            .start = start_ns - 1,
            .end = start_ns + 1,
        },
    );
    defer deinitQueriedLines(app.allocator, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(start_ns, lines.items[0].timestampNs);
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].fields.len);
    try std.testing.expectEqualStrings("", lines.items[0].fields[0].key);
    try std.testing.expectEqualStrings(
        "hello from marionette",
        lines.items[0].fields[0].value,
    );
}

test "Ochi storage survives flush, crash, and reopen under Marionette" {
    var world = try mar.World.init(std.testing.allocator, .{
        .seed = 0x0C41,
        .start_ns = start_ns,
    });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{ .sector_size = 4096 } });
    try sim.registerProcess(0, .{
        .ptr = sim.control.world,
        .restart = noopProcessRestart,
    });
    var case: Case = .{
        .sim = sim,
        .app = try OchiApp.init(sim),
    };
    var app_live = true;
    defer if (app_live) case.app.deinit();

    try scenario(&case);
    try expectStoredLine(&case.app);
    try case.env().record("ochi.oracle phase=post_flush result=ok", .{});

    case.app.deinit();
    app_live = false;
    try sim.control.disk.setFaults(.{
        .crash_lost_write_rate = .always(),
        .crash_lost_metadata_rate = .always(),
    });
    try sim.control.disk.crash();
    try sim.control.disk.restart();
    try sim.restartProcess(0);

    case.app = try OchiApp.init(sim);
    app_live = true;
    try case.app.store.start(case.app.io, case.app.allocator);
    try expectStoredLine(&case.app);
    try case.env().record("ochi.oracle phase=post_reopen result=ok", .{});

    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "ochi.frontier phase=store.flush",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "disk.rename",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "ochi.oracle phase=post_reopen result=ok",
    ) != null);
}
