
const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    workbench,
    sysdb,
    svc,
    app,
    proxy,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            // Phase 7 rename — user-visible launchd / systemd unit
            // names become "cc" instead of "workbench". The Kind tag
            // stays as `.workbench` (internal symbol) per the design.
            .workbench => "cc",
            .sysdb => "sysdb",
            .svc => "svc",
            .app => "app",
            .proxy => "proxy",
        };
    }
};

pub const PREFIX: []const u8 = switch (builtin.os.tag) {
    .macos => "com.planck.",
    .linux => "planck-",
    .windows => "Planck.",
    else => "planck-",
};

pub fn buildLabel(allocator: std.mem.Allocator, kind: Kind, scope: []const u8) ![]u8 {
    const k = kind.toString();
    return switch (builtin.os.tag) {
        .macos => std.fmt.allocPrint(allocator, "com.planck.{s}.{s}", .{ k, scope }),
        .linux => std.fmt.allocPrint(allocator, "planck.{s}.{s}", .{ k, scope }),
        .windows => std.fmt.allocPrint(allocator, "Planck.{s}.{s}", .{ k, scope }),
        else => std.fmt.allocPrint(allocator, "planck.{s}.{s}", .{ k, scope }),
    };
}

pub fn workbench(allocator: std.mem.Allocator) ![]u8 {
    return buildLabel(allocator, .workbench, "ui");
}

pub fn sysdb(allocator: std.mem.Allocator) ![]u8 {
    return buildLabel(allocator, .sysdb, "db");
}

pub fn service(allocator: std.mem.Allocator, app: []const u8, name: []const u8) ![]u8 {
    if (app.len == 0) return buildLabel(allocator, .svc, name);
    const scope = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ app, name });
    defer allocator.free(scope);
    return buildLabel(allocator, .svc, scope);
}

pub fn shellApp(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return buildLabel(allocator, .app, name);
}

pub fn proxyApp(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return buildLabel(allocator, .proxy, name);
}

pub fn isPlanckLabel(label: []const u8) bool {
    return std.mem.startsWith(u8, label, PREFIX);
}

 
test "buildLabel current platform" {
    const a = std.testing.allocator;
    const lbl = try buildLabel(a, .workbench, "standalone");
    defer a.free(lbl);
    try std.testing.expect(std.mem.startsWith(u8, lbl, PREFIX));
    try std.testing.expect(std.mem.endsWith(u8, lbl, "standalone"));
    try std.testing.expect(std.mem.indexOf(u8, lbl, "cc") != null);
}

test "service with app" {
    const a = std.testing.allocator;
    const lbl = try service(a, "shop", "orders");
    defer a.free(lbl);
    try std.testing.expect(std.mem.indexOf(u8, lbl, "shop.orders") != null);
    try std.testing.expect(std.mem.indexOf(u8, lbl, "svc") != null);
}

test "service without app" {
    const a = std.testing.allocator;
    const lbl = try service(a, "", "orders");
    defer a.free(lbl);
    try std.testing.expect(std.mem.endsWith(u8, lbl, "orders"));
}

test "isPlanckLabel" {
    const a = std.testing.allocator;
    const lbl = try workbench(a);
    defer a.free(lbl);
    try std.testing.expect(isPlanckLabel(lbl));
    try std.testing.expect(!isPlanckLabel("nginx.service"));
    try std.testing.expect(!isPlanckLabel("com.apple.something"));
}
