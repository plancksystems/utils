
const std = @import("std");
const Now = @import("time.zig").Now;

pub const CircuitBreaker = struct {
    io: std.Io,
    state: State,
    failure_count: u32,
    success_count: u32,
    last_state_change: i64,

    failure_threshold: u32,
    success_threshold: u32,
    timeout_ms: u32,

    pub const State = enum {
        closed,
        open,
        half_open,
    };

    pub fn init(io: std.Io, failure_threshold: u32, success_threshold: u32, timeout_ms: u32) CircuitBreaker {
        return .{
            .io = io,
            .state = .closed,
            .failure_count = 0,
            .success_count = 0,
            .last_state_change = nowMs(io),
            .failure_threshold = failure_threshold,
            .success_threshold = success_threshold,
            .timeout_ms = timeout_ms,
        };
    }

    fn nowMs(io: std.Io) i64 {
        return (Now{ .io = io }).toMilliSeconds();
    }

    pub fn shouldAllow(self: *CircuitBreaker) bool {
        switch (self.state) {
            .closed => return true,
            .half_open => return true,
            .open => {
                const now = nowMs(self.io);
                const elapsed = @as(u32, @intCast(now - self.last_state_change));
                if (elapsed >= self.timeout_ms) {
                     self.state = .half_open;
                    self.failure_count = 0;
                    self.success_count = 0;
                    self.last_state_change = now;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => {
                 self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.success_threshold) {
                     self.state = .closed;
                    self.failure_count = 0;
                    self.success_count = 0;
                    self.last_state_change = nowMs(self.io);
                }
            },
            .open => {
                 self.failure_count = 0;
            },
        }
    }

    pub fn recordFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;

        switch (self.state) {
            .closed => {
                if (self.failure_count >= self.failure_threshold) {
                     self.state = .open;
                    self.last_state_change = nowMs(self.io);
                }
            },
            .half_open => {
                 self.state = .open;
                self.success_count = 0;
                self.last_state_change = nowMs(self.io);
            },
            .open => {
                 self.last_state_change = nowMs(self.io);
            },
        }
    }

    pub fn getState(self: *const CircuitBreaker) State {
        return self.state;
    }

    pub fn reset(self: *CircuitBreaker) void {
        self.state = .closed;
        self.failure_count = 0;
        self.success_count = 0;
        self.last_state_change = nowMs(self.io);
    }
};
