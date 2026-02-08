const std = @import("std");

const color_mod = @import("color.zig");

pub const ColorMode = color_mod.ColorMode;

pub const Caps = struct {
    ansi: bool = true,
    cursor_address: bool = true,
    clear_screen: bool = true,
    erase_eol: bool = true,
    alt_screen: bool = true,
    cursor_visibility: bool = true,
    /// XTerm synchronized output (DECSET 2026). When supported, this prevents
    /// visible intermediate states during large repaints (e.g. resize).
    sync_output: bool = true,
    bracketed_paste: bool = true,
    mouse_sgr: bool = true,
    osc52: bool = true,
    color: ColorMode = .ansi16,
    tmux: bool = false,
    screen: bool = false,
};

pub const Profile = enum {
    dumb,
    xterm,
    screen,
    tmux,
    alacritty,
    kitty,
    wezterm,
    vscode,
    iterm2,
    windows_terminal,
};

fn getenvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

fn envPresent(allocator: std.mem.Allocator, name: []const u8) bool {
    const v = getenvOwned(allocator, name) orelse return false;
    allocator.free(v);
    return true;
}

fn profileFromString(s: []const u8) ?Profile {
    if (std.mem.eql(u8, s, "dumb")) return .dumb;
    if (std.mem.eql(u8, s, "xterm")) return .xterm;
    if (std.mem.eql(u8, s, "screen") or std.mem.eql(u8, s, "screen-256color")) return .screen;
    if (std.mem.eql(u8, s, "tmux") or std.mem.eql(u8, s, "tmux-256color")) return .tmux;
    if (std.mem.eql(u8, s, "alacritty")) return .alacritty;
    if (std.mem.eql(u8, s, "kitty")) return .kitty;
    if (std.mem.eql(u8, s, "wezterm")) return .wezterm;
    if (std.mem.eql(u8, s, "vscode")) return .vscode;
    if (std.mem.eql(u8, s, "iterm2")) return .iterm2;
    if (std.mem.eql(u8, s, "windows-terminal") or std.mem.eql(u8, s, "windows_terminal")) return .windows_terminal;
    return null;
}

fn defaultCapsForProfile(p: Profile) Caps {
    return switch (p) {
        .dumb => .{
            .ansi = false,
            .cursor_address = false,
            .clear_screen = false,
            .erase_eol = false,
            .alt_screen = false,
            .cursor_visibility = false,
            .sync_output = false,
            .bracketed_paste = false,
            .mouse_sgr = false,
            .osc52 = false,
            .color = .mono,
        },
        .screen => .{
            .ansi = true,
            .cursor_address = true,
            .clear_screen = true,
            .erase_eol = true,
            .alt_screen = true,
            .cursor_visibility = true,
            .sync_output = true,
            .bracketed_paste = true,
            .mouse_sgr = true,
            .osc52 = true,
        },
        .tmux => .{
            .ansi = true,
            .cursor_address = true,
            .clear_screen = true,
            .erase_eol = true,
            .alt_screen = true,
            .cursor_visibility = true,
            .sync_output = true,
            .bracketed_paste = true,
            .mouse_sgr = true,
            .osc52 = true,
        },
        else => .{
            .ansi = true,
            .cursor_address = true,
            .clear_screen = true,
            .erase_eol = true,
            .alt_screen = true,
            .cursor_visibility = true,
            .sync_output = true,
            .bracketed_paste = true,
            .mouse_sgr = true,
            .osc52 = true,
        },
    };
}

pub fn detectProfile(allocator: std.mem.Allocator, is_windows: bool) Profile {
    if (getenvOwned(allocator, "TUI_TERM_PROFILE")) |v| {
        defer allocator.free(v);
        if (profileFromString(v)) |p| return p;
    }

    if (is_windows) return .windows_terminal;

    // Multiplexers first: they can sit in front of many TERM values.
    if (envPresent(allocator, "TMUX")) return .tmux;
    if (envPresent(allocator, "STY")) return .screen;

    if (getenvOwned(allocator, "TERM_PROGRAM")) |tp| {
        defer allocator.free(tp);
        if (std.mem.eql(u8, tp, "vscode")) return .vscode;
        if (std.mem.eql(u8, tp, "WezTerm")) return .wezterm;
        if (std.mem.eql(u8, tp, "iTerm.app")) return .iterm2;
        if (std.mem.eql(u8, tp, "Apple_Terminal")) return .xterm;
    }

    if (getenvOwned(allocator, "TERM")) |term| {
        defer allocator.free(term);
        if (profileFromString(term)) |p| return p;
        if (std.mem.eql(u8, term, "dumb")) return .dumb;
        if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
        if (std.mem.indexOf(u8, term, "alacritty") != null) return .alacritty;
        if (std.mem.indexOf(u8, term, "wezterm") != null) return .wezterm;
        if (std.mem.startsWith(u8, term, "screen")) return .screen;
        if (std.mem.startsWith(u8, term, "tmux")) return .tmux;
        if (std.mem.startsWith(u8, term, "xterm")) return .xterm;
    }

    return .xterm;
}

pub fn detectCaps(allocator: std.mem.Allocator, is_windows: bool) Caps {
    const profile = detectProfile(allocator, is_windows);
    var caps = defaultCapsForProfile(profile);

    caps.tmux = envPresent(allocator, "TMUX");
    caps.screen = envPresent(allocator, "STY");
    caps.color = color_mod.detectColorMode();
    if (!caps.ansi) caps.color = .mono;

    applyCapsDisableEnv(allocator, &caps);
    return caps;
}

fn disableField(caps: *Caps, name: []const u8) void {
    if (std.mem.eql(u8, name, "ansi")) caps.ansi = false;
    if (std.mem.eql(u8, name, "cursor_address")) caps.cursor_address = false;
    if (std.mem.eql(u8, name, "clear_screen")) caps.clear_screen = false;
    if (std.mem.eql(u8, name, "erase_eol")) caps.erase_eol = false;
    if (std.mem.eql(u8, name, "altscreen") or std.mem.eql(u8, name, "alt_screen")) caps.alt_screen = false;
    if (std.mem.eql(u8, name, "cursor") or std.mem.eql(u8, name, "cursor_visibility")) caps.cursor_visibility = false;
    if (std.mem.eql(u8, name, "sync_output") or std.mem.eql(u8, name, "sync")) caps.sync_output = false;
    if (std.mem.eql(u8, name, "bracketed_paste") or std.mem.eql(u8, name, "paste")) caps.bracketed_paste = false;
    if (std.mem.eql(u8, name, "mouse") or std.mem.eql(u8, name, "mouse_sgr")) caps.mouse_sgr = false;
    if (std.mem.eql(u8, name, "osc52")) caps.osc52 = false;
    if (std.mem.eql(u8, name, "colors") or std.mem.eql(u8, name, "color")) caps.color = .mono;
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn applyCapsDisableEnv(allocator: std.mem.Allocator, caps: *Caps) void {
    const v = getenvOwned(allocator, "TUI_CAPS_DISABLE") orelse return;
    defer allocator.free(v);

    applyCapsDisableString(caps, v);
}

fn applyCapsDisableString(caps: *Caps, v: []const u8) void {
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |part| {
        const name = trimSpaces(part);
        if (name.len == 0) continue;
        disableField(caps, name);
    }
}

/// Test/helper API: detect a profile from a string-keyed env map.
///
/// `env` must provide:
/// - `get([]const u8) ?[]const u8`
/// - `contains([]const u8) bool`
pub fn detectProfileFromMap(env: anytype, is_windows: bool) Profile {
    if (env.get("TUI_TERM_PROFILE")) |v| {
        if (profileFromString(v)) |p| return p;
    }

    if (is_windows) return .windows_terminal;

    if (env.contains("TMUX")) return .tmux;
    if (env.contains("STY")) return .screen;

    if (env.get("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "vscode")) return .vscode;
        if (std.mem.eql(u8, tp, "WezTerm")) return .wezterm;
        if (std.mem.eql(u8, tp, "iTerm.app")) return .iterm2;
        if (std.mem.eql(u8, tp, "Apple_Terminal")) return .xterm;
    }

    if (env.get("TERM")) |term| {
        if (profileFromString(term)) |p| return p;
        if (std.mem.eql(u8, term, "dumb")) return .dumb;
        if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
        if (std.mem.indexOf(u8, term, "alacritty") != null) return .alacritty;
        if (std.mem.indexOf(u8, term, "wezterm") != null) return .wezterm;
        if (std.mem.startsWith(u8, term, "screen")) return .screen;
        if (std.mem.startsWith(u8, term, "tmux")) return .tmux;
        if (std.mem.startsWith(u8, term, "xterm")) return .xterm;
    }

    return .xterm;
}

/// Test/helper API: detect caps from a string-keyed env map.
///
/// `env` must provide:
/// - `get([]const u8) ?[]const u8`
/// - `contains([]const u8) bool`
pub fn detectCapsFromMap(env: anytype, is_windows: bool, color_mode: ColorMode) Caps {
    const profile = detectProfileFromMap(env, is_windows);
    var caps = defaultCapsForProfile(profile);
    caps.tmux = env.contains("TMUX");
    caps.screen = env.contains("STY");
    caps.color = color_mode;
    if (!caps.ansi) caps.color = .mono;

    if (env.get("TUI_CAPS_DISABLE")) |v| {
        applyCapsDisableString(&caps, v);
    }
    return caps;
}
