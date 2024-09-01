const std = @import("std");
const color = @import("colored_print.zig");

pub fn main() !u8 {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var args = std.process.args();
    const self_name = args.next() orelse @panic("Impossible");
    const program_to_execute = args.next() orelse {
        std.debug.print(
            \\Program name not specified
            \\Usage: {s} path/to/program
            \\
        , .{self_name});
        return 0;
    };

    const pid = try std.posix.fork();
    if (pid == 0) {
        // child
        try std.posix.ptrace(
            std.os.linux.PTRACE.TRACEME,
            0,
            0,
            0,
        );
        return std.posix.execveZ(program_to_execute, &.{program_to_execute}, &.{null});
    } else if (pid >= 1) { // parent

        const file = try std.fs.cwd().openFile(program_to_execute, .{});
        const elf_header = try std.elf.Header.read(file);

        const table = try elfGetSectionStringTable(arena, elf_header, file) orelse {
            std.log.err("Can't find string table", .{});
            return 1;
        };

        var iter = elf_header.section_header_iterator(file);
        var sections_array = std.debug.Dwarf.null_section_array;
        while (try iter.next()) |section| {
            if (section.sh_type != std.elf.SHT_NULL) {
                const name = std.mem.span(@as([*:0]u8, @ptrCast(&table[section.sh_name])));
                const id = std.meta.stringToEnum(
                    std.debug.Dwarf.Section.Id,
                    name[1..],
                ) orelse continue; // Remove .
                const buf = try arena.alloc(u8, section.sh_size);
                try file.seekTo(section.sh_offset);
                _ = try file.readAll(buf);
                sections_array[@intFromEnum(id)] = std.debug.Dwarf.Section{
                    .data = buf,
                    .virtual_address = null,
                    .owned = false,
                };

                std.debug.print("Read {any}\n", .{id});
            }
        }

        var dwarf = std.debug.Dwarf{
            .sections = sections_array,
            .endian = .little,
            .is_macho = false,
        };
        try dwarf.open(gpa);
        defer dwarf.deinit(gpa);
        for (dwarf.func_list.items) |func| {
            std.debug.print("{?s}\n", .{func.name});
        }
    }
    return 0;
}

fn debug(debugge_name: []const u8, debugge_pid: i32) void {
    _ = debugge_name;
    const res = std.posix.waitpid(debugge_pid, 0);
    std.log.info("waited for pid {d}", .{res.pid});

    const stdio = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    const reader = stdio.reader();
    var buffer: [256]u8 = undefined;

    var old_regs: user_regs_struct = std.mem.zeroes(user_regs_struct);

    while (blk: {
        stdout.writeAll("zugger> ") catch |err| {
            std.log.err("can't write to stdout: {s}", .{@errorName(err)});
        };
        break :blk reader.readUntilDelimiterOrEof(&buffer, '\n') catch "";
    }) |line| {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const command = tokens.next() orelse "step";
        if (std.mem.startsWith(u8, "continue", command)) {
            continueExecution(debugge_pid) catch |err| {
                std.log.err("Failed to continue execution: {s}", .{@errorName(err)});
            };
            continue;
        }
        if (std.mem.startsWith(u8, "step", command)) {
            step(debugge_pid) catch |err| {
                std.log.err("Failed to continue execution: {s}", .{@errorName(err)});
            };
        }
        const regs = getRegisters(debugge_pid) catch |err| {
            std.log.err("Failed to continue execution: {s}", .{@errorName(err)});
            continue;
        };
        regs.printDiff(old_regs);
        old_regs = regs;
    }
}

fn continueExecution(pid: i32) !void {
    std.posix.ptrace(std.os.linux.PTRACE.CONT, pid, 0, 0) catch |err| {
        std.log.err("continue {s}", .{@errorName(err)});
        return;
    };
    const res = std.posix.waitpid(pid, 0);
    _ = res; // autofix
}

fn step(pid: i32) !void {
    std.posix.ptrace(std.os.linux.PTRACE.SINGLESTEP, pid, 0, 0) catch |err| {
        std.log.err("step failed {s}", .{@errorName(err)});
        return;
    };
    const res = std.posix.waitpid(pid, 0);
    _ = res; // autofix
}

const user_regs_struct = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    bp: u64,
    bx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    ax: u64,
    cx: u64,
    dx: u64,
    si: u64,
    di: u64,
    orig_ax: u64,
    ip: u64,
    cs: u64,
    flags: u64,
    sp: u64,
    ss: u64,
    fs_base: u64,
    gs_base: u64,
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,

    pub fn printDiff(self: @This(), other: @This()) void {
        inline for (@typeInfo(@This()).@"struct".fields) |field| {
            if (@field(self, field.name) != @field(other, field.name)) {
                color.print(field.name ++ ": {x}\n", .{@field(self, field.name)}, .{ .fg = color.fg.red });
            } else {
                std.debug.print(field.name ++ ": {x}\n", .{@field(self, field.name)});
            }
        }
    }

    pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt; // autofix
        _ = options; // autofix
        inline for (@typeInfo(@This()).@"struct".fields) |field| {
            try writer.print(field.name ++ ": {x}\n", .{@field(value, field.name)});
        }
    }
};

fn getRegisters(pid: i32) !user_regs_struct {
    var regs: user_regs_struct = undefined;
    std.posix.ptrace(std.os.linux.PTRACE.GETREGS, pid, 0, @intFromPtr(&regs)) catch |err| {
        std.log.err("can't get registers {s}", .{@errorName(err)});
        return err;
    };

    return regs;
}

fn elfGetSectionStringTable(alloc: std.mem.Allocator, elf_header: std.elf.Header, file: std.fs.File) !?[]u8 {
    var iter = elf_header.section_header_iterator(file);
    var counter: usize = 0;
    while (try iter.next()) |section| : (counter += 1) {
        if (section.sh_type == std.elf.SHT_STRTAB and counter == elf_header.shstrndx) {
            try file.seekTo(section.sh_offset);
            const buffer = try alloc.alloc(u8, section.sh_size);
            std.debug.assert(try file.readAll(buffer) == section.sh_size);
            return buffer;
        }
    }
    return null;
}
