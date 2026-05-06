# WAL Records

`mar.wal` provides a tiny fixed-size record framing helper for examples and
small tests. It is not a WAL framework: it does not choose offsets, manage
sync, scan files, or decide recovery policy. Application code still owns those
rules.

The helper frames one record as:

```text
magic:u32 | body:N bytes | checksum:u32
```

Use the body for service-specific fields such as a key, sequence number,
operation id, or payload. The examples use short ASCII-style magic values in a
commented u32 form, such as `MKV1` for the KV store and `MDB1` for durable
broadcast.

```zig
const Record = mar.wal.FixedRecord(8);
const magic: u32 = 0x4d4b5631; // MKV1

var body: [Record.body_size]u8 = undefined;
mar.wal.putU32(body[0..4], key);
mar.wal.putU32(body[4..8], value);

var bytes: [Record.record_size]u8 = undefined;
Record.encode(&bytes, magic, &body);
```

Strict recovery validates both magic and checksum:

```zig
const decoded = Record.decode(&bytes, magic) orelse return error.BadRecord;
const key = mar.wal.readU32(decoded.body[0..4]);
const value = mar.wal.readU32(decoded.body[4..8]);
```

`decodeMagicOnly` exists for deliberately buggy examples and tests. It is useful
when demonstrating why accepting a torn or corrupt record based only on magic is
wrong.

Corruption and torn writes remain application-visible bytes. Marionette's disk
simulator does not infer record validity; recovery code detects invalid records
with its own framing and checksum rules, just like production code would.
