
const std = @import("std");
const Io = std.Io;

pub const StopWatch = struct {
    start_ns: ?i128 = null,
    elapsed_ns: i128 = 0,

    pub fn start(self: *StopWatch, io: Io) void {
        self.start_ns = Io.Clock.now(.awake, io).toNanoseconds();
    }

    pub fn stop(self: *StopWatch, io: Io) void {
        if (self.start_ns) |begin| {
            const now: i128 = Io.Clock.now(.awake, io).toNanoseconds();
            self.elapsed_ns += now - begin;
            self.start_ns = null;
        }
    }

    pub fn reset(self: *StopWatch) void {
        self.start_ns = null;
        self.elapsed_ns = 0;
    }

    pub fn elapsedNs(self: *const StopWatch) u64 {
        return @intCast(self.elapsed_ns);
    }

    pub fn elapsedUs(self: *const StopWatch) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000.0;
    }

    pub fn elapsedMs(self: *const StopWatch) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000.0;
    }

    pub fn elapsedS(self: *const StopWatch) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000_000.0;
    }
};
