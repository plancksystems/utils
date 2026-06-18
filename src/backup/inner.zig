
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;

const format = @import("format.zig");

const log = std.log.scoped(.backup_inner);

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn createServiceArchive(allocator: Allocator, io: Io, output_path: []const u8, vlog_dir: []const u8, index_dir: []const u8, secondary_index_paths: []const []const u8, wal_dir: []const u8, now_ms: i64) !format.BackupMetadata {
    const backup_file = try Dir.createFile(.cwd(), io, output_path, .{ .read = false, .truncate = true });
    defer backup_file.close(io);

    var vlog_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (vlog_files.items) |p| allocator.free(p);
        vlog_files.deinit(allocator);
    }

    if (Dir.openDir(.cwd(), io, vlog_dir, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".vlog")) continue;
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ vlog_dir, entry.basename });
            try vlog_files.append(allocator, full);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var header = format.BackupHeader{
        .timestamp = now_ms,
        .component_count = 0,
        .total_size = 0,
    };
    var pos: u64 = try format.writeHeader(io, backup_file, header, 0);

    var total_entries: u64 = 0;
    var actual_count: u32 = 0;

    const addSection = struct {
        fn call(
            alloc: Allocator,
            io_: Io,
            bf: File,
            src_path: []const u8,
            rel: []const u8,
            what: format.What,
            pos_: *u64,
            actual_count_: *u32,
            total_entries_: *u64,
        ) !void {
            const prev = pos_.*;
            const r = try writeFileSection(alloc, io_, bf, src_path, rel, what, pos_.*);
            total_entries_.* += r.entries;
            pos_.* = r.pos;
            if (pos_.* != prev) actual_count_.* += 1;
        }
    }.call;

    std.mem.sort([]const u8, vlog_files.items, {}, lessThanStr);

    for (vlog_files.items) |vlog_path| {
        const basename = std.fs.path.basename(vlog_path);
        const rel = try std.fmt.allocPrint(allocator, "logs/{s}", .{basename});
        defer allocator.free(rel);
        try addSection(allocator, io, backup_file, vlog_path, rel, .ValueLog, &pos, &actual_count, &total_entries);
    }

    {
        const primary_src = try std.fmt.allocPrint(allocator, "{s}/primary.idx", .{index_dir});
        defer allocator.free(primary_src);
        try addSection(allocator, io, backup_file, primary_src, "indexes/primary.idx", .Index, &pos, &actual_count, &total_entries);
    }

    {
        const catalog_src = try std.fmt.allocPrint(allocator, "{s}/system.catalog.idx", .{index_dir});
        defer allocator.free(catalog_src);
        try addSection(allocator, io, backup_file, catalog_src, "indexes/system.catalog.idx", .Index, &pos, &actual_count, &total_entries);
    }

    for (secondary_index_paths) |src_path| {
        const basename = std.fs.path.basename(src_path);
        const rel = try std.fmt.allocPrint(allocator, "indexes/{s}", .{basename});
        defer allocator.free(rel);
        try addSection(allocator, io, backup_file, src_path, rel, .Index, &pos, &actual_count, &total_entries);
    }

    var wal_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (wal_files.items) |p| allocator.free(p);
        wal_files.deinit(allocator);
    }
    if (Dir.openDir(.cwd(), io, wal_dir, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const is_wal = std.mem.endsWith(u8, entry.basename, ".wal");
            const is_checkpoint = std.mem.eql(u8, entry.basename, "CHECKPOINT");
            if (!is_wal and !is_checkpoint) continue;
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wal_dir, entry.basename });
            try wal_files.append(allocator, full);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    std.mem.sort([]const u8, wal_files.items, {}, lessThanStr);
    for (wal_files.items) |wal_path| {
        const basename = std.fs.path.basename(wal_path);
        const rel = try std.fmt.allocPrint(allocator, "wals/{s}", .{basename});
        defer allocator.free(rel);
        try addSection(allocator, io, backup_file, wal_path, rel, .Wal, &pos, &actual_count, &total_entries);
    }

    header.total_size = pos;
    header.component_count = actual_count;
    _ = try format.writeHeader(io, backup_file, header, 0);

    return .{
        .backup_path = try allocator.dupe(u8, output_path),
        .timestamp = now_ms,
        .size_bytes = pos,
        .vlog_count = @intCast(vlog_files.items.len),
        .entry_count = total_entries,
    };
}

pub fn restoreInnerArchive(allocator: Allocator, io: Io, archive_path: []const u8, target_dir: []const u8) !format.BackupMetadata {
    const file = try Dir.openFile(.cwd(), io, archive_path, .{ .mode = .read_only });
    defer file.close(io);

    var pos: u64 = 0;
    const hdr_r = try format.readHeader(io, file, pos);
    const header = hdr_r.header;
    pos = hdr_r.pos;

    if (header.magic != format.BACKUP_MAGIC) return format.FormatError.InvalidBackupFile;
    if (header.version != format.BACKUP_VERSION) return format.FormatError.IncompatibleBackupVersion;

    try Dir.createDirPath(.cwd(), io, target_dir);

    var total_entries: u64 = 0;
    var vlog_count: u16 = 0;

    var i: u32 = 0;
    while (i < header.component_count) : (i += 1) {
        const sh_r = try format.readSectionHeader(allocator, io, file, pos);
        pos = sh_r.pos;
        const sh = sh_r.header;
        defer allocator.free(sh.file_name);

        const data_size = sh.dataSize();
        const data = try allocator.alloc(u8, data_size);
        defer allocator.free(data);
        _ = try file.readPositionalAll(io, data, pos);
        pos += data_size;

        if (!sh.compressed) {
            const computed = std.hash.Crc32.hash(data);
            if (computed != sh.checksum) {
                log.err("restoreInnerArchive: CRC mismatch on '{s}' (expected {x}, got {x})", .{ sh.file_name, sh.checksum, computed });
                return format.FormatError.ChecksumMismatch;
            }
        }

        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_dir, sh.file_name });
        defer allocator.free(out_path);
        if (std.fs.path.dirname(out_path)) |parent| {
            Dir.createDirPath(.cwd(), io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        const out = try Dir.createFile(.cwd(), io, out_path, .{ .truncate = true });
        defer out.close(io);
        try out.writePositionalAll(io, data, 0);

        if (sh.what == .ValueLog) {
            vlog_count += 1;
            total_entries += data.len / 64;
        }
    }

    return .{
        .backup_path = try allocator.dupe(u8, archive_path),
        .timestamp = header.timestamp,
        .size_bytes = header.total_size,
        .vlog_count = vlog_count,
        .entry_count = total_entries,
    };
}

const SectionWrite = struct { entries: u64, pos: u64 };

fn writeFileSection(allocator: Allocator, io: Io, backup_file: File, file_path: []const u8, relative_name: []const u8, what: format.What, pos: u64) !SectionWrite {
    const src = Dir.openFile(.cwd(), io, file_path, .{ .mode = .read_only }) catch return .{ .entries = 0, .pos = pos };
    defer src.close(io);

    const stat = try src.stat(io);
    const sz = stat.size;
    if (sz == 0) return .{ .entries = 0, .pos = pos };

    const bytes = try allocator.alloc(u8, sz);
    defer allocator.free(bytes);
    _ = try src.readPositionalAll(io, bytes, 0);

    const sh = format.SectionHeader{
        .what = what,
        .file_name_len = @intCast(relative_name.len),
        .file_name = relative_name,
        .original_size = sz,
        .compressed_size = sz,
        .checksum = std.hash.Crc32.hash(bytes),
        .compressed = false,
    };

    var next = try format.writeSectionHeader(io, backup_file, sh, pos);
    try backup_file.writePositionalAll(io, bytes, next);
    next += sz;

    const entries: u64 = if (what == .ValueLog) sz / 64 else 0;
    return .{ .entries = entries, .pos = next };
}

const testing = std.testing;
const Now = @import("../time.zig").Now;

test "write fake service archive, read it back, verify file contents" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_dir_name_buf: [128]u8 = undefined;
     const ts = (Now{ .io = io }).toMilliSeconds();
    const tmp_root = try std.fmt.bufPrint(&tmp_dir_name_buf, "/tmp/utils-backup-test-{d}", .{ts});

    const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{tmp_root});
    defer testing.allocator.free(data_dir);
    const vlog_dir = try std.fmt.allocPrint(testing.allocator, "{s}/logs", .{data_dir});
    defer testing.allocator.free(vlog_dir);
    const index_dir = try std.fmt.allocPrint(testing.allocator, "{s}/indexes", .{data_dir});
    defer testing.allocator.free(index_dir);
    const wal_dir = try std.fmt.allocPrint(testing.allocator, "{s}/wals", .{data_dir});
    defer testing.allocator.free(wal_dir);
    try Dir.createDirPath(.cwd(), io, vlog_dir);
    try Dir.createDirPath(.cwd(), io, index_dir);
    try Dir.createDirPath(.cwd(), io, wal_dir);

    const vlog0_path = try std.fmt.allocPrint(testing.allocator, "{s}/0.vlog", .{vlog_dir});
    defer testing.allocator.free(vlog0_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = vlog0_path, .data = "VLOG0 contents" });

    const vlog1_path = try std.fmt.allocPrint(testing.allocator, "{s}/1.vlog", .{vlog_dir});
    defer testing.allocator.free(vlog1_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = vlog1_path, .data = "VLOG1 contents — slightly longer" });

    const primary_path = try std.fmt.allocPrint(testing.allocator, "{s}/primary.idx", .{index_dir});
    defer testing.allocator.free(primary_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = primary_path, .data = "PRIMARY INDEX BYTES" });

    const catalog_path = try std.fmt.allocPrint(testing.allocator, "{s}/system.catalog.idx", .{index_dir});
    defer testing.allocator.free(catalog_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = catalog_path, .data = "CATALOG INDEX BYTES" });

    const sec1_path = try std.fmt.allocPrint(testing.allocator, "{s}/by_title.idx", .{index_dir});
    defer testing.allocator.free(sec1_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = sec1_path, .data = "SECONDARY INDEX BY_TITLE" });

    const wal0_path = try std.fmt.allocPrint(testing.allocator, "{s}/000000.wal", .{wal_dir});
    defer testing.allocator.free(wal0_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = wal0_path, .data = "WAL SEGMENT 0 contents" });

    const checkpoint_path = try std.fmt.allocPrint(testing.allocator, "{s}/CHECKPOINT", .{wal_dir});
    defer testing.allocator.free(checkpoint_path);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = checkpoint_path, .data = "CHECKPOINT marker" });

    const archive_path = try std.fmt.allocPrint(testing.allocator, "{s}/backup.planck", .{tmp_root});
    defer testing.allocator.free(archive_path);

    const secondaries = [_][]const u8{sec1_path};
    const meta = try createServiceArchive(
        testing.allocator,
        io,
        archive_path,
        vlog_dir,
        index_dir,
        &secondaries,
        wal_dir,
        ts,
    );
    defer testing.allocator.free(meta.backup_path);

    try testing.expectEqual(@as(u16, 2), meta.vlog_count);
    try testing.expect(meta.size_bytes > format.BACKUP_HEADER_SIZE);

    const restore_dir = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{tmp_root});
    defer testing.allocator.free(restore_dir);

    const r_meta = try restoreInnerArchive(testing.allocator, io, archive_path, restore_dir);
    defer testing.allocator.free(r_meta.backup_path);

    try testing.expectEqual(@as(u16, 2), r_meta.vlog_count);
    try testing.expectEqual(meta.timestamp, r_meta.timestamp);

    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/logs/0.vlog", .{restore_dir});
        defer testing.allocator.free(p);
        const restored_vlog0 = try Dir.readFileAlloc(.cwd(), io, p, testing.allocator, .unlimited);
        defer testing.allocator.free(restored_vlog0);
        try testing.expectEqualStrings("VLOG0 contents", restored_vlog0);
    }

    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/indexes/by_title.idx", .{restore_dir});
        defer testing.allocator.free(p);
        const restored_secondary = try Dir.readFileAlloc(.cwd(), io, p, testing.allocator, .unlimited);
        defer testing.allocator.free(restored_secondary);
        try testing.expectEqualStrings("SECONDARY INDEX BY_TITLE", restored_secondary);
    }

    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/wals/000000.wal", .{restore_dir});
        defer testing.allocator.free(p);
        const restored_wal = try Dir.readFileAlloc(.cwd(), io, p, testing.allocator, .unlimited);
        defer testing.allocator.free(restored_wal);
        try testing.expectEqualStrings("WAL SEGMENT 0 contents", restored_wal);
    }
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/wals/CHECKPOINT", .{restore_dir});
        defer testing.allocator.free(p);
        const restored_cp = try Dir.readFileAlloc(.cwd(), io, p, testing.allocator, .unlimited);
        defer testing.allocator.free(restored_cp);
        try testing.expectEqualStrings("CHECKPOINT marker", restored_cp);
    }

    var tmp_cwd = Dir.cwd();
    tmp_cwd.deleteTree(io, tmp_root) catch {};
}

test "restoreInnerArchive rejects bad magic" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

     const ts = (Now{ .io = io }).toMilliSeconds();
    const path = try std.fmt.allocPrint(testing.allocator, "/tmp/utils-backup-bad-{d}.planck", .{ts});
    defer testing.allocator.free(path);

    var zeros: [29]u8 = .{0} ** 29;
    try Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = &zeros });
    defer (Dir.cwd()).deleteFile(io, path) catch {};

    try testing.expectError(format.FormatError.InvalidBackupFile, restoreInnerArchive(testing.allocator, io, path, "/tmp/utils-backup-bad-out"));
}

test "restoreInnerArchive rejects incompatible version" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const ts = (Now{ .io = io }).toMilliSeconds();
    const path = try std.fmt.allocPrint(testing.allocator, "/tmp/utils-backup-ver-{d}.planck", .{ts});
    defer testing.allocator.free(path);

    var buf: [29]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], format.BACKUP_MAGIC, .little);
    buf[4] = 99;
    std.mem.writeInt(i64, buf[5..13], 0, .little);
    std.mem.writeInt(u32, buf[13..17], 0, .little);
    std.mem.writeInt(u64, buf[17..25], 0, .little);
    buf[25] = 0;
    buf[26] = 0;
    buf[27] = 0;
    buf[28] = 0;
    try Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = &buf });
    defer (Dir.cwd()).deleteFile(io, path) catch {};

    try testing.expectError(format.FormatError.IncompatibleBackupVersion, restoreInnerArchive(testing.allocator, io, path, "/tmp/utils-backup-ver-out"));
}
