const std = @import("std");
const builtin = @import("builtin");
const zcpu = @import("zcpu");

const refresh_ms = 1000;
const freq_columns = 4;
const temp_columns = 3;

/// Set by SIGINT/SIGTERM so the live view can exit and restore the terminal.
var stop_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: i32) callconv(.c) void {
    stop_requested.store(true, .release);
}

pub fn printSplash(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\
        \\           █████╗   ██████╗  ██    ██
        \\  ______  ██╔══██╗  ██╔══██╗ ██    ██
        \\  \====/  ██║       ██████╔╝ ██    ██
        \\   \\     ██║  ██╗  ██║      ██    ██
        \\ ___\\    ╚█████╔╝  ██║      ╚█████╔╝
        \\ \====\    ╚════╝   ╚═╝       ╚════╝
        \\
        \\
    );
}

fn field(w: *std.Io.Writer, key: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try w.print("   {s:<15}" ++ fmt ++ "\n", .{key} ++ args);
}

fn orNa(value: ?[]const u8) []const u8 {
    return value orelse "n/a";
}

/// Prints space-separated `words` as a field, wrapping lines at ~78 columns.
fn wrappedField(w: *std.Io.Writer, key: []const u8, words: anytype) !void {
    const indent = 18;
    const width = 78;
    try w.print("   {s:<15}", .{key});
    var col: usize = indent;
    var first = true;
    while (words.next()) |word| {
        if (!first and col + 1 + word.len > width) {
            try w.writeAll("\n");
            try w.splatByteAll(' ', indent);
            col = indent;
        } else if (!first) {
            try w.writeAll(" ");
            col += 1;
        }
        try w.writeAll(word);
        col += word.len;
        first = false;
    }
    try w.writeAll("\n");
}

const SliceIterator = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *SliceIterator) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

fn printStatic(w: *std.Io.Writer, info: zcpu.Info) !void {
    try w.print(" Processor\n", .{});
    try field(w, "Name", "{s}", .{info.model_name});
    try field(w, "Vendor", "{s}", .{info.vendor});
    try field(w, "Architecture", "{s}", .{@tagName(builtin.cpu.arch)});
    if (info.family) |family| {
        try field(w, "Family", "{d} (0x{X})", .{ family, family });
    }
    if (info.model) |model| {
        try field(w, "Model", "{d} (0x{X})", .{ model, model });
    }
    if (info.stepping) |stepping| try field(w, "Stepping", "{d}", .{stepping});
    if (info.microcode) |microcode| try field(w, "Microcode", "{s}", .{microcode});
    try field(w, "Topology", "{d} socket(s), {d} cores, {d} threads", .{ info.sockets, info.cores, info.cpus.len });
    if (info.address_sizes) |sizes| try field(w, "Address sizes", "{s}", .{sizes});
    if (info.bogomips) |bogomips| try field(w, "BogoMIPS", "{s}", .{bogomips});

    if (info.caches.len > 0) {
        try w.print("\n Cache\n", .{});
        for (info.caches) |cache| {
            var key_buf: [32]u8 = undefined;
            const key = if (std.mem.eql(u8, cache.kind, "Unified"))
                try std.fmt.bufPrint(&key_buf, "L{d}", .{cache.level})
            else
                try std.fmt.bufPrint(&key_buf, "L{d} {s}", .{ cache.level, cache.kind });
            if (cache.size_kb >= 1024 and cache.size_kb % 1024 == 0) {
                try field(w, key, "{d} x {d} MB", .{ cache.instances, cache.size_kb / 1024 });
            } else {
                try field(w, key, "{d} x {d} KB", .{ cache.instances, cache.size_kb });
            }
        }
    }

    try w.print("\n Frequency scaling\n", .{});
    if (info.min_khz != null and info.max_khz != null) {
        try field(w, "Range", "{d} - {d} MHz", .{ info.min_khz.? / 1000, info.max_khz.? / 1000 });
    }
    if (info.base_khz) |base| try field(w, "Base", "{d} MHz", .{base / 1000});
    try field(w, "Driver", "{s}", .{orNa(info.driver)});
    try field(w, "Governor", "{s}", .{orNa(info.governor)});
    if (info.epp) |epp| try field(w, "EPP", "{s}", .{epp});
    if (info.boost) |boost| try field(w, "Boost", "{s}", .{if (boost) "enabled" else "disabled"});

    try w.print("\n Features\n", .{});
    if (info.extensions.len > 0) {
        var it: SliceIterator = .{ .items = info.extensions };
        try wrappedField(w, "Instructions", &it);
    } else if (info.features) |features| {
        var it = std.mem.tokenizeScalar(u8, features, ' ');
        try wrappedField(w, "Instructions", &it);
    }
    if (info.bugs) |bugs| {
        var it = std.mem.tokenizeScalar(u8, bugs, ' ');
        try wrappedField(w, "Known bugs", &it);
    }
}

/// Writes lines that overwrite what was previously on screen and counts them,
/// so the next refresh knows how far to move the cursor back up.
const LiveWriter = struct {
    w: *std.Io.Writer,
    interactive: bool,
    lines: usize = 0,

    fn line(self: *LiveWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.w.print(fmt, args);
        // Clear the rest of the line in case the previous frame's line was longer.
        if (self.interactive) try self.w.writeAll("\x1b[K");
        try self.w.writeAll("\n");
        self.lines += 1;
    }
};

const LiveState = struct {
    freqs_khz: []u64,
    temps: []?i64,
    peak_khz: u64 = 0,
    peak_temp: ?i64 = null,
};

fn printLive(w: *std.Io.Writer, info: zcpu.Info, state: *LiveState, interactive: bool) !usize {
    var out: LiveWriter = .{ .w = w, .interactive = interactive };

    var sum: u64 = 0;
    var known: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (state.freqs_khz) |khz| {
        if (khz == 0) continue;
        sum += khz;
        known += 1;
        min = @min(min, khz);
        max = @max(max, khz);
    }
    state.peak_khz = @max(state.peak_khz, max);

    try out.line("", .{});
    if (interactive) {
        try out.line(" Live (refreshes every {d} s, Ctrl+C to quit)", .{refresh_ms / 1000});
    } else {
        try out.line(" Current", .{});
    }
    if (known == 0) {
        try out.line("   {s:<15}unavailable", .{"Clock"});
    } else {
        try out.line("   {s:<15}avg {d} MHz   min {d}   max {d}   peak {d} MHz", .{
            "Clock", sum / known / 1000, min / 1000, max / 1000, state.peak_khz / 1000,
        });
        var i: usize = 0;
        while (i < info.cpus.len) : (i += freq_columns) {
            var row_buf: [128]u8 = undefined;
            var row: std.Io.Writer = .fixed(&row_buf);
            for (info.cpus[i..@min(i + freq_columns, info.cpus.len)], state.freqs_khz[i..@min(i + freq_columns, info.cpus.len)]) |cpu, khz| {
                var name_buf: [16]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "cpu{d}", .{cpu});
                try row.print("{s:<6}{d:>5}   ", .{ name, khz / 1000 });
            }
            try out.line("   {s:<15}{s}", .{ "", std.mem.trimRight(u8, row.buffered(), " ") });
        }
    }

    if (info.sensors.len == 0) {
        try out.line("   {s:<15}unavailable (no CPU hwmon sensor found)", .{"Temperature"});
    } else {
        var hottest: ?i64 = null;
        for (info.sensors, state.temps) |sensor, *temp| {
            temp.* = zcpu.readTemperature(sensor);
            if (temp.*) |t| hottest = if (hottest) |h| @max(h, t) else t;
        }
        if (hottest) |h| state.peak_temp = if (state.peak_temp) |p| @max(p, h) else h;

        var i: usize = 0;
        while (i < info.sensors.len) : (i += temp_columns) {
            var row_buf: [256]u8 = undefined;
            var row: std.Io.Writer = .fixed(&row_buf);
            const end = @min(i + temp_columns, info.sensors.len);
            for (info.sensors[i..end], state.temps[i..end]) |sensor, temp| {
                if (temp) |t| {
                    try row.print("{s:<8}{d:>5.1} °C   ", .{ sensor.label, celsius(t) });
                } else {
                    try row.print("{s:<8}  n/a      ", .{sensor.label});
                }
            }
            const key = if (i == 0) "Temperature" else "";
            try out.line("   {s:<15}{s}", .{ key, std.mem.trimRight(u8, row.buffered(), " ") });
        }
        if (state.peak_temp) |p| {
            try out.line("   {s:<15}peak {d:.1} °C ({s})", .{ "", celsius(p), info.sensor_chip.? });
        }
    }
    return out.lines;
}

fn celsius(millidegrees: i64) f64 {
    return @as(f64, @floatFromInt(millidegrees)) / 1000.0;
}

fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stdout = std.fs.File.stdout();
    var out_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = stdout.writer(&out_buf);
    const w = &stdout_writer.interface;

    try printSplash(w);
    try w.writeAll("\nzCPU v0.0.2 - Authored by Uljas Antero Lindell 2025\n\n");

    if (builtin.os.tag != .linux) {
        try w.print("CPU information is only supported on Linux (running on {s}).\n", .{@tagName(builtin.os.tag)});
        try w.flush();
        return;
    }

    const info = try zcpu.collect(arena);
    try printStatic(w, info);

    var state: LiveState = .{
        .freqs_khz = try arena.alloc(u64, info.cpus.len),
        .temps = try arena.alloc(?i64, info.sensors.len),
    };
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    // When piped or redirected, print one snapshot instead of redrawing.
    const interactive = stdout.isTty();
    if (!interactive) {
        zcpu.readFrequencies(info, scratch.allocator(), state.freqs_khz);
        _ = try printLive(w, info, &state, false);
        try w.flush();
        return;
    }

    installSignalHandlers();
    try w.writeAll("\x1b[?25l"); // hide cursor while redrawing
    defer {
        w.writeAll("\x1b[?25h") catch {};
        w.flush() catch {};
    }

    var previous_lines: usize = 0;
    while (!stop_requested.load(.acquire)) {
        _ = scratch.reset(.retain_capacity);
        zcpu.readFrequencies(info, scratch.allocator(), state.freqs_khz);
        if (previous_lines > 0) try w.print("\x1b[{d}A", .{previous_lines});
        previous_lines = try printLive(w, info, &state, true);
        try w.flush();

        var waited: u64 = 0;
        while (waited < refresh_ms and !stop_requested.load(.acquire)) : (waited += 50) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }
}
