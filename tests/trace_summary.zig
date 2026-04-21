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
        \\trace.events total=53 final_time_ns=6000000
        \\trace.run profile=replicated-register-smoke
        \\trace.run tag=example:replicated_register
        \\trace.run tag=scenario:smoke
        \\trace.run attribute.replicas=uint:3
        \\trace.run attribute.quorum=uint:2
        \\trace.run attribute.max_messages=uint:64
        \\trace.run attribute.proposal_drop_percent=uint:20
        \\trace.run attribute.retry_limit=uint:8
        \\trace.subsystem name=network count=11
        \\trace.subsystem name=register count=11
        \\trace.subsystem name=replica count=5
        \\trace.subsystem name=run count=8
        \\trace.subsystem name=world count=18
        \\trace.event_top rank=1 name=world.random_int_less_than count=11
        \\trace.event_top rank=2 name=register.message count=6
        \\trace.event_top rank=3 name=world.tick count=6
        \\trace.event_top rank=4 name=network.deliver count=5
        \\trace.event_top rank=5 name=network.send count=5
        \\trace.event_top rank=6 name=run.attribute count=5
        \\trace.event_top rank=7 name=replica.commit count=3
        \\trace.event_top rank=8 name=register.check count=2
        \\trace.singleton name=network.drop
        \\trace.singleton name=register.write.attempt
        \\trace.singleton name=register.write.quorum
        \\trace.singleton name=register.write.start
        \\trace.singleton name=run.profile
        \\trace.singleton name=world.init
        \\trace.network sends=5 deliveries=5 drops=1
        \\trace.network.drop_reason name=send_drop count=1
        \\trace.network.link from=3 to=0 sends=2 deliveries=2 drops=0
        \\trace.network.link from=3 to=1 sends=2 deliveries=2 drops=0
        \\trace.network.link from=3 to=2 sends=1 deliveries=1 drops=1
        \\
    , writer.buffered());
}
