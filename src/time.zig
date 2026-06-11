
const std = @import("std");
const Io = std.Io;

pub const Now = struct {
    io: Io,

    pub fn toMilliSeconds(self: Now) i64 {
        return Io.Clock.now(.real, self.io).toMilliseconds();
    }

    pub fn toSeconds(self: Now) i64 {
        return Io.Clock.now(.real, self.io).toSeconds();
    }

    pub fn toNanoSeconds(self: Now) i96 {
        return Io.Clock.now(.real, self.io).toNanoseconds();
    }
};
