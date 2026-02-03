const std = @import("std");

pub const Config = struct {
    tick_interval_ms: i32 = 250,
    flood_burst: usize = 1,
    quiet_tx: bool = false,
};

pub fn parseArgs(args: []const []const u8) !Config {
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            std.debug.print(
                "backend_demo usage:\n  --flood (10ms tick, burst=10)\n  --tick-ms <ms>\n  --burst <n>\n  --quiet-tx (suppress PATCH_TX logs)\n",
                .{},
            );
            return cfg;
        }
        if (std.mem.eql(u8, args[i], "--flood")) {
            cfg.tick_interval_ms = 10;
            cfg.flood_burst = 10;
            cfg.quiet_tx = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--tick-ms")) {
            if (i + 1 >= args.len) return error.InvalidArgs;
            i += 1;
            cfg.tick_interval_ms = try std.fmt.parseInt(i32, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, args[i], "--burst")) {
            if (i + 1 >= args.len) return error.InvalidArgs;
            i += 1;
            const n = try std.fmt.parseInt(usize, args[i], 10);
            cfg.flood_burst = if (n == 0) 1 else n;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--quiet-tx")) {
            cfg.quiet_tx = true;
            continue;
        }
    }

    if (cfg.tick_interval_ms < 0) cfg.tick_interval_ms = 0;
    return cfg;
}
