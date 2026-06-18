

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const tar_mod = @import("tar.zig");

pub const ContainerFormat = enum {
    tar_gz,
    zip,

    pub fn default() ContainerFormat {
        return switch (builtin.os.tag) {
            .windows => .zip,
            else => .tar_gz,
        };
    }

    pub fn extension(self: ContainerFormat) []const u8 {
        return switch (self) {
            .tar_gz => "tar.gz",
            .zip => "zip",
        };
    }

    pub fn fromExtension(name: []const u8) ?ContainerFormat {
        if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz")) return .tar_gz;
        if (std.mem.endsWith(u8, name, ".zip")) return .zip;
        return null;
    }
};

pub const Error = error{
    UnsupportedFormat,
    ArchiveCommandFailed,
};

pub fn create(io: Io, format: ContainerFormat, src_dir: []const u8, output_path: []const u8) !void {
    switch (format) {
        .tar_gz => try tar_mod.create(io, src_dir, output_path),
        .zip => return Error.UnsupportedFormat,
    }
}

pub fn extract(io: Io, format: ContainerFormat, archive_path: []const u8, target_dir: []const u8) !void {
    switch (format) {
        .tar_gz => try tar_mod.extract(io, archive_path, target_dir),
        .zip => return Error.UnsupportedFormat,
    }
}

test {
    _ = @import("tar.zig");
}
