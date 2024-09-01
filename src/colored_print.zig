const std = @import("std");

pub const fg = struct {
    pub const black = 30;
    pub const red = 31;
    pub const green = 32;
    pub const yellow = 33;
    pub const blue = 34;
    pub const magenta = 35;
    pub const cyan = 36;
    pub const white = 37;
};

pub const bg = struct {
    pub const black = 40;
    pub const red = 41;
    pub const green = 42;
    pub const yellow = 43;
    pub const blue = 44;
    pub const magenta = 45;
    pub const cyan = 46;
    pub const white = 47;
};
pub fn print(comptime fmt: []const u8, args: anytype, color: struct {
    fg: u8 = fg.white,
    bg: u8 = bg.black,
}) void {
    std.debug.print("\x1B[{d};{d}" ++
        "m" ++
        fmt ++
        "\x1B[0m", .{color.bg} ++
        .{color.fg} ++ args);
}
