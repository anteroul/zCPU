//! CPU information gathering for Linux, using /proc/cpuinfo and sysfs.
const std = @import("std");

const cpu_sysfs = "/sys/devices/system/cpu";

/// hwmon chip names that report CPU temperatures, in order of preference.
const cpu_hwmon_names = [_][]const u8{ "k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal" };

/// cpuinfo flag -> display name for notable instruction set extensions (x86).
const extension_flags = [_][2][]const u8{
    .{ "lm", "x86-64" },        .{ "mmx", "MMX" },             .{ "sse", "SSE" },
    .{ "sse2", "SSE2" },        .{ "pni", "SSE3" },            .{ "ssse3", "SSSE3" },
    .{ "sse4_1", "SSE4.1" },    .{ "sse4_2", "SSE4.2" },       .{ "sse4a", "SSE4A" },
    .{ "avx", "AVX" },          .{ "avx2", "AVX2" },           .{ "avx512f", "AVX-512F" },
    .{ "avx512bw", "AVX-512BW" }, .{ "avx512vl", "AVX-512VL" }, .{ "avx_vnni", "AVX-VNNI" },
    .{ "fma", "FMA3" },         .{ "fma4", "FMA4" },           .{ "f16c", "F16C" },
    .{ "aes", "AES-NI" },       .{ "vaes", "VAES" },           .{ "pclmulqdq", "PCLMUL" },
    .{ "vpclmulqdq", "VPCLMULQDQ" }, .{ "sha_ni", "SHA" },     .{ "bmi1", "BMI1" },
    .{ "bmi2", "BMI2" },        .{ "adx", "ADX" },             .{ "popcnt", "POPCNT" },
    .{ "movbe", "MOVBE" },      .{ "rdrand", "RDRAND" },       .{ "rdseed", "RDSEED" },
    .{ "svm", "AMD-V" },        .{ "vmx", "VT-x" },            .{ "amx_tile", "AMX" },
};

pub const Cache = struct {
    level: u8,
    /// "Data", "Instruction" or "Unified".
    kind: []const u8,
    size_kb: u64,
    instances: usize,
};

pub const Sensor = struct {
    label: []const u8,
    /// Path to the hwmon tempN_input file (millidegrees Celsius).
    path: []const u8,
};

/// Information that does not change while the program runs.
pub const Info = struct {
    vendor: []const u8 = "unknown",
    model_name: []const u8 = "unknown",
    family: ?u32 = null,
    model: ?u32 = null,
    stepping: ?u32 = null,
    microcode: ?[]const u8 = null,
    address_sizes: ?[]const u8 = null,
    bogomips: ?[]const u8 = null,
    sockets: usize = 0,
    cores: usize = 0,
    /// Online logical CPU ids.
    cpus: []const u32 = &.{},
    caches: []const Cache = &.{},
    min_khz: ?u64 = null,
    max_khz: ?u64 = null,
    base_khz: ?u64 = null,
    driver: ?[]const u8 = null,
    governor: ?[]const u8 = null,
    epp: ?[]const u8 = null,
    boost: ?bool = null,
    extensions: []const []const u8 = &.{},
    /// Raw feature list, used when no known x86 extensions are found (e.g. ARM).
    features: ?[]const u8 = null,
    bugs: ?[]const u8 = null,
    sensor_chip: ?[]const u8 = null,
    sensors: []const Sensor = &.{},
};

/// Gathers static CPU information. All returned memory is owned by `gpa`;
/// an arena allocator is the intended use.
pub fn collect(gpa: std.mem.Allocator) !Info {
    var info: Info = .{};

    const online = try readFileAlloc(gpa, cpu_sysfs ++ "/online");
    info.cpus = try parseCpuList(gpa, std.mem.trim(u8, online, " \n"));

    try parseCpuinfo(gpa, &info, try readFileAlloc(gpa, "/proc/cpuinfo"));
    try collectTopology(gpa, &info);
    try collectCaches(gpa, &info);
    try collectFrequencyScaling(gpa, &info);
    try collectSensors(gpa, &info);
    return info;
}

fn parseCpuinfo(gpa: std.mem.Allocator, info: *Info, text: []const u8) !void {
    var flags: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        // Only the first processor block matters; later blocks repeat these fields.
        if (eql(key, "vendor_id") and eql(info.vendor, "unknown")) {
            info.vendor = value;
        } else if (eql(key, "model name") and eql(info.model_name, "unknown")) {
            info.model_name = value;
        } else if (eql(key, "cpu family") and info.family == null) {
            info.family = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (eql(key, "model") and info.model == null) {
            info.model = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (eql(key, "stepping") and info.stepping == null) {
            info.stepping = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (eql(key, "microcode") and info.microcode == null) {
            info.microcode = value;
        } else if (eql(key, "address sizes") and info.address_sizes == null) {
            info.address_sizes = value;
        } else if ((eql(key, "bogomips") or eql(key, "BogoMIPS")) and info.bogomips == null) {
            info.bogomips = value;
        } else if (eql(key, "flags") and flags == null) {
            flags = value;
        } else if (eql(key, "Features") and info.features == null) {
            info.features = value;
        } else if (eql(key, "bugs") and info.bugs == null) {
            info.bugs = value;
        }
    }

    if (flags) |f| {
        var found: std.ArrayList([]const u8) = .empty;
        for (extension_flags) |ext| {
            if (hasWord(f, ext[0])) try found.append(gpa, ext[1]);
        }
        info.extensions = try found.toOwnedSlice(gpa);
    }
}

fn collectTopology(gpa: std.mem.Allocator, info: *Info) !void {
    var packages: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var cores: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (info.cpus) |cpu| {
        const pkg = readInt(u64, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/topology/physical_package_id", .{cpu})) orelse 0;
        const core = readInt(u64, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/topology/core_id", .{cpu})) orelse cpu;
        try packages.put(gpa, pkg, {});
        try cores.put(gpa, (pkg << 32) | core, {});
    }
    info.sockets = packages.count();
    info.cores = cores.count();
}

fn collectCaches(gpa: std.mem.Allocator, info: *Info) !void {
    if (info.cpus.len == 0) return;
    var caches: std.ArrayList(Cache) = .empty;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var index: usize = 0;
    while (true) : (index += 1) {
        const dir = try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cache/index{d}", .{ info.cpus[0], index });
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(dir_buf[0..dir.len], dir);
        const base = dir_buf[0..dir.len];

        const level = readInt(u8, try std.fmt.bufPrint(&path_buf, "{s}/level", .{base})) orelse break;
        const kind = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, "{s}/type", .{base})) orelse "Unified";
        const size_kb = parseSizeKb(try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, "{s}/size", .{base})) orelse "") orelse continue;
        const shared = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, "{s}/shared_cpu_list", .{base})) orelse "";
        const sharing = @max(1, (parseCpuList(gpa, shared) catch &.{}).len);
        try caches.append(gpa, .{
            .level = level,
            .kind = kind,
            .size_kb = size_kb,
            .instances = std.math.divCeil(usize, info.cpus.len, sharing) catch 1,
        });
    }
    info.caches = try caches.toOwnedSlice(gpa);
}

fn collectFrequencyScaling(gpa: std.mem.Allocator, info: *Info) !void {
    if (info.cpus.len == 0) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cpu = info.cpus[0];
    info.min_khz = readInt(u64, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/cpuinfo_min_freq", .{cpu}));
    info.max_khz = readInt(u64, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/cpuinfo_max_freq", .{cpu}));
    info.base_khz = readInt(u64, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/base_frequency", .{cpu}));
    info.driver = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/scaling_driver", .{cpu}));
    info.governor = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/scaling_governor", .{cpu}));
    info.epp = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/energy_performance_preference", .{cpu}));

    if (readInt(u8, try std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/boost", .{cpu}))) |b| {
        info.boost = b != 0;
    } else if (readInt(u8, cpu_sysfs ++ "/cpufreq/boost")) |b| {
        info.boost = b != 0;
    } else if (readInt(u8, cpu_sysfs ++ "/intel_pstate/no_turbo")) |no_turbo| {
        info.boost = no_turbo == 0;
    }
}

fn collectSensors(gpa: std.mem.Allocator, info: *Info) !void {
    var dir = std.fs.openDirAbsolute("/sys/class/hwmon", .{ .iterate = true }) catch return;
    defer dir.close();

    // Pick the most preferred CPU temperature chip present.
    var best_rank: usize = cpu_hwmon_names.len;
    var best_path: ?[]const u8 = null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const name = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/{s}/name", .{entry.name})) orelse continue;
        for (cpu_hwmon_names, 0..) |candidate, rank| {
            if (rank < best_rank and eql(name, candidate)) {
                best_rank = rank;
                best_path = try std.fmt.allocPrint(gpa, "/sys/class/hwmon/{s}", .{entry.name});
            }
        }
    }
    const chip = best_path orelse return;
    info.sensor_chip = cpu_hwmon_names[best_rank];

    var sensors: std.ArrayList(Sensor) = .empty;
    var n: usize = 1;
    while (n <= 64) : (n += 1) {
        const input = try std.fmt.allocPrint(gpa, "{s}/temp{d}_input", .{ chip, n });
        if (readInt(i64, input) == null) continue;
        const label = try readStringAlloc(gpa, try std.fmt.bufPrint(&path_buf, "{s}/temp{d}_label", .{ chip, n })) orelse
            try std.fmt.allocPrint(gpa, "temp{d}", .{n});
        try sensors.append(gpa, .{ .label = label, .path = input });
    }
    info.sensors = try sensors.toOwnedSlice(gpa);
}

/// Fills `out_khz` (one entry per CPU in `info.cpus`) with the current clock
/// speed of each logical CPU, 0 when unknown. `scratch` is only used when
/// cpufreq is unavailable and /proc/cpuinfo has to be read instead.
pub fn readFrequencies(info: Info, scratch: std.mem.Allocator, out_khz: []u64) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var have_sysfs = false;
    for (info.cpus, out_khz) |cpu, *out| {
        const path = std.fmt.bufPrint(&path_buf, cpu_sysfs ++ "/cpu{d}/cpufreq/scaling_cur_freq", .{cpu}) catch unreachable;
        out.* = readInt(u64, path) orelse 0;
        if (out.* != 0) have_sysfs = true;
    }
    if (have_sysfs) return;

    // Fallback: "cpu MHz" lines, which appear in the same order as the online CPUs.
    const text = readFileAlloc(scratch, "/proc/cpuinfo") catch return;
    var i: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (i >= out_khz.len) break;
        if (!std.mem.startsWith(u8, line, "cpu MHz")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const mhz = std.fmt.parseFloat(f64, std.mem.trim(u8, line[colon + 1 ..], " \t")) catch continue;
        out_khz[i] = @intFromFloat(mhz * 1000);
        i += 1;
    }
}

/// Current temperature of a sensor in millidegrees Celsius.
pub fn readTemperature(sensor: Sensor) ?i64 {
    return readInt(i64, sensor.path);
}

/// Parses a kernel CPU list such as "0-3,8,10-11".
pub fn parseCpuList(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    var cpus: std.ArrayList(u32) = .empty;
    errdefer cpus.deinit(gpa);
    var ranges = std.mem.tokenizeScalar(u8, text, ',');
    while (ranges.next()) |range| {
        if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
            const first = try std.fmt.parseInt(u32, range[0..dash], 10);
            const last = try std.fmt.parseInt(u32, range[dash + 1 ..], 10);
            var cpu = first;
            while (cpu <= last) : (cpu += 1) try cpus.append(gpa, cpu);
        } else {
            try cpus.append(gpa, try std.fmt.parseInt(u32, range, 10));
        }
    }
    return cpus.toOwnedSlice(gpa);
}

/// Parses sysfs cache sizes such as "32K" or "8M" into kilobytes.
fn parseSizeKb(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const multiplier: u64 = switch (text[text.len - 1]) {
        'K' => 1,
        'M' => 1024,
        'G' => 1024 * 1024,
        else => return std.fmt.parseInt(u64, text, 10) catch null,
    };
    const value = std.fmt.parseInt(u64, text[0 .. text.len - 1], 10) catch return null;
    return value * multiplier;
}

fn hasWord(list: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, list, ' ');
    while (words.next()) |w| {
        if (eql(w, word)) return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Reads a whole file, including procfs files that report a size of 0.
fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    while (true) {
        try list.ensureUnusedCapacity(gpa, 4096);
        const n = try file.read(list.unusedCapacitySlice());
        if (n == 0) break;
        list.items.len += n;
    }
    return list.toOwnedSlice(gpa);
}

/// Reads a small sysfs file into `buf`, trimmed; null if it cannot be read.
fn readSmall(buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn readStringAlloc(gpa: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var buf: [256]u8 = undefined;
    const value = readSmall(&buf, path) orelse return null;
    return try gpa.dupe(u8, value);
}

fn readInt(comptime T: type, path: []const u8) ?T {
    var buf: [64]u8 = undefined;
    const value = readSmall(&buf, path) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

test parseCpuList {
    const gpa = std.testing.allocator;
    const cpus = try parseCpuList(gpa, "0-3,8,10-11");
    defer gpa.free(cpus);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 8, 10, 11 }, cpus);
}

test parseSizeKb {
    try std.testing.expectEqual(@as(?u64, 32), parseSizeKb("32K"));
    try std.testing.expectEqual(@as(?u64, 32768), parseSizeKb("32M"));
    try std.testing.expectEqual(@as(?u64, null), parseSizeKb(""));
}

test parseCpuinfo {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var info: Info = .{};
    try parseCpuinfo(arena.allocator(), &info,
        \\processor : 0
        \\vendor_id : AuthenticAMD
        \\cpu family : 25
        \\model  : 33
        \\model name : AMD Ryzen 7 5800X 8-Core Processor
        \\flags  : fpu sse sse2 avx2 sha_ni
        \\
        \\processor : 1
        \\model name : ignored
    );
    try std.testing.expectEqualStrings("AMD Ryzen 7 5800X 8-Core Processor", info.model_name);
    try std.testing.expectEqual(@as(?u32, 25), info.family);
    try std.testing.expectEqual(@as(?u32, 33), info.model);
    try std.testing.expectEqual(@as(usize, 4), info.extensions.len);
}
