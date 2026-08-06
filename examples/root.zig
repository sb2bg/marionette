//! Example services used by Marionette tests and documentation.

pub const retry_queue = @import("retry_queue.zig");
pub const replicated_register = @import("replicated_register.zig");
pub const durable_broadcast = @import("durable_broadcast.zig");
pub const kv_store = @import("kv_store.zig");
pub const idempotency_bug = @import("idempotency_bug.zig");
pub const toy_sql_db = @import("toy_sql_db.zig");
pub const std_io_net_kv = @import("std_io_net_kv.zig");
pub const memtable_pressure = @import("memtable_pressure.zig");
pub const wal_record = @import("wal_record.zig");
const support = @import("support.zig");

test {
    _ = retry_queue;
    _ = replicated_register;
    _ = durable_broadcast;
    _ = kv_store;
    _ = idempotency_bug;
    _ = toy_sql_db;
    _ = std_io_net_kv;
    _ = memtable_pressure;
    _ = wal_record;
    _ = support;
}
