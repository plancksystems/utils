
const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.backup_tar);

pub fn create(io: Io, src_dir: []const u8, output_path: []const u8) !void {
    const argv: []const []const u8 = &.{
        "tar",
        "-czf",
        output_path,
        "-C",
        src_dir,
        ".",
    };
    try runCmd(io, argv);
}

pub fn extract(io: Io, archive_path: []const u8, target_dir: []const u8) !void {
    const argv: []const []const u8 = &.{
        "tar",
        "-xzf",
        archive_path,
        "-C",
        target_dir,
    };
    try runCmd(io, argv);
}

fn runCmd(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            log.err("tar command failed: argv={any} exit_code={d}", .{ argv, code });
            return error.ArchiveCommandFailed;
        },
        else => return error.ArchiveCommandFailed,
    }
}

const testing = std.testing;

test "tar.gz  preserves file tree + contents" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const Now = @import("../../time.zig").Now;
    const ts = (Now{ .io = io }).toMilliSeconds();

    var tmp_root_buf: [128]u8 = undefined;
    const tmp_root = try std.fmt.bufPrint(&tmp_root_buf, "/tmp/utils-tar-test-{d}", .{ts});
    defer (Io.Dir.cwd()).deleteTree(io, tmp_root) catch {};

    const src = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{tmp_root});
    defer testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst);
    const archive = try std.fmt.allocPrint(testing.allocator, "{s}/out.tar.gz", .{tmp_root});
    defer testing.allocator.free(archive);

    try Io.Dir.createDirPath(.cwd(), io, src);
    try Io.Dir.createDirPath(.cwd(), io, dst);

    const sub = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{src});
    defer testing.allocator.free(sub);
    try Io.Dir.createDirPath(.cwd(), io, sub);

    const a_path = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{src});
    defer testing.allocator.free(a_path);
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = a_path, .data = "hello A" });

    const b_path = try std.fmt.allocPrint(testing.allocator, "{s}/b.bin", .{sub});
    defer testing.allocator.free(b_path);
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = b_path, .data = "binary payload\x00\x01\x02" });

    try create(io, src, archive);
    try extract(io, archive, dst);

    {
        const restored_a = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{dst});
        defer testing.allocator.free(restored_a);
        const data = try Io.Dir.readFileAlloc(.cwd(), io, restored_a, testing.allocator, .unlimited);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("hello A", data);
    }
    {
        const restored_b = try std.fmt.allocPrint(testing.allocator, "{s}/sub/b.bin", .{dst});
        defer testing.allocator.free(restored_b);
        const data = try Io.Dir.readFileAlloc(.cwd(), io, restored_b, testing.allocator, .unlimited);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("binary payload\x00\x01\x02", data);
    }
}
