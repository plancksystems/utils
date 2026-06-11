
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version: u8 = 1;

pub const Kind = enum(u8) {
    insert = 1,
    update = 2,
    delete = 3,

    pub fn fromByte(b: u8) ?Kind {
        return switch (b) {
            1 => .insert,
            2 => .update,
            3 => .delete,
            else => null,
        };
    }
};

pub const Frame = struct {
    version: u8 = version,
    kind: Kind,
    writer_lsn: u64,
    timestamp_ms: i64,
    store_ns: []const u8,
    key: u128,
    value: ?[]const u8,
    pub fn encodedLen(self: Frame) usize {
        const value_len: usize = if (self.value) |v| v.len else 0;
        return 4 + bodyLen(self.store_ns.len, value_len);
    }

    pub fn encode(self: Frame, out: []u8) ![]u8 {
        const n = self.encodedLen();
        if (out.len < n) return error.BufferTooSmall;

        const value_len: u32 = @intCast(if (self.value) |v| v.len else 0);
        const body_len: u32 = @intCast(bodyLen(self.store_ns.len, value_len));
        const store_ns_len: u16 = @intCast(self.store_ns.len);

        var p: usize = 0;
        std.mem.writeInt(u32, out[p..][0..4], body_len, .little);
        p += 4;
        out[p] = self.version;
        p += 1;
        out[p] = @intFromEnum(self.kind);
        p += 1;
        std.mem.writeInt(u64, out[p..][0..8], self.writer_lsn, .little);
        p += 8;
        std.mem.writeInt(i64, out[p..][0..8], self.timestamp_ms, .little);
        p += 8;
        std.mem.writeInt(u16, out[p..][0..2], store_ns_len, .little);
        p += 2;
        @memcpy(out[p..][0..self.store_ns.len], self.store_ns);
        p += self.store_ns.len;
        std.mem.writeInt(u128, out[p..][0..16], self.key, .little);
        p += 16;
        std.mem.writeInt(u32, out[p..][0..4], value_len, .little);
        p += 4;
        if (self.value) |v| {
            @memcpy(out[p..][0..v.len], v);
            p += v.len;
        }

        std.debug.assert(p == n);
        return out[0..n];
    }

    pub fn encodeAlloc(self: Frame, allocator: Allocator) ![]u8 {
        const n = self.encodedLen();
        const buf = try allocator.alloc(u8, n);
        errdefer allocator.free(buf);
        _ = try self.encode(buf);
        return buf;
    }

    pub fn decode(bytes: []const u8) !Parsed {
        if (bytes.len < 4) return error.Incomplete;
        const body_len = std.mem.readInt(u32, bytes[0..4], .little);
        const total = @as(usize, body_len) + 4;
        if (bytes.len < total) return error.Incomplete;

        const body = bytes[4..total];
        if (body.len < 1 + 1 + 8 + 8 + 2 + 0 + 16 + 4) return error.BodyTooShort;

        var p: usize = 0;
        const ver = body[p];
        p += 1;
        if (ver != version) return error.UnsupportedVersion;
        const kind_byte = body[p];
        p += 1;
        const kind = Kind.fromByte(kind_byte) orelse return error.UnknownKind;
        const writer_lsn = std.mem.readInt(u64, body[p..][0..8], .little);
        p += 8;
        const ts_ms = std.mem.readInt(i64, body[p..][0..8], .little);
        p += 8;
        const ns_len = std.mem.readInt(u16, body[p..][0..2], .little);
        p += 2;
        if (body.len < p + ns_len + 16 + 4) return error.BodyTooShort;
        const ns = body[p..][0..ns_len];
        p += ns_len;
        const key = std.mem.readInt(u128, body[p..][0..16], .little);
        p += 16;
        const value_len = std.mem.readInt(u32, body[p..][0..4], .little);
        p += 4;
        if (body.len < p + value_len) return error.BodyTooShort;
        const value: ?[]const u8 = if (value_len == 0) null else body[p..][0..value_len];

        return .{
            .frame = .{
                .version = ver,
                .kind = kind,
                .writer_lsn = writer_lsn,
                .timestamp_ms = ts_ms,
                .store_ns = ns,
                .key = key,
                .value = value,
            },
            .total_consumed = total,
        };
    }
};

pub const Parsed = struct {
    frame: Frame,
    total_consumed: usize,
};

fn bodyLen(store_ns_len: usize, value_len: usize) usize {
    return 1 + 1 + 8 + 8 + 2 + store_ns_len + 16 + 4 + value_len;
}

const testing = std.testing;

test "Frame: encode/decode  with value" {
    const original: Frame = .{
        .kind = .insert,
        .writer_lsn = 0xDEADBEEFCAFEBABE,
        .timestamp_ms = 1_700_000_000_000,
        .store_ns = "orders",
        .key = 0x0102030405060708090A0B0C0D0E0F10,
        .value = "BSON_PAYLOAD_BYTES",
    };

    var buf: [256]u8 = undefined;
    const encoded = try original.encode(&buf);
    try testing.expectEqual(original.encodedLen(), encoded.len);

    const parsed = try Frame.decode(encoded);
    try testing.expectEqual(encoded.len, parsed.total_consumed);
    try testing.expectEqual(original.kind, parsed.frame.kind);
    try testing.expectEqual(original.writer_lsn, parsed.frame.writer_lsn);
    try testing.expectEqual(original.timestamp_ms, parsed.frame.timestamp_ms);
    try testing.expectEqualStrings(original.store_ns, parsed.frame.store_ns);
    try testing.expectEqual(original.key, parsed.frame.key);
    try testing.expect(parsed.frame.value != null);
    try testing.expectEqualSlices(u8, original.value.?, parsed.frame.value.?);
    try testing.expectEqual(@as(u8, version), parsed.frame.version);
}

test "Frame: delete has null value on decode" {
    const original: Frame = .{
        .kind = .delete,
        .writer_lsn = 42,
        .timestamp_ms = 99,
        .store_ns = "x",
        .key = 7,
        .value = null,
    };

    var buf: [128]u8 = undefined;
    const encoded = try original.encode(&buf);
    const parsed = try Frame.decode(encoded);

    try testing.expectEqual(Kind.delete, parsed.frame.kind);
    try testing.expectEqual(@as(?[]const u8, null), parsed.frame.value);
}

test "Frame: decode reports Incomplete when bytes short" {
    const original: Frame = .{
        .kind = .update,
        .writer_lsn = 1,
        .timestamp_ms = 2,
        .store_ns = "abc",
        .key = 3,
        .value = "v",
    };
    var buf: [128]u8 = undefined;
    const encoded = try original.encode(&buf);

    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        try testing.expectError(error.Incomplete, Frame.decode(encoded[0..i]));
    }
    _ = try Frame.decode(encoded);
}

test "Frame: encodeAlloc matches encode" {
    const original: Frame = .{
        .kind = .insert,
        .writer_lsn = 1234,
        .timestamp_ms = 5678,
        .store_ns = "payments",
        .key = 0xAA,
        .value = "abc",
    };
    var buf: [128]u8 = undefined;
    const direct = try original.encode(&buf);
    const allocd = try original.encodeAlloc(testing.allocator);
    defer testing.allocator.free(allocd);
    try testing.expectEqualSlices(u8, direct, allocd);
}

test "Frame: rejects unknown kind" {
    const original: Frame = .{
        .kind = .insert,
        .writer_lsn = 1,
        .timestamp_ms = 1,
        .store_ns = "x",
        .key = 1,
        .value = null,
    };
    var buf: [128]u8 = undefined;
    const encoded = try original.encode(&buf);

    var mutable_copy: [128]u8 = undefined;
    @memcpy(mutable_copy[0..encoded.len], encoded);
    mutable_copy[4 + 1] = 99;
    try testing.expectError(error.UnknownKind, Frame.decode(mutable_copy[0..encoded.len]));
}

test "Frame: rejects wrong version" {
    const original: Frame = .{
        .kind = .insert,
        .writer_lsn = 1,
        .timestamp_ms = 1,
        .store_ns = "x",
        .key = 1,
        .value = null,
    };
    var buf: [128]u8 = undefined;
    const encoded = try original.encode(&buf);
    var mutable_copy: [128]u8 = undefined;
    @memcpy(mutable_copy[0..encoded.len], encoded);
    mutable_copy[4 + 0] = 99;
    try testing.expectError(error.UnsupportedVersion, Frame.decode(mutable_copy[0..encoded.len]));
}
