
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const ServiceState = enum {
    running,
    stopped,
    crashed,
    not_loaded,
    unknown,
};

pub const ServiceStatus = struct {
    state: ServiceState,
    pid: ?i32 = null,
    exit_code: ?i32 = null,
};

pub const RegisterOptions = struct {
    name: []const u8,
    binary: []const u8,
    workdir: []const u8,
    description: ?[]const u8 = null,
    args: []const []const u8 = &.{"run"},
    stdout_log: ?[]const u8 = null,
    stderr_log: ?[]const u8 = null,
    keep_alive: bool = true,
    run_at_load: bool = true,
};

pub const ServiceControl = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ServiceControl {
        return ServiceControl{ .allocator = allocator };
    }

    pub fn start(self: *ServiceControl, io: Io, name: []const u8) !void {
        switch (builtin.os.tag) {
            .linux => {
                try runCmd(io, &.{ "systemctl", "enable", "--now", name });
            },
            .macos => {
                const service = try std.fmt.allocPrint(self.allocator, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer self.allocator.free(service);
                try runCmd(io, &.{ "launchctl", "bootstrap", "system", service });
            },
            .windows => {
                try runCmd(io, &.{ "sc.exe", "start", name });
            },
            else => return error.UnsupportedOS,
        }
    }

    pub fn stop(self: *ServiceControl, io: Io, name: []const u8) !void {
        switch (builtin.os.tag) {
            .linux => {
                try runCmd(io, &.{ "systemctl", "stop", name });
            },
            .macos => {
                const service = try std.fmt.allocPrint(self.allocator, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer self.allocator.free(service);
                try runCmd(io, &.{ "launchctl", "bootout", "system", service });
            },
            .windows => {
                try runCmd(io, &.{ "sc.exe", "stop", name });
            },
            else => return error.UnsupportedOS,
        }
    }

    pub fn restart(self: *ServiceControl, io: Io, name: []const u8) !void {
        switch (builtin.os.tag) {
            .linux => {
                try runCmd(io, &.{ "systemctl", "restart", name });
            },
            .macos => {
                 const target = try std.fmt.allocPrint(self.allocator, "system/{s}", .{name});
                defer self.allocator.free(target);
                try runCmd(io, &.{ "launchctl", "kickstart", "-k", target });
            },
            .windows => {
                runCmd(io, &.{ "sc.exe", "stop", name }) catch {};
                try runCmd(io, &.{ "sc.exe", "start", name });
            },
            else => return error.UnsupportedOS,
        }
    }

    pub fn register(self: *ServiceControl, io: Io, opts: RegisterOptions) !void {
        switch (builtin.os.tag) {
            .macos => try self.registerMacOsService(io, opts),
            .linux => try self.registerLinuxService(io, opts),
            .windows => try self.registerWindowsService(io, opts),
            else => return error.UnsupportedOS,
        }
    }

    pub fn unregister(self: *ServiceControl, io: Io, name: []const u8) !void {
        switch (builtin.os.tag) {
            .linux => {
                runCmd(io, &.{ "systemctl", "disable", name }) catch {};
                const service = try std.fmt.allocPrint(self.allocator, "/etc/systemd/system/{s}.service", .{name});
                defer self.allocator.free(service);

                Io.Dir.deleteFileAbsolute(io, service) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                try runCmd(io, &.{ "systemctl", "daemon-reload" });
            },
            .macos => {
                const service = try std.fmt.allocPrint(self.allocator, "/Library/LaunchDaemons/{s}.plist", .{name});
                defer self.allocator.free(service);
                Io.Dir.deleteFileAbsolute(io, service) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            },
            .windows => try runCmd(io, &.{ "sc.exe", "delete", name }),
            else => return error.UnsupportedOS,
        }
    }

    pub fn status(self: *ServiceControl, io: Io, name: []const u8) !ServiceStatus {
        switch (builtin.os.tag) {
            .linux => return try self.statusLinux(io, name),
            .macos => return try self.statusMacOs(io, name),
            .windows => return try self.statusWindows(io, name),
            else => return error.UnsupportedOS,
        }
    }

    pub fn listMatching(self: *ServiceControl, io: Io, prefix: []const u8) ![][]const u8 {
        switch (builtin.os.tag) {
            .linux => return try self.listLinux(io, prefix),
            .macos => return try self.listMacOs(io, prefix),
            .windows => return try self.listWindows(io, prefix),
            else => return error.UnsupportedOS,
        }
    }

    fn listLinux(self: *ServiceControl, io: Io, prefix: []const u8) ![][]const u8 {
        return try self.listDiskBased(io, "/etc/systemd/system", prefix, ".service");
    }

    fn listMacOs(self: *ServiceControl, io: Io, prefix: []const u8) ![][]const u8 {
        return try self.listDiskBased(io, "/Library/LaunchDaemons", prefix, ".plist");
    }

    fn listWindows(self: *ServiceControl, io: Io, prefix: []const u8) ![][]const u8 {
         const result = std.process.run(self.allocator, io, .{
            .argv = &.{ "sc.exe", "query", "type=", "service", "state=", "all" },
        }) catch {
            return try self.allocator.alloc([]const u8, 0);
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            const tag = "SERVICE_NAME:";
            if (!std.mem.startsWith(u8, line, tag)) continue;
            const name = std.mem.trim(u8, line[tag.len..], " \t\r");
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            try names.append(self.allocator, try self.allocator.dupe(u8, name));
        }

        return try names.toOwnedSlice(self.allocator);
    }

    fn listDiskBased(self: *ServiceControl, io: Io, dir_path: []const u8, prefix: []const u8, suffix: []const u8) ![][]const u8 {
        var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            return try self.allocator.alloc([]const u8, 0);
        };
        defer dir.close(io);

        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
            const stem_len = entry.name.len - suffix.len;
            try names.append(self.allocator, try self.allocator.dupe(u8, entry.name[0..stem_len]));
        }

        return try names.toOwnedSlice(self.allocator);
    }

 
    fn registerLinuxService(self: *ServiceControl, io: Io, opts: RegisterOptions) !void {
        const unit_path = try std.fmt.allocPrint(self.allocator, "/etc/systemd/system/{s}.service", .{opts.name});
        defer self.allocator.free(unit_path);

        const description = try self.resolveDescription(opts);
        defer self.allocator.free(description);

         const exec_start = try joinArgs(self.allocator, opts.binary, opts.args);
        defer self.allocator.free(exec_start);

        const unit = try std.fmt.allocPrint(self.allocator,
            \\[Unit]
            \\Description={s}
            \\After=network.target
            \\Documentation=https://plancks.io
            \\
            \\[Service]
            \\Type=simple
            \\WorkingDirectory={s}
            \\ExecStart={s}
            \\Restart={s}
            \\RestartSec=5
            \\LimitNOFILE=65535
            \\
            \\ProtectSystem=strict
            \\ProtectHome=true
            \\ReadWritePaths={s}
            \\PrivateTmp=true
            \\NoNewPrivileges=true
            \\
            \\[Install]
            \\WantedBy=multi-user.target
            \\
        , .{
            description,
            opts.workdir,
            exec_start,
            if (opts.keep_alive) "on-failure" else "no",
            opts.workdir,
        });
        defer self.allocator.free(unit);
        try writeFile(unit_path, io, unit);
        try runCmd(io, &.{ "systemctl", "daemon-reload" });
    }

 
    fn registerMacOsService(self: *ServiceControl, io: Io, opts: RegisterOptions) !void {
        const plist_path = try std.fmt.allocPrint(self.allocator, "/Library/LaunchDaemons/{s}.plist", .{opts.name});
        defer self.allocator.free(plist_path);

        const description = try self.resolveDescription(opts);
        defer self.allocator.free(description);

        const stdout_path = if (opts.stdout_log) |p|
            try self.allocator.dupe(u8, p)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.out.log", .{ opts.workdir, opts.name });
        defer self.allocator.free(stdout_path);

        const stderr_path = if (opts.stderr_log) |p|
            try self.allocator.dupe(u8, p)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.err.log", .{ opts.workdir, opts.name });
        defer self.allocator.free(stderr_path);

         var args_xml: std.ArrayList(u8) = .empty;
        defer args_xml.deinit(self.allocator);
        try args_xml.appendSlice(self.allocator, "<string>");
        try args_xml.appendSlice(self.allocator, opts.binary);
        try args_xml.appendSlice(self.allocator, "</string>");
        for (opts.args) |a| {
            try args_xml.appendSlice(self.allocator, "<string>");
            try args_xml.appendSlice(self.allocator, a);
            try args_xml.appendSlice(self.allocator, "</string>");
        }

        const keep_alive_block = if (opts.keep_alive)
            \\    <key>KeepAlive</key>
            \\    <dict>
            \\        <key>SuccessfulExit</key>
            \\        <false/>
            \\    </dict>
        else
            "";

        const run_at_load_block = if (opts.run_at_load)
            \\    <key>RunAtLoad</key>
            \\    <true/>
        else
            "";

        const plist = try std.fmt.allocPrint(self.allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>Label</key>
            \\    <string>{s}</string>
            \\    <key>ServiceDescription</key>
            \\    <string>{s}</string>
            \\    <key>ProgramArguments</key>
            \\    <array>{s}</array>
            \\    <key>WorkingDirectory</key>
            \\    <string>{s}</string>
            \\{s}
            \\{s}
            \\    <key>StandardOutPath</key>
            \\    <string>{s}</string>
            \\    <key>StandardErrorPath</key>
            \\    <string>{s}</string>
            \\</dict>
            \\</plist>
            \\
        , .{
            opts.name,
            description,
            args_xml.items,
            opts.workdir,
            run_at_load_block,
            keep_alive_block,
            stdout_path,
            stderr_path,
        });
        defer self.allocator.free(plist);
        try writeFile(plist_path, io, plist);
    }

 
    fn registerWindowsService(self: *ServiceControl, io: Io, opts: RegisterOptions) !void {
        const description = try self.resolveDescription(opts);
        defer self.allocator.free(description);

         const cmd_line = try joinArgs(self.allocator, opts.binary, opts.args);
        defer self.allocator.free(cmd_line);

        const bin_path_arg = try std.fmt.allocPrint(self.allocator, "binPath={s}", .{cmd_line});
        defer self.allocator.free(bin_path_arg);

        const desc_arg = try std.fmt.allocPrint(self.allocator, "DisplayName={s}", .{description});
        defer self.allocator.free(desc_arg);

        const start_arg: []const u8 = if (opts.run_at_load) "start=auto" else "start=demand";

        try runCmd(io, &.{
            "sc.exe",     "create",
            opts.name,    bin_path_arg,
            start_arg,    desc_arg,
        });
    }

 
    fn statusLinux(self: *ServiceControl, io: Io, name: []const u8) !ServiceStatus {
        const result = std.process.run(self.allocator, io, .{
            .argv = &.{ "systemctl", "show", "-p", "MainPID,ActiveState,SubState,ExecMainStatus", name },
        }) catch {
            return .{ .state = .not_loaded };
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited != 0) {
            return .{ .state = .not_loaded };
        }
        return parseSystemctlShow(result.stdout);
    }

 
    fn statusMacOs(self: *ServiceControl, io: Io, name: []const u8) !ServiceStatus {
        const target = try std.fmt.allocPrint(self.allocator, "system/{s}", .{name});
        defer self.allocator.free(target);

        const result = std.process.run(self.allocator, io, .{
            .argv = &.{ "launchctl", "print", target },
        }) catch {
            return .{ .state = .not_loaded };
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited != 0) {
            return .{ .state = .not_loaded };
        }
        return parseLaunchctlPrint(result.stdout);
    }

 
    fn statusWindows(self: *ServiceControl, io: Io, name: []const u8) !ServiceStatus {
        const result = std.process.run(self.allocator, io, .{
            .argv = &.{ "sc.exe", "queryex", name },
        }) catch {
            return .{ .state = .not_loaded };
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited != 0) {
            return .{ .state = .not_loaded };
        }
        return parseScQueryex(result.stdout);
    }

 
    fn resolveDescription(self: *ServiceControl, opts: RegisterOptions) ![]u8 {
        if (opts.description) |d| {
            if (d.len > 0) return try self.allocator.dupe(u8, d);
        }
        return try std.fmt.allocPrint(self.allocator, "Planck service: {s}", .{opts.name});
    }
};

 fn joinArgs(allocator: std.mem.Allocator, binary: []const u8, args: []const []const u8) ![]u8 {
    var total: usize = binary.len;
    for (args) |a| total += 1 + a.len;

    const buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    @memcpy(buf[i .. i + binary.len], binary);
    i += binary.len;
    for (args) |a| {
        buf[i] = ' ';
        i += 1;
        @memcpy(buf[i .. i + a.len], a);
        i += a.len;
    }
    return buf;
}

fn writeFile(path: []const u8, io: Io, content: []const u8) !void {
    var file = try Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var fw = file.writer(io, &.{});
    try fw.interface.writeAll(content);
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
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

 
fn parseSystemctlShow(output: []const u8) ServiceStatus {
    var pid: ?i32 = null;
    var exit_code: ?i32 = null;
    var active: []const u8 = "";

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "MainPID=")) {
            const v = line["MainPID=".len..];
            const n = std.fmt.parseInt(i32, v, 10) catch 0;
            if (n > 0) pid = n;
        } else if (std.mem.startsWith(u8, line, "ActiveState=")) {
            active = line["ActiveState=".len..];
        } else if (std.mem.startsWith(u8, line, "ExecMainStatus=")) {
            exit_code = std.fmt.parseInt(i32, line["ExecMainStatus=".len..], 10) catch null;
        }
    }

    var state: ServiceState = .unknown;
    if (std.mem.eql(u8, active, "active")) {
        state = .running;
    } else if (std.mem.eql(u8, active, "failed")) {
        state = .crashed;
    } else if (std.mem.eql(u8, active, "inactive")) {
        if (exit_code != null and exit_code.? != 0) {
            state = .crashed;
        } else {
            state = .stopped;
        }
    } else if (active.len == 0) {
        state = .not_loaded;
    }

    return .{ .state = state, .pid = pid, .exit_code = exit_code };
}

 
fn parseLaunchctlPrint(output: []const u8) ServiceStatus {
    var pid: ?i32 = null;
    var exit_code: ?i32 = null;
    var state: ServiceState = .unknown;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "pid = ")) {
            pid = std.fmt.parseInt(i32, trimmed["pid = ".len..], 10) catch null;
            if (pid != null) state = .running;
        } else if (std.mem.startsWith(u8, trimmed, "last exit code = ")) {
            exit_code = std.fmt.parseInt(i32, trimmed["last exit code = ".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, trimmed, "state = ")) {
            const val = trimmed["state = ".len..];
            if (std.mem.eql(u8, val, "running")) {
                state = .running;
            } else if (std.mem.eql(u8, val, "waiting")) {
                state = .stopped;
            } else if (std.mem.eql(u8, val, "not running")) {
                state = if (exit_code != null and exit_code.? != 0) .crashed else .stopped;
            }
        }
    }

    return .{ .state = state, .pid = pid, .exit_code = exit_code };
}

 
fn parseScQueryex(output: []const u8) ServiceStatus {
    var pid: ?i32 = null;
    var state: ServiceState = .unknown;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
         if (std.mem.startsWith(u8, line, "STATE")) {
            if (std.mem.indexOf(u8, line, "RUNNING") != null) {
                state = .running;
            } else if (std.mem.indexOf(u8, line, "STOPPED") != null) {
                state = .stopped;
            } else if (std.mem.indexOf(u8, line, "PAUSED") != null) {
                state = .stopped;
            }
        } else if (std.mem.startsWith(u8, line, "PID")) {
             if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const v = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
                const n = std.fmt.parseInt(i32, v, 10) catch 0;
                if (n > 0) pid = n;
            }
        }
    }

    return .{ .state = state, .pid = pid };
}

 
test "joinArgs" {
    const allocator = std.testing.allocator;
    const out = try joinArgs(allocator, "/usr/bin/foo", &.{ "run", "--config", "x.yaml" });
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/usr/bin/foo run --config x.yaml", out);
}

test "joinArgs no args" {
    const allocator = std.testing.allocator;
    const out = try joinArgs(allocator, "/bin/x", &.{});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/bin/x", out);
}

test "parseSystemctlShow running" {
    const sample =
        "MainPID=1234\nActiveState=active\nSubState=running\nExecMainStatus=0\n";
    const s = parseSystemctlShow(sample);
    try std.testing.expectEqual(ServiceState.running, s.state);
    try std.testing.expectEqual(@as(?i32, 1234), s.pid);
}

test "parseSystemctlShow crashed" {
    const sample =
        "MainPID=0\nActiveState=failed\nSubState=failed\nExecMainStatus=1\n";
    const s = parseSystemctlShow(sample);
    try std.testing.expectEqual(ServiceState.crashed, s.state);
    try std.testing.expectEqual(@as(?i32, 1), s.exit_code);
}

test "parseSystemctlShow stopped" {
    const sample =
        "MainPID=0\nActiveState=inactive\nSubState=dead\nExecMainStatus=0\n";
    const s = parseSystemctlShow(sample);
    try std.testing.expectEqual(ServiceState.stopped, s.state);
}

test "parseLaunchctlPrint running" {
    const sample =
        \\state = running
        \\pid = 4321
        \\last exit code = 0
    ;
    const s = parseLaunchctlPrint(sample);
    try std.testing.expectEqual(ServiceState.running, s.state);
    try std.testing.expectEqual(@as(?i32, 4321), s.pid);
}

test "parseScQueryex running" {
    const sample =
        "SERVICE_NAME: foo\n        STATE              : 4  RUNNING\n        PID                : 9999\n";
    const s = parseScQueryex(sample);
    try std.testing.expectEqual(ServiceState.running, s.state);
    try std.testing.expectEqual(@as(?i32, 9999), s.pid);
}
