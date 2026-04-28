const std = @import("std");
const examples = @import("examples");
const mar = @import("marionette");

pub fn expectReplicatedRegisterSummary(allocator: std.mem.Allocator) !void {
    const trace = try examples.replicated_register.runScenario(allocator, 0xC0FFEE);
    defer allocator.free(trace);

    var summary = try mar.summarize(allocator, trace);
    defer summary.deinit();

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try summary.writeSummary(&writer);

    try std.testing.expectEqualStrings(
        \\trace.events total=36
        \\trace.run profile=replicated-register-smoke
        \\trace.subsystem name=network count=12
        \\trace.subsystem name=register count=11
        \\trace.subsystem name=replica count=5
        \\trace.subsystem name=run count=1
        \\trace.subsystem name=world count=7
        \\trace.event_top rank=1 name=register.message count=6
        \\trace.event_top rank=2 name=world.random_int_less_than count=6
        \\trace.event_top rank=3 name=network.deliver count=5
        \\trace.event_top rank=4 name=network.send count=5
        \\trace.event_top rank=5 name=replica.accept count=3
        \\trace.event_top rank=6 name=register.check count=2
        \\trace.event_top rank=7 name=replica.commit count=2
        \\trace.event_top rank=8 name=network.drop count=1
        \\trace.singleton name=network.drop
        \\trace.singleton name=network.faults
        \\trace.singleton name=register.write.attempt
        \\trace.singleton name=register.write.quorum
        \\trace.singleton name=register.write.start
        \\trace.singleton name=run.profile
        \\trace.singleton name=world.init
        \\trace.network sends=5 deliveries=5 drops=1
        \\trace.network.drop_reason name=send_drop count=1
        \\trace.network.link from=3 to=0 sends=2 deliveries=2 drops=0
        \\trace.network.link from=3 to=1 sends=1 deliveries=1 drops=1
        \\trace.network.link from=3 to=2 sends=2 deliveries=2 drops=0
        \\
    , writer.buffered());
}
