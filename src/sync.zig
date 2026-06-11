
const std = @import("std");
const Io = std.Io;

pub const Mutex = struct {
    impl: Io.Mutex = Io.Mutex.init,

    pub fn lock(self: *Mutex, io: Io) void {
        self.impl.lockUncancelable(io);
    }

    pub fn unlock(self: *Mutex, io: Io) void {
        self.impl.unlock(io);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.impl.tryLock();
    }

    pub fn deinit(self: *Mutex) void {
        _ = self;
    }
};

pub const RwLock = struct {
    impl: Io.RwLock = Io.RwLock.init,

    pub fn lock(self: *RwLock, io: Io) void {
        self.impl.lockUncancelable(io);
    }

    pub fn unlock(self: *RwLock, io: Io) void {
        self.impl.unlock(io);
    }

    pub fn lockShared(self: *RwLock, io: Io) void {
        self.impl.lockSharedUncancelable(io);
    }

    pub fn unlockShared(self: *RwLock, io: Io) void {
        self.impl.unlockShared(io);
    }

    pub fn tryLock(self: *RwLock, io: Io) bool {
        return self.impl.tryLock(io);
    }

    pub fn tryLockShared(self: *RwLock, io: Io) bool {
        return self.impl.tryLockShared(io);
    }

    pub fn deinit(self: *RwLock) void {
        _ = self;
    }
};
