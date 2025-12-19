const std = @import("std");
const builtin = @import("builtin");

pub fn printSplash() void {
    std.debug.print(
        \\
        \\           █████╗   ██████╗  ██    ██
        \\  ______  ██╔══██╗  ██╔══██╗ ██    ██
        \\  \====/  ██║       ██████╔╝ ██    ██
        \\   \\     ██║  ██╗  ██║      ██    ██
        \\ ___\\    ╚█████╔╝  ██║      ╚█████╔╝
        \\ \====\    ╚════╝   ╚═╝       ╚════╝ 
        \\           
    , .{});
}

pub fn printSystemInfo() !void {
    // Architecture and OS
    std.debug.print("Architecture : {s}\n", .{@tagName(builtin.cpu.arch)});
    std.debug.print("OS           : {s}\n", .{@tagName(builtin.os.tag)});

    // TODO: MacOS and Windows support.

    try printCpuBrand(); // CPU Brand (Linux only)
    try printCpuFrequency(); // CPU Frequency (Linux only)
}

fn printCpuBrand() !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("CPU Brand    : (unsupported on this OS)\n", .{});
        return;
    }

    const file = try std.fs.openFileAbsolute("/proc/cpuinfo", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    const size = try file.readAll(&buf);
    const text = buf[0..size];

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOf(u8, line, ":")) |idx| {
                const name = std.mem.trim(u8, line[idx + 1 ..], " ");
                std.debug.print("CPU Brand    : {s}\n", .{name});
                return;
            }
        }
    }

    std.debug.print("CPU Brand    : unknown\n", .{});
}

fn printCpuFrequency() !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("CPU Frequency: (unsupported on this OS)\n", .{});
        return;
    }

    const file = try std.fs.openFileAbsolute("/proc/cpuinfo", .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    const size = try file.readAll(&buf);
    const text = buf[0..size];

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "cpu MHz")) {
            if (std.mem.indexOf(u8, line, ":")) |idx| {
                const mhz = std.mem.trim(u8, line[idx + 1 ..], " ");
                std.debug.print("CPU Frequency: {s} MHz\n", .{mhz});
                return;
            }
        }
    }

    std.debug.print("CPU Frequency: unknown\n", .{});
}

pub fn main() !void {
    printSplash();
    std.debug.print("\nzCPU v0.0.1 - Authored by Uljas Antero Lindell 2025\n\n", .{});
    try printSystemInfo();
}
