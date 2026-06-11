
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const inner = @import("inner.zig");
const format = @import("format.zig");
const container_mod = @import("container/root.zig");

const log = std.log.scoped(.backup_orchestrate);

pub const ServiceQuiesce = struct {
    name: []const u8,
    ctx: ?*anyopaque = null,
    quiesce: *const fn (
        ctx: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        service_name: []const u8,
        output_dir: []const u8,
    ) anyerror!void,
};

pub const CreateOptions = struct {
    app_dir: []const u8,

    output_path: []const u8,
    format: container_mod.ContainerFormat = .tar_gz,
    services: []const ServiceQuiesce,

    staging_dir: []const u8,
};

pub const CreateResult = struct {
    output_path: []const u8,
    bytes: u64,
    services_captured: u32,
};

pub fn createAppArchive(allocator: Allocator, io: Io, opts: CreateOptions) !CreateResult {
    Dir.cwd().deleteTree(io, opts.staging_dir) catch {};
    try Dir.createDirPath(.cwd(), io, opts.staging_dir);

    try mirrorAppDir(allocator, io, opts.app_dir, opts.staging_dir, opts.services);

    for (opts.services) |svc| {
        const svc_staging = try std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ opts.staging_dir, svc.name });
        defer allocator.free(svc_staging);
        try Dir.createDirPath(.cwd(), io, svc_staging);
        svc.quiesce(svc.ctx, allocator, io, svc.name, svc_staging) catch |err| {
            log.err("createAppArchive: quiesce '{s}' failed: {}", .{ svc.name, err });
            Dir.cwd().deleteTree(io, opts.staging_dir) catch {};
            return err;
        };
    }

    try container_mod.create(io, opts.format, opts.staging_dir, opts.output_path);

    var bytes: u64 = 0;
    if (Dir.openFile(.cwd(), io, opts.output_path, .{ .mode = .read_only })) |f| {
        defer f.close(io);
        if (f.stat(io)) |s| bytes = s.size else |_| {}
    } else |_| {}

    Dir.cwd().deleteTree(io, opts.staging_dir) catch {};

    return .{
        .output_path = try allocator.dupe(u8, opts.output_path),
        .bytes = bytes,
        .services_captured = @intCast(opts.services.len),
    };
}

pub const PlistCheckCallback = struct {
    ctx: ?*anyopaque = null,
    check: *const fn (ctx: ?*anyopaque, label: []const u8) anyerror!void,
};

pub const BootstrapCallback = struct {
    ctx: ?*anyopaque = null,
    bootstrap: *const fn (ctx: ?*anyopaque, app_name: []const u8) anyerror!void,
};

pub const RestoreOptions = struct {
    archive_path: []const u8,
    target_app_dir: []const u8,
    format: ?container_mod.ContainerFormat = null,
    service_filter: ?[]const u8 = null,
    wipe_before_extract: bool = true,
    app_name: []const u8 = "",
    staging_dir: []const u8,
};

pub const RestoreResult = struct {
    app_name: []const u8,
    services_restored: u32,
};

pub fn restoreAppArchive(allocator: Allocator, io: Io, opts: RestoreOptions) !RestoreResult {
    const fmt = opts.format orelse (container_mod.ContainerFormat.fromExtension(opts.archive_path) orelse return error.UnknownArchiveFormat);

    const app_name = if (opts.app_name.len > 0) opts.app_name else std.fs.path.basename(opts.target_app_dir);

    if (opts.wipe_before_extract and opts.service_filter == null) {
        Dir.cwd().deleteTree(io, opts.target_app_dir) catch {};
    }
    try Dir.createDirPath(.cwd(), io, opts.target_app_dir);

    Dir.cwd().deleteTree(io, opts.staging_dir) catch {};
    try Dir.createDirPath(.cwd(), io, opts.staging_dir);
    try container_mod.extract(io, fmt, opts.archive_path, opts.staging_dir);

    var services_restored: u32 = 0;
    try copyTree(allocator, io, opts.staging_dir, opts.target_app_dir, opts.service_filter, &services_restored);

    try expandInnerArchives(allocator, io, opts.target_app_dir, opts.service_filter);

    Dir.cwd().deleteTree(io, opts.staging_dir) catch {};

    return .{
        .app_name = try allocator.dupe(u8, app_name),
        .services_restored = services_restored,
    };
}

fn mirrorAppDir(allocator: Allocator, io: Io, app_dir: []const u8, staging_dir: []const u8, services: []const ServiceQuiesce) !void {
    const src_glob = try std.fmt.allocPrint(allocator, "{s}/.", .{app_dir});
    defer allocator.free(src_glob);
    try runShell(io, &.{ "cp", "-a", src_glob, staging_dir });

    for (services) |svc| {
        for ([_][]const u8{ "logs", "indexes", "wals" }) |sub| {
            const path = try std.fmt.allocPrint(allocator, "{s}/services/{s}/{s}", .{ staging_dir, svc.name, sub });
            defer allocator.free(path);
            Dir.cwd().deleteTree(io, path) catch {};
        }
    }
}

fn runShell(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            log.err("shell command failed: argv={any} exit_code={d}", .{ argv, code });
            return error.ShellCommandFailed;
        },
        else => return error.ShellCommandFailed,
    }
}

fn shouldSkipForBackup(path: []const u8, services: []const ServiceQuiesce) bool {
    if (!std.mem.startsWith(u8, path, "services/")) return false;
    const after_services = path["services/".len..];
    const slash = std.mem.indexOfScalar(u8, after_services, '/') orelse return false;
    const svc_name = after_services[0..slash];

    var known = false;
    for (services) |s| {
        if (std.mem.eql(u8, s.name, svc_name)) {
            known = true;
            break;
        }
    }
    if (!known) return false;

    const rest = after_services[slash + 1 ..];
    return std.mem.startsWith(u8, rest, "logs/") or
        std.mem.startsWith(u8, rest, "indexes/") or
        std.mem.startsWith(u8, rest, "wals/");
}

fn copyTree(allocator: Allocator, io: Io, src_dir: []const u8, dst_dir: []const u8, service_filter: ?[]const u8, services_restored: *u32) !void {
    if (service_filter) |f| {
        const src_svc = try std.fmt.allocPrint(allocator, "{s}/services/{s}/.", .{ src_dir, f });
        defer allocator.free(src_svc);
        const dst_svc_parent = try std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ dst_dir, f });
        defer allocator.free(dst_svc_parent);
        try Dir.createDirPath(.cwd(), io, dst_svc_parent);
        try runShell(io, &.{ "cp", "-a", src_svc, dst_svc_parent });
        services_restored.* = 1;
        return;
    }

    const src_glob = try std.fmt.allocPrint(allocator, "{s}/.", .{src_dir});
    defer allocator.free(src_glob);
    try runShell(io, &.{ "cp", "-a", src_glob, dst_dir });

    const services_path = try std.fmt.allocPrint(allocator, "{s}/services", .{src_dir});
    defer allocator.free(services_path);
    if (Dir.openDir(.cwd(), io, services_path, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) services_restored.* += 1;
        }
    } else |_| {}
}

fn expandInnerArchives(allocator: Allocator, io: Io, app_dir: []const u8, service_filter: ?[]const u8) !void {
    const services_dir = try std.fmt.allocPrint(allocator, "{s}/services", .{app_dir});
    defer allocator.free(services_dir);

    var dir = Dir.openDir(.cwd(), io, services_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (service_filter) |f| {
            if (!std.mem.eql(u8, entry.name, f)) continue;
        }
        const svc_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ services_dir, entry.name });
        defer allocator.free(svc_dir);
        const archive = try std.fmt.allocPrint(allocator, "{s}/data.planck", .{svc_dir});
        defer allocator.free(archive);
        if (Dir.openFile(.cwd(), io, archive, .{ .mode = .read_only })) |f| {
            f.close(io);
        } else |_| {
            continue;
        }

        const m = try inner.restoreInnerArchive(allocator, io, archive, svc_dir);
        allocator.free(m.backup_path);
        Dir.deleteFile(.cwd(), io, archive) catch {};
    }
}

const testing = std.testing;

const FakeService = struct {
    bytes: []const u8,
    fn quiesce(ctx: ?*anyopaque, allocator: Allocator, io: Io, service_name: []const u8, output_dir: []const u8) anyerror!void {
        _ = service_name;
        const self: *const FakeService = @ptrCast(@alignCast(ctx.?));
        const path = try std.fmt.allocPrint(allocator, "{s}/data.planck", .{output_dir});
        defer allocator.free(path);
        try Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = self.bytes });
    }
};

test "createAppArchive packages app_dir + per-service quiesce output" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const Now = @import("../time.zig").Now;
    const ts = (Now{ .io = io }).toMilliSeconds();

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/utils-orchestrate-test-{d}", .{ts});
    defer Dir.cwd().deleteTree(io, root) catch {};

    const app_dir = try std.fmt.allocPrint(testing.allocator, "{s}/app", .{root});
    defer testing.allocator.free(app_dir);
    const staging = try std.fmt.allocPrint(testing.allocator, "{s}/staging", .{root});
    defer testing.allocator.free(staging);
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/out.tar.gz", .{root});
    defer testing.allocator.free(out);

    try Dir.createDirPath(.cwd(), io, app_dir);

    // App-level + service-level + live engine dirs (should be skipped).
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/app.yaml", .{app_dir});
        defer testing.allocator.free(p);
        try Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = "name: testapp\n" });
    }
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/services/svc1/db.yaml", .{app_dir});
        defer testing.allocator.free(p);
        if (std.fs.path.dirname(p)) |parent| try Dir.createDirPath(.cwd(), io, parent);
        try Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = "port: 24000\n" });
    }
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/services/svc1/logs/0.vlog", .{app_dir});
        defer testing.allocator.free(p);
        if (std.fs.path.dirname(p)) |parent| try Dir.createDirPath(.cwd(), io, parent);
        try Dir.writeFile(.cwd(), io, .{ .sub_path = p, .data = "LIVE VLOG (should be replaced)" });
    }

    var fake = FakeService{ .bytes = "QUIESCED data.planck bytes" };
    const services = [_]ServiceQuiesce{.{
        .name = "svc1",
        .ctx = @ptrCast(&fake),
        .quiesce = FakeService.quiesce,
    }};

    const r = try createAppArchive(testing.allocator, io, .{
        .app_dir = app_dir,
        .output_path = out,
        .format = .tar_gz,
        .services = &services,
        .staging_dir = staging,
    });
    defer testing.allocator.free(r.output_path);

    try testing.expect(r.bytes > 0);
    try testing.expectEqual(@as(u32, 1), r.services_captured);

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored", .{root});
    defer testing.allocator.free(target);

    try Dir.createDirPath(.cwd(), io, target);
    try container_mod.extract(io, .tar_gz, out, target);

    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/app.yaml", .{target});
        defer testing.allocator.free(p);
        const data = try Dir.readFileAlloc(.cwd(), io, p, testing.allocator, .unlimited);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("name: testapp\n", data);
    }
    {
        const dp = try std.fmt.allocPrint(testing.allocator, "{s}/services/svc1/data.planck", .{target});
        defer testing.allocator.free(dp);
        const data = try Dir.readFileAlloc(.cwd(), io, dp, testing.allocator, .unlimited);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("QUIESCED data.planck bytes", data);
    }
    {
        const live = try std.fmt.allocPrint(testing.allocator, "{s}/services/svc1/logs/0.vlog", .{target});
        defer testing.allocator.free(live);
        const r2 = Dir.openFile(.cwd(), io, live, .{ .mode = .read_only });
        try testing.expect(std.meta.isError(r2));
    }
}
