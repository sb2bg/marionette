const std = @import("std");
const marionette_build = @import("marionette");

pub fn build(b: *std.Build) void {
    const tidy = marionette_build.addTidyStep(b, .{
        .paths = &.{"src"},
    });
    tidy.setCwd(b.path("."));

    const test_step = b.step("test", "Verify the exported Marionette tidy helper");
    test_step.dependOn(&tidy.step);
}
