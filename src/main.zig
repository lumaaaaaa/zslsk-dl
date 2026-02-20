const std = @import("std");
const zslsk = @import("zslsk");
const zio = @import("zio");

// constants
const HOST: []const u8 = "server.slsknet.org";
const PORT: u16 = 2242;
const LISTEN_PORT: u16 = 22340;
const DEFAULT_TERM_WIDTH: u16 = 80;

// zslsk-dl application entrypoint
pub fn main(init: std.process.Init) !void {
    // get juicy main args
    const io = init.io;
    const env = init.environ_map;
    const allocator = init.gpa;
    const arena_allocator = init.arena.allocator();

    // try to resolve config directory
    const xdg = env.get("XDG_CONFIG_HOME");
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHomeDir;
    const config_path = if (xdg) |path|
        try std.fs.path.join(allocator, &.{ path, "zslsk-dl", "config.zon" })
    else
        try std.fs.path.join(allocator, &.{ home, ".config", "zslsk-dl", "config.zon" });
    defer allocator.free(config_path);

    // attempt to parse config file
    var config = readConfig(io, arena_allocator, config_path) catch |err| blk: {
        std.log.debug("Could not read config: {}. Using defaults.", .{err});
        break :blk Config{
            .username = null,
            .password = null,
        }; // use default config
    };

    // create zio runtime
    var rt = try zio.Runtime.init(allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    // prompt for credentials if not in config
    if (config.username == null) {
        print(rt, "[input] username: ", .{});
        config.username = try readStdinLine(rt, arena_allocator, true);
    }
    if (config.password == null) {
        print(rt, "[input] password: ", .{});
        config.password = try readStdinLine(rt, arena_allocator, true);
    }

    // initialize zslsk client
    var client = try zslsk.Client.init(allocator);
    defer client.deinit();

    // run application inside zio runtime
    var task = try rt.spawn(app, .{ rt, &client, allocator, config });
    try task.join(rt);

    print(rt, "[info] goodbye!\n", .{});
}

fn app(rt: *zio.Runtime, client: *zslsk.Client, allocator: std.mem.Allocator, config: Config) !void {
    var client_group: zio.Group = .init;
    defer client_group.cancel(rt);
    defer client.disconnect(rt);

    try client_group.spawn(rt, runClient, .{ client, rt, config.username.?, config.password.? });

    // kinda a hack, but sleep without blocking the runtime to allow connection to become established
    while (client.connection_state.load(.seq_cst) != .connected) {
        try rt.sleep(.fromMilliseconds(10));
    }

    print(rt, "[info] login successful. enter desired target metadata:\n", .{});

    print(rt, "[input] artist: ", .{});
    const artist = try readStdinLine(rt, allocator, true);
    defer allocator.free(artist);

    print(rt, "[input] year: ", .{});
    const year = try readStdinLine(rt, allocator, true);
    defer allocator.free(year);

    print(rt, "[input] album: ", .{});
    const album = try readStdinLine(rt, allocator, true);
    defer allocator.free(album);

    print(rt, "[input] additional search terms: ", .{});
    const additional = try readStdinLine(rt, allocator, false);
    defer allocator.free(additional);

    const query = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{ artist, year, album, additional });
    defer allocator.free(query);

    const channel = client.fileSearch(rt, query) catch |err| {
        std.log.err("Could not search network for file: {}", .{err});
        return;
    };

    // build sub path from template
    const sub_path = try formatPath(allocator, config.path_format, artist, album, year);

    processSearchResults(rt, client, allocator, channel, config, sub_path);
}

/// Prints search results from a channel as they come in.
fn processSearchResults(rt: *zio.Runtime, client: *zslsk.Client, allocator: std.mem.Allocator, search_channel: zslsk.SearchChannel, config: Config, sub_path: []const u8) void {
    // zig new std.Io for file operations
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = .empty,
    }); // HACK: short lived std.Io instance because rt.io() panics :(
    defer threaded.deinit();
    const io = threaded.ioBasic();

    // open music library root
    const library_root_dir = std.Io.Dir.cwd().openDir(io, config.library_dir, .{}) catch |err| {
        std.log.err("Could not open library root directory: {}", .{err});
        return;
    };

    // create output directory
    const output_dir = library_root_dir.createDirPathOpen(io, sub_path, .{}) catch |err| {
        std.log.err("Could not create output directory: {}", .{err});
        return;
    };

    while (search_channel.channel.receive(rt)) |msg| {
        defer msg.deinit(allocator);
        print(rt, "== user {s} | count {d} | speed {B}/s ==\n", .{ msg.username, msg.files.len, msg.avg_speed });

        for (msg.files) |file| {
            print(rt, "\t-> {s} ({d}B)\n", .{ file.name, file.size });
        }

        print(rt, "[input] download all? (y/n): ", .{});
        const download_all = readStdinLine(rt, allocator, false) catch |err| {
            std.log.err("Could not read stdin line: {}", .{err});
            return;
        };
        defer allocator.free(download_all);

        if (std.mem.eql(u8, download_all, "y")) {
            for (msg.files) |file| {
                const filename = std.fs.path.basenameWindows(file.name);
                print(rt, "[download] transferring \"{s}\" from \"{s}\"...\n", .{ filename, msg.username });

                // initiate transfer
                var dl_channel = client.downloadFile(rt, msg.username, file.name) catch |err| {
                    std.log.err("[error] could not initiate file transfer: {}", .{err});
                    continue;
                };
                defer dl_channel.deinit(rt, allocator);

                // clock start time
                const start_time = std.time.Instant.now() catch |err| {
                    std.log.err("Could not get start time: {}", .{err});
                    continue;
                };

                // create/open output file
                const output_file = output_dir.createFile(io, filename, .{ .truncate = true }) catch |err| {
                    std.log.err("Could not create output file: {}", .{err});
                    continue;
                };
                defer output_file.close(io);

                // get file writer
                var write_buf: [4096]u8 = undefined;
                var writer = output_file.writer(io, &write_buf);

                // get terminal size for progress bar
                const term_width = getTerminalWidth() orelse DEFAULT_TERM_WIDTH;
                const bar_width = term_width - 24; // padding + borders + pct
                const progress_step = if (dl_channel.size > bar_width) dl_channel.size / bar_width else 1;

                // receive bytes from channel until closed
                var read: u64 = 0;
                while (read < dl_channel.size) {
                    // attempt to receive a byte
                    const byte = dl_channel.channel.receive(rt) catch |err| {
                        print(rt, "\n[error] could not receive downloaded data: {}", .{err});
                        break;
                    };

                    read += 1;

                    // flush write_buf when full or done
                    writer.interface.writeByte(byte) catch |err| {
                        std.log.err("Could not write to file: {}", .{err});
                        break;
                    };

                    // print progress bar if there's a bar update
                    if (read % progress_step == 0 or read == dl_channel.size) {
                        // progress bar math
                        const pct = (@as(f64, @floatFromInt(read)) / @as(f64, @floatFromInt(dl_channel.size))) * 100.0;
                        const filled = (read * bar_width) / dl_channel.size;
                        const vacant = bar_width - filled;
                        // speed calculation
                        const current_time = std.time.Instant.now() catch |err| {
                            std.log.err("Could not get current time: {}", .{err});
                            continue;
                        };
                        const elapsed_ns = current_time.since(start_time);
                        const elapsed_secs = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
                        const mb_read = (@as(f64, @floatFromInt(read)) / (1024 * 1024));
                        const speed_mbps = mb_read / elapsed_secs;

                        // build bar
                        var bar: [1024]u8 = undefined;
                        var pos: usize = 0;

                        // filled
                        const fill_char = "\u{2588}";
                        for (0..filled) |_| {
                            @memcpy(bar[pos..][0..fill_char.len], fill_char);
                            pos += fill_char.len;
                        }

                        // vacant
                        const vacant_char = "\u{2591}";
                        for (0..vacant) |_| {
                            @memcpy(bar[pos..][0..vacant_char.len], vacant_char);
                            pos += vacant_char.len;
                        }

                        print(rt, "\r \u{2590}{s}\u{258C} {d:.1}% {d:.2} MB/s ", .{
                            bar,
                            pct,
                            speed_mbps,
                        });
                    }
                }
                writer.interface.flush() catch |err| {
                    std.log.err("Could not flush file writer: {}", .{err});
                    continue;
                };
                print(rt, "\n", .{});
            }
            return;
        }
    } else |err| switch (err) {
        error.ChannelClosed => print(rt, "Search complete.\n", .{}),
        else => std.log.err("Failed to receive from channel: {}", .{err}),
    }
}

/// Begins running the client.
fn runClient(client: *zslsk.Client, rt: *zio.Runtime, username: []const u8, password: []const u8) void {
    client.run(rt, HOST, PORT, username, password, LISTEN_PORT) catch |err| {
        std.log.err("Client error: {}", .{err});
    };
}

/// Represents configuration data for the zslsk-dl application
const Config = struct {
    // credentials, if specified will skip prompt
    username: ?[]const u8,
    password: ?[]const u8,

    // library configuration
    library_dir: []const u8 = ".", // defaults to cwd
    path_format: []const u8 = "{artist}/[{year}] {album}", // defaults to what I like ;)
};

/// Reads a zslsk-dl config file from the default location.
fn readConfig(io: std.Io, allocator: std.mem.Allocator, config_path: []const u8) !Config {
    // read config file
    const cfg_file = try std.Io.Dir.cwd().readFileAllocOptions(io, config_path, allocator, .limited(4096), .@"1", 0);
    defer allocator.free(cfg_file);

    // parse to config type
    return try std.zon.parse.fromSliceAlloc(Config, allocator, cfg_file, null, .{ .ignore_unknown_fields = true });
}

/// Fills in a path template.
fn formatPath(allocator: std.mem.Allocator, template: []const u8, artist: []const u8, album: []const u8, year: []const u8) ![]u8 {
    var result = try allocator.dupe(u8, template);
    inline for (.{
        .{ "{artist}", artist },
        .{ "{year}", year },
        .{ "{album}", album },
    }) |pair| {
        const replaced = try std.mem.replaceOwned(u8, allocator, result, pair[0], pair[1]);
        allocator.free(result);
        result = replaced;
    }
    return result;
}

/// Helper function to non-blocking print to stdout.
fn print(rt: *zio.Runtime, comptime fmt: []const u8, args: anytype) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = zio.File.fromFd(std.posix.STDOUT_FILENO).writer(rt, &stdout_buffer);
    const writer_interface = &stdout_writer.interface;

    writer_interface.print(fmt, args) catch |err| {
        std.debug.print("Failed to print string to stdout: .{}\n", .{err});
    };
    writer_interface.flush() catch |err| {
        std.debug.print("Failed to flush stdout: .{}\n", .{err});
    };
}

/// Helper function to non-blocking read a single line from stdin.
pub fn readStdinLine(rt: *zio.Runtime, allocator: std.mem.Allocator, required: bool) ![]const u8 {
    var stdin_buffer: [128]u8 = undefined;
    var stdin_reader = zio.File.fromFd(std.posix.STDIN_FILENO).reader(rt, &stdin_buffer);
    const reader_interface = &stdin_reader.interface;

    // read a line from stdin
    const line = try reader_interface.takeDelimiterExclusive('\n');

    // if required, check that input validity
    if (required and line.len == 0) return error.EmptyInput;

    // return a copy
    return allocator.dupe(u8, line);
}

/// Helper function to get terminal size (POSIX).
fn getTerminalWidth() ?u16 {
    var winsize = std.posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rv = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));

    if (rv == 0) {
        if (winsize.row == 0 or winsize.col == 0) {
            return null; // maybe not TTY, invalid result
        }
        return winsize.col;
    }

    // just return null if error, caller should default to some value
    return null;
}
