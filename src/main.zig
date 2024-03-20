const std = @import("std");
const os = std.os;

const RESET: *const [4:0]u8 = "\x1b[0m";
const BOLD: *const [4:0]u8 = "\x1b[1m";
const RED: *const [5:0]u8 = "\x1b[31m";
const GREEN: *const [5:0]u8 = "\x1b[32m";
const YELLOW: *const [5:0]u8 = "\x1b[33m";
const BLUE: *const [5:0]u8 = "\x1b[34m";
const CYAN: *const [5:0]u8 = "\x1b[36m";

const ACPI_CALL_PATH = "/proc/acpi/call";
const UPDATE_INTERVAL_IN_NANOSECS: u64 = 1000 * 1000 * 1000 * 10;

const Coordinates = struct {
    x: u8,
    y: u8,
};

const TempFanGraph: [7]Coordinates = .{
    Coordinates{ .x = 0, .y = 0 },
    Coordinates{ .x = 47, .y = 0 },
    Coordinates{ .x = 48, .y = 38 },
    Coordinates{ .x = 50, .y = 64 },
    Coordinates{ .x = 55, .y = 100 },
    Coordinates{ .x = 60, .y = 128 },
    Coordinates{ .x = 65, .y = 130 },
};

const AlienDevInfo = struct {
    fan_id: u8,
    sen_id: u8,
    name: *const [3:0]u8,
};

const CPU_ALIEN_DEVICE: AlienDevInfo = AlienDevInfo{
    .fan_id = 50,
    .sen_id = 1,
    .name = "CPU",
};

const GPU_ALIEN_DEVICE: AlienDevInfo = AlienDevInfo{
    .fan_id = 51,
    .sen_id = 6,
    .name = "GPU",
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const command = args.next().?;
    if (std.mem.eql(u8, command, "watch")) {
        var exit_flag = std.atomic.Atomic(bool).init(false);
        const thread = try std.Thread.spawn(.{}, watch, .{&exit_flag});
        var reader = std.io.getStdIn().reader();
        var buf: [32]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            if (line.len == 0) {
                continue;
            }
            if (std.mem.eql(u8, line, "q")) {
                break;
            } else {
                try std.io.getStdErr().writer().print("Unknown command '{s}'\n", .{line});
            }
        }

        try std.io.getStdOut().writer().print("Exiting gracefully\n", .{});
        exit_flag.store(true, std.atomic.Ordering.SeqCst);

        thread.join();
    } else if (std.mem.eql(u8, command, "fans")) {
        var bufferWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
        const w = bufferWriter.writer();
        const arg = args.next();
        try w.print("{s}\n", .{CPU_ALIEN_DEVICE.name});
        _ = try print_fan_info(CPU_ALIEN_DEVICE.fan_id, &w);
        try w.print("{s}\n", .{GPU_ALIEN_DEVICE.name});
        _ = try print_fan_info(GPU_ALIEN_DEVICE.fan_id, &w);
        if (arg != null) {
            const boost = try std.fmt.parseInt(u8, arg.?, 10);
            try set_fan_boosts(boost, &w);
        }

        try bufferWriter.flush();
    } else if (std.mem.eql(u8, command, "mode")) {
        const arg = args.next();
        const mode = try get_power_mode();
        var bufferWriter = std.io.bufferedWriter(std.io.getStdOut().writer());
        const w = bufferWriter.writer();
        const readableMode = if (mode == 0xab) "gmode" else "normal";
        try w.print("Current Power Mode: {s}\n", .{readableMode});
        if (arg != null) {
            const set_mode_to = arg.?;
            if (std.mem.eql(u8, set_mode_to, "gmode")) {
                const result = try enable_gmode();
                try w.print("Enabled Gmode {}\n", .{result});
            } else {
                const result = try disable_gmode();
                try w.print("Disabled Gmode {}\n", .{result});
            }
        }

        try bufferWriter.flush();
    } else {
        try print_usage();
    }
}

pub fn print_usage() !void {
    var buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = buffer.writer();

    try w.print("Usage: \n", .{});
    try w.print("\tawc [COMMAND] [ARGUMENT] \n", .{});
    try w.print("COMMANDS: \n", .{});
    try w.print("\t mode [gmode | normal | ]    - switch to gmode or normal, or prints current mode if no mode is passed \n", .{});
    try w.print("\t watch                       - watch sensors and control fans automatically, the configuration of the relation between temparature and fan boost can be updated in main.zig\n", .{});
    try w.print("\t fans [boost | ]             - set all fan boosts, or prints current fan boosts, if no boost value passed\n", .{});

    try buffer.flush();
}

pub fn print_fan_info(fan_id: u8, w: anytype) anyerror!u8 {
    const boost = try get_fan_boost(fan_id);
    const rpm = try get_fan_rpm(fan_id);
    try w.print("\tBoost {s}{}{s}\n", .{ YELLOW, boost, RESET });
    try w.print("\tRPM   {s}{}{s}\n", .{ GREEN, rpm, RESET });
    return boost;
}

pub fn watch(exit_flag: *std.atomic.Atomic(bool)) anyerror!void {
    const power_mode = try get_power_mode();
    var buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = buf.writer();
    try w.print("Power Mode: {}\n", .{power_mode});
    if (0 != power_mode) {
        return error.PowerModeIsEnabled;
    }
    try w.print("Watching Temperatures...\n", .{});
    while (true) {
        _ = try update_device(&CPU_ALIEN_DEVICE, &w);
        _ = try update_device(&GPU_ALIEN_DEVICE, &w);
        try w.print("\n", .{});
        try buf.flush();
        const start = try std.time.Instant.now();
        while (true) {
            std.time.sleep(20 * std.time.ns_per_ms);
            if (exit_flag.load(std.atomic.Ordering.SeqCst)) {
                try set_fan_boosts(0, &w);
                try buf.flush();
                return;
            }
            const now = try std.time.Instant.now();
            if (now.since(start) >= UPDATE_INTERVAL_IN_NANOSECS) {
                break;
            }
        }
    }
}

fn set_fan_boost_and_print(fan_id: u8, boost: u8, writer: anytype) anyerror!void {
    const result = try set_fan_boost(fan_id, boost);
    try writer.print("\tSet Fan Boost To {s}{}{s} result {s}{}{s}\n", .{
        BOLD,
        boost,
        RESET,
        CYAN,
        result,
        RESET,
    });
}

fn set_fan_boosts(boost: u8, writer: anytype) anyerror!void {
    try set_fan_boost_and_print(CPU_ALIEN_DEVICE.fan_id, boost, writer);
    try set_fan_boost_and_print(GPU_ALIEN_DEVICE.fan_id, boost, writer);
}

fn update_device(device: *const AlienDevInfo, writer: anytype) anyerror!void {
    const w = writer;
    const temp = try get_temperature(device.sen_id);
    const timestamp = std.time.milliTimestamp();
    try w.print("{} Device {s}\n", .{ timestamp, device.name });
    try w.print("\tSensor Temperature: {}\n", .{temp});
    for (TempFanGraph) |coord| {
        if (temp < coord.x) {
            const fan_boost = coord.y;
            const current_fan_boost = try print_fan_info(device.fan_id, w);
            // const current_fan_boost = try get_fan_boost(device.fan_id);
            // const current_fan_rpm = try get_fan_rpm(device.fan_id);
            // try w.print("\tBoost {s}{}{s}\n", .{ YELLOW, current_fan_boost, RESET });
            // try w.print("\tRPM   {s}{}{s}\n", .{ GREEN, current_fan_rpm, RESET });
            if (current_fan_boost != fan_boost) {
                try set_fan_boost_and_print(device.fan_id, fan_boost, w);
                // const result = try set_fan_boost(device.fan_id, fan_boost);
                // try w.print("\tSet Fan Boost To {s}{}{s} result {s}{}{s}\n", .{
                //     BOLD,
                //     fan_boost,
                //     RESET,
                //     CYAN,
                //     result,
                //     RESET,
                // });
            }
            break;
        }
    }
}

fn get_fan_rpm(fan_id: u8) anyerror!i64 {
    return try run_main_command(0x14, 5, fan_id, 0);
}
fn get_fan_boost(fan_id: u8) anyerror!u8 {
    return @intCast(try run_main_command(0x14, 0xc, fan_id, 0));
}

fn set_fan_boost(fan_id: u8, value: u8) anyerror!i64 {
    return try run_main_command(0x15, 2, fan_id, value);
}

fn get_power_mode() anyerror!i64 {
    return try run_main_command(0x14, 0xb, 0, 0);
}

fn enable_gmode() anyerror!i64 {
    return try set_power_mode(0xab);
}

fn disable_gmode() anyerror!i64 {
    return try set_power_mode(0);
}

fn set_power_mode(mode: u8) anyerror!i64 {
    return try run_main_command(0x15, 1, mode, 0);
}

fn toggle_gmode(mode: u8) anyerror!i64 {
    return try run_main_command(0x25, 1, mode, 0);
}

fn get_temperature(sensor_id: u8) anyerror!i64 {
    return try run_main_command(0x14, 4, sensor_id, 0);
}

fn run_main_command(cmd: u8, sub: u8, arg0: u8, arg1: u8) anyerror!i64 {
    var buffer: [128]u8 = undefined;
    const acpi_cmd = try std.fmt.bufPrint(&buffer, "\\_SB.AMW3.WMAX 0 {} {{ {}, {}, {}, 0 }}", .{ cmd, sub, arg0, arg1 });

    return try run_command(acpi_cmd);
}

pub fn run_command(cmd: []u8) anyerror!i64 {
    // std.debug.print("Running {s}\n", .{cmd});
    var file = try std.fs.openFileAbsolute(ACPI_CALL_PATH, .{ .mode = .read_write });
    defer file.close();
    try file.writeAll(cmd);
    var buffer: [32]u8 = undefined;
    const bytesRead = try file.readAll(&buffer);
    var result = buffer[0..bytesRead];
    if (buffer[bytesRead - 1] == 0) {
        result = buffer[0 .. bytesRead - 1];
    }
    // std.debug.print("\nresult of {s} '{s}', {} \n", .{ cmd, result, bytesRead });
    var value = try std.fmt.parseInt(i64, result, 0);

    return value;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
