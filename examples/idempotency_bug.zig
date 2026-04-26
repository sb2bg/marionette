//! Marionette example: a seed-sensitive idempotency bug.
//!
//! - `Harness` owns a small payment service and simulator authorities.
//! - `scenario` uses the seeded env to choose whether two accounts reuse an id.
//! - `checks` assert both account-local deposits are applied exactly once.
//! - Passing and failing seeds are replayable because every decision is traced.

const std = @import("std");
const mar = @import("marionette");

pub const passing_seed: u64 = 0xC0FFEE;
pub const failing_seed: u64 = 13;

const deposit_cents = 100;

pub const checks = [_]mar.StateCheck(Harness){
    .{ .name = "account-local deposits are not globally deduped", .check = balancesAreSafe },
};

pub fn scenario(harness: *Harness) !void {
    const env = harness.service.env;
    const alice_request_id = try env.random.intLessThan(u32, 10_000);
    const reuse_request_id = try env.buggify(.reuse_request_id_across_accounts, .oneIn(8));
    const bob_request_id = if (reuse_request_id) alice_request_id else alice_request_id + 1;

    try env.record(
        "idempotency.requests alice_id={} bob_id={} reused={}",
        .{ alice_request_id, bob_request_id, reuse_request_id },
    );

    try harness.service.deposit(.alice, alice_request_id, deposit_cents);
    try harness.service.deposit(.bob, bob_request_id, deposit_cents);
}

fn balancesAreSafe(harness: *const Harness) !void {
    const service = &harness.service;

    if (service.balance(.alice) != deposit_cents or service.balance(.bob) != deposit_cents) {
        try service.env.record(
            "idempotency.invariant_violation alice_balance={} bob_balance={} last_request_id={?}",
            .{ service.balance(.alice), service.balance(.bob), service.last_request_id },
        );
        return error.AccountDepositLost;
    }

    try service.env.record(
        "idempotency.check balances=ok alice_balance={} bob_balance={}",
        .{ service.balance(.alice), service.balance(.bob) },
    );
}

pub const Harness = struct {
    service: PaymentService,
    control: mar.SimControl,

    pub fn init(world: *mar.World) !Harness {
        const sim = try world.simulate(.{});
        return .{
            .service = .{ .env = sim.env },
            .control = sim.control,
        };
    }
};

const Account = enum {
    alice,
    bob,
};

const PaymentService = struct {
    env: mar.Env,
    alice_balance: u32 = 0,
    bob_balance: u32 = 0,
    last_request_id: ?u32 = null,

    fn deposit(self: *PaymentService, account: Account, request_id: u32, cents: u32) !void {
        // Bug: request IDs are account-local, but this cache is global.
        if (self.last_request_id == request_id) {
            try self.env.record(
                "idempotency.deposit account={s} request_id={} cents={} accepted=false reason=global_duplicate",
                .{ @tagName(account), request_id, cents },
            );
            return;
        }

        self.last_request_id = request_id;
        switch (account) {
            .alice => self.alice_balance += cents,
            .bob => self.bob_balance += cents,
        }

        try self.env.record(
            "idempotency.deposit account={s} request_id={} cents={} accepted=true",
            .{ @tagName(account), request_id, cents },
        );
    }

    fn balance(self: *const PaymentService, account: Account) u32 {
        return switch (account) {
            .alice => self.alice_balance,
            .bob => self.bob_balance,
        };
    }
};

pub fn runReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}
