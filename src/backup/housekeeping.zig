
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Now = @import("../time.zig").Now;

const log = std.log.scoped(.backup_housekeeping);

pub const BackupEntry = struct {
    path: []const u8,
    name: []const u8,
    timestamp_ms: i64,
    size_bytes: u64,
};

pub fn listBackups(allocator: Allocator, io: Io, backup_dir: []const u8) ![]BackupEntry {
    var dir = Dir.openDir(.cwd(), io, backup_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(BackupEntry, 0),
        else => return err,
    };
    defer dir.close(io);

    var list: std.ArrayList(BackupEntry) = .empty;
    errdefer {
        for (list.items) |e| {
            allocator.free(e.path);
            allocator.free(e.name);
        }
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ts = parseBackupTimestamp(entry.name) orelse continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup_dir, entry.name });
        errdefer allocator.free(full_path);

        var size: u64 = 0;
        if (Dir.openFile(.cwd(), io, full_path, .{ .mode = .read_only })) |f| {
            defer f.close(io);
            if (f.stat(io)) |s| size = s.size else |_| {}
        } else |_| {}

        try list.append(allocator, .{
            .path = full_path,
            .name = try allocator.dupe(u8, entry.name),
            .timestamp_ms = ts,
            .size_bytes = size,
        });
    }

    const slice = try list.toOwnedSlice(allocator);
    std.mem.sort(BackupEntry, slice, {}, struct {
        fn lt(_: void, a: BackupEntry, b: BackupEntry) bool {
            return a.timestamp_ms > b.timestamp_ms;
        }
    }.lt);
    return slice;
}

pub fn freeBackupList(allocator: Allocator, list: []BackupEntry) void {
    for (list) |e| {
        allocator.free(e.path);
        allocator.free(e.name);
    }
    allocator.free(list);
}

pub fn cleanupOldBackups(allocator: Allocator, io: Io, backup_dir: []const u8, keep_count: usize) !usize {
    const list = try listBackups(allocator, io, backup_dir);
    defer freeBackupList(allocator, list);

    if (list.len <= keep_count) return 0;

    var deleted: usize = 0;
    var i: usize = keep_count;
    while (i < list.len) : (i += 1) {
        Dir.cwd().deleteFile(io, list[i].path) catch |err| {
            log.warn("cleanupOldBackups: delete '{s}' failed: {}", .{ list[i].path, err });
            continue;
        };
        deleted += 1;
    }
    return deleted;
}

 
fn parseBackupTimestamp(name: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, name, "backup_")) return null;
    const after_prefix = name["backup_".len..];

     const dot = std.mem.indexOfScalar(u8, after_prefix, '.') orelse return null;
    const ts_str = after_prefix[0..dot];
    const ext = after_prefix[dot + 1 ..];

    if (!std.mem.eql(u8, ext, "tar.gz") and
        !std.mem.eql(u8, ext, "tgz") and
        !std.mem.eql(u8, ext, "zip") and
        !std.mem.eql(u8, ext, "planck"))
    {
        return null;
    }

    return std.fmt.parseInt(i64, ts_str, 10) catch null;
}

 
const testing = std.testing;

test "parseBackupTimestamp handles known extensions + rejects garbage" {
    try testing.expectEqual(@as(?i64, 12345), parseBackupTimestamp("backup_12345.tar.gz"));
    try testing.expectEqual(@as(?i64, 1700000000000), parseBackupTimestamp("backup_1700000000000.zip"));
    try testing.expectEqual(@as(?i64, 42), parseBackupTimestamp("backup_42.planck"));
    try testing.expectEqual(@as(?i64, null), parseBackupTimestamp("readme.txt"));
    try testing.expectEqual(@as(?i64, null), parseBackupTimestamp("backup_abc.tar.gz"));
    try testing.expectEqual(@as(?i64, null), parseBackupTimestamp("backup_42.unknown"));
    try testing.expectEqual(@as(?i64, null), parseBackupTimestamp("not_backup_42.tar.gz"));
}

test "listBackups returns sorted newest-first" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const ts = (Now{ .io = io }).toMilliSeconds();
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/utils-housekeeping-test-{d}", .{ts});
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.createDirPath(.cwd(), io, root);

    const f1 = try std.fmt.allocPrint(testing.allocator, "{s}/backup_100.tar.gz", .{root});
    defer testing.allocator.free(f1);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = f1, .data = "older" });

    const f2 = try std.fmt.allocPrint(testing.allocator, "{s}/backup_300.tar.gz", .{root});
    defer testing.allocator.free(f2);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = f2, .data = "newest" });

    const f3 = try std.fmt.allocPrint(testing.allocator, "{s}/backup_200.tar.gz", .{root});
    defer testing.allocator.free(f3);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = f3, .data = "middle" });

    const f4 = try std.fmt.allocPrint(testing.allocator, "{s}/readme.txt", .{root});
    defer testing.allocator.free(f4);
    try Dir.writeFile(.cwd(), io, .{ .sub_path = f4, .data = "ignored" });

    const list = try listBackups(testing.allocator, io, root);
    defer freeBackupList(testing.allocator, list);

    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(@as(i64, 300), list[0].timestamp_ms);
    try testing.expectEqual(@as(i64, 200), list[1].timestamp_ms);
    try testing.expectEqual(@as(i64, 100), list[2].timestamp_ms);
}

test "cleanupOldBackups deletes oldest, keeps N newest" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const ts = (Now{ .io = io }).toMilliSeconds();
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/utils-cleanup-test-{d}", .{ts});
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.createDirPath(.cwd(), io, root);

    inline for (.{ "100", "200", "300", "400", "500" }) |stamp| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/backup_{s}.tar.gz", .{ root, stamp });
        defer testing.allocator.free(p);
        try Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = "x" });
    }

    const deleted = try cleanupOldBackups(testing.allocator, io, root, 2);
    try testing.expectEqual(@as(usize, 3), deleted);

    const remaining = try listBackups(testing.allocator, io, root);
    defer freeBackupList(testing.allocator, remaining);
    try testing.expectEqual(@as(usize, 2), remaining.len);
    try testing.expectEqual(@as(i64, 500), remaining[0].timestamp_ms);
    try testing.expectEqual(@as(i64, 400), remaining[1].timestamp_ms);
}
