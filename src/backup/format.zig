
const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub const BACKUP_MAGIC: u32 = 0x42414442;

pub const BACKUP_VERSION: u8 = 1;

pub const BACKUP_HEADER_SIZE: u64 = 29;

pub const SECTION_HEADER_FIXED_SIZE: usize = 1 + 4 + 8 + 8 + 4 + 1;

pub const What = enum(u8) {
    ValueLog = 0,
    Index = 1,
    Config = 2,
    Wasm = 3,
    Static = 4,
    Binary = 5,
    Log = 6,
    Wal = 7,
    Other = 255,
};

pub const BackupHeader = struct {
    magic: u32 = BACKUP_MAGIC,
    version: u8 = BACKUP_VERSION,
    timestamp: i64,
    component_count: u32,
    total_size: u64,
    compressed: bool = false,
};

pub const SectionHeader = struct {
    what: What,
    file_name_len: u32,
    file_name: []const u8,
    original_size: u64,
    compressed_size: u64,
    checksum: u32,
    compressed: bool,

    pub fn dataSize(self: SectionHeader) u64 {
        return if (self.compressed) self.compressed_size else self.original_size;
    }
};

pub const BackupMetadata = struct {
    backup_path: []const u8,
    timestamp: i64,
    size_bytes: u64,
    vlog_count: u16,
    entry_count: u64,
};

pub const FormatError = error{
    InvalidBackupFile,
    IncompatibleBackupVersion,
    ChecksumMismatch,
};

pub fn writeHeader(io: Io, file: File, header: BackupHeader, pos: u64) !u64 {
    var buf: [BACKUP_HEADER_SIZE]u8 = undefined;
    var o: usize = 0;
    std.mem.writeInt(u32, buf[o..][0..4], header.magic, .little);
    o += 4;
    buf[o] = header.version;
    o += 1;
    std.mem.writeInt(i64, buf[o..][0..8], header.timestamp, .little);
    o += 8;
    std.mem.writeInt(u32, buf[o..][0..4], header.component_count, .little);
    o += 4;
    std.mem.writeInt(u64, buf[o..][0..8], header.total_size, .little);
    o += 8;
    buf[o] = if (header.compressed) 1 else 0;
    o += 1;
    while (o < buf.len) : (o += 1) buf[o] = 0;
    try file.writePositionalAll(io, &buf, pos);
    return pos + BACKUP_HEADER_SIZE;
}

pub fn readHeader(io: Io, file: File, pos: u64) !struct { header: BackupHeader, pos: u64 } {
    var buf: [BACKUP_HEADER_SIZE]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, pos);
    var o: usize = 0;
    const magic = std.mem.readInt(u32, buf[o..][0..4], .little);
    o += 4;
    const version = buf[o];
    o += 1;
    const timestamp = std.mem.readInt(i64, buf[o..][0..8], .little);
    o += 8;
    const component_count = std.mem.readInt(u32, buf[o..][0..4], .little);
    o += 4;
    const total_size = std.mem.readInt(u64, buf[o..][0..8], .little);
    o += 8;
    const compressed = buf[o] != 0;
    return .{
        .header = .{
            .magic = magic,
            .version = version,
            .timestamp = timestamp,
            .component_count = component_count,
            .total_size = total_size,
            .compressed = compressed,
        },
        .pos = pos + BACKUP_HEADER_SIZE,
    };
}

pub fn writeSectionHeader(io: Io, file: File, header: SectionHeader, pos: u64) !u64 {
    var buf: [SECTION_HEADER_FIXED_SIZE]u8 = undefined;
    var o: usize = 0;
    buf[o] = @intFromEnum(header.what);
    o += 1;
    std.mem.writeInt(u32, buf[o..][0..4], header.file_name_len, .little);
    o += 4;
    std.mem.writeInt(u64, buf[o..][0..8], header.original_size, .little);
    o += 8;
    std.mem.writeInt(u64, buf[o..][0..8], header.compressed_size, .little);
    o += 8;
    std.mem.writeInt(u32, buf[o..][0..4], header.checksum, .little);
    o += 4;
    buf[o] = if (header.compressed) 1 else 0;
    try file.writePositionalAll(io, &buf, pos);
    const name_pos = pos + SECTION_HEADER_FIXED_SIZE;
    try file.writePositionalAll(io, header.file_name, name_pos);
    return name_pos + header.file_name.len;
}

pub fn readSectionHeader(allocator: Allocator, io: Io, file: File, pos: u64) !struct { header: SectionHeader, pos: u64 } {
    var buf: [SECTION_HEADER_FIXED_SIZE]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, pos);
    var o: usize = 0;
    const what: What = @enumFromInt(buf[o]);
    o += 1;
    const file_name_len = std.mem.readInt(u32, buf[o..][0..4], .little);
    o += 4;
    const original_size = std.mem.readInt(u64, buf[o..][0..8], .little);
    o += 8;
    const compressed_size = std.mem.readInt(u64, buf[o..][0..8], .little);
    o += 8;
    const checksum = std.mem.readInt(u32, buf[o..][0..4], .little);
    o += 4;
    const compressed = buf[o] != 0;

    var name_pos = pos + SECTION_HEADER_FIXED_SIZE;
    const file_name = try allocator.alloc(u8, file_name_len);
    _ = try file.readPositionalAll(io, file_name, name_pos);
    name_pos += file_name_len;

    return .{
        .header = .{
            .what = what,
            .file_name_len = file_name_len,
            .file_name = file_name,
            .original_size = original_size,
            .compressed_size = compressed_size,
            .checksum = checksum,
            .compressed = compressed,
        },
        .pos = name_pos,
    };
}

 
const testing = std.testing;

test "BackupHeader defaults" {
    const h = BackupHeader{ .timestamp = 1000, .component_count = 5, .total_size = 1024 };
    try testing.expectEqual(BACKUP_MAGIC, h.magic);
    try testing.expectEqual(BACKUP_VERSION, h.version);
    try testing.expectEqual(@as(i64, 1000), h.timestamp);
    try testing.expectEqual(@as(u32, 5), h.component_count);
    try testing.expectEqual(@as(u64, 1024), h.total_size);
    try testing.expectEqual(false, h.compressed);
}

test "BACKUP_MAGIC is 'BADB' in little-endian" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, BACKUP_MAGIC, .little);
    try testing.expectEqualSlices(u8, "BDAB", &buf);  
    
}

test "What enum values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(What.ValueLog));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(What.Index));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(What.Config));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(What.Wasm));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(What.Static));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(What.Binary));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(What.Log));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(What.Wal));
    try testing.expectEqual(@as(u8, 255), @intFromEnum(What.Other));
}

test "SectionHeader.dataSize switches by compressed flag" {
    const uncompressed = SectionHeader{
        .what = .ValueLog,
        .file_name_len = 10,
        .file_name = "test.vlog",
        .original_size = 1024,
        .compressed_size = 512,
        .checksum = 0,
        .compressed = false,
    };
    try testing.expectEqual(@as(u64, 1024), uncompressed.dataSize());

    const compressed = SectionHeader{
        .what = .ValueLog,
        .file_name_len = 10,
        .file_name = "test.vlog",
        .original_size = 1024,
        .compressed_size = 512,
        .checksum = 0,
        .compressed = true,
    };
    try testing.expectEqual(@as(u64, 512), compressed.dataSize());
}

test "fixed sizes" {
    try testing.expectEqual(@as(u64, 29), BACKUP_HEADER_SIZE);
    try testing.expectEqual(@as(usize, 26), SECTION_HEADER_FIXED_SIZE);
}
