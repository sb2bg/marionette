const mar = @import("marionette");

pub fn takePassedTrace(report: *mar.RunReport) ![]u8 {
    return switch (report.*) {
        .passed => |*passed| passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.UnexpectedRunFailure;
        },
    };
}
