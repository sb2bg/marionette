//! Worked BUGGIFY shape for checking production dead-code elimination.

const Mode = enum {
    production,
    simulation,
};

const Hook = enum {
    drop_packet,
};

fn Sim(comptime mode: Mode) type {
    return struct {
        const Self = @This();

        inline fn buggify(_: *Self, comptime hook: Hook) bool {
            _ = hook;
            return switch (mode) {
                .production => comptime false,
                .simulation => true,
            };
        }
    };
}

export fn send_packet_prod() u32 {
    var sim: Sim(.production) = .{};
    if (sim.buggify(.drop_packet)) return 0;
    return 1;
}

export fn send_packet_baseline() u32 {
    return 1;
}
