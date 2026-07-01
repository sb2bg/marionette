//! Shared fault-model vocabulary.

const std = @import("std");

pub const BuggifyError = error{
    InvalidRate,
};

/// Probability that a BUGGIFY hook fires in simulation.
pub const BuggifyRate = struct {
    numerator: u32,
    denominator: u32,

    /// Disabled hook.
    pub fn never() BuggifyRate {
        return .{ .numerator = 0, .denominator = 1 };
    }

    /// Always-on hook.
    pub fn always() BuggifyRate {
        return .{ .numerator = 1, .denominator = 1 };
    }

    /// Percentage chance in the closed range `0..100`.
    pub fn percent(value: u8) BuggifyRate {
        std.debug.assert(value <= 100);
        return .{ .numerator = value, .denominator = 100 };
    }

    /// One-in-N chance.
    pub fn oneIn(denominator: u32) BuggifyRate {
        std.debug.assert(denominator > 0);
        return .{ .numerator = 1, .denominator = denominator };
    }

    pub fn validate(self: BuggifyRate) BuggifyError!void {
        if (self.denominator == 0) return error.InvalidRate;
        if (self.numerator > self.denominator) return error.InvalidRate;
    }
};
