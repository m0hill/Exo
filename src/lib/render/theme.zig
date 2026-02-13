const std = @import("std");
const style = @import("../style.zig");
const protocol = @import("../protocol/mod.zig");
const theme_engine = @import("theme_engine.zig");

pub const SemanticTokens = struct {
    surface: style.Rgb,
    text: style.Rgb,
    muted: style.Rgb,
    border: style.Rgb,
    accent: style.Rgb,
    success: style.Rgb,
    warn: style.Rgb,
    @"error": style.Rgb,
};

pub const ComponentChrome = struct {
    input_prefix: []const u8 = "> ",
    input_placeholder_left: []const u8 = "[",
    input_placeholder_right: []const u8 = "]",
    list_selected_focused_marker: []const u8 = "> ",
    list_selected_marker: []const u8 = "* ",
    list_unselected_marker: []const u8 = "  ",
    list_selected_inverse: bool = true,
    box_top_left: []const u8 = "┌",
    box_top_right: []const u8 = "┐",
    box_bottom_left: []const u8 = "└",
    box_bottom_right: []const u8 = "┘",
    box_horizontal: []const u8 = "─",
    box_vertical: []const u8 = "│",
};

pub const NodeKind = theme_engine.NodeKind;
pub const StateFlags = theme_engine.StateFlags;
pub const CompiledRule = theme_engine.CompiledRule;
pub const ThemeEngine = theme_engine.ThemeEngine;

pub const VarEntry = struct {
    name: []const u8,
    value: style.Rgb,
};

pub const Theme = struct {
    tokens: SemanticTokens,
    chrome: ComponentChrome = .{},
    vars: []const VarEntry = &.{},
    engine: ThemeEngine,

    pub fn lookupVar(self: Theme, name: []const u8) ?style.Rgb {
        for (self.vars) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn resolveStyleOverrideVars(self: Theme, ov: ?style.StyleOverride) ?style.StyleOverride {
        var out = ov orelse return null;

        out.fg = switch (out.fg) {
            .@"var" => |name| blk: {
                const c = self.lookupVar(name) orelse {
                    logThemeVarMiss(name);
                    break :blk style.ColorOverride.inherit;
                };
                break :blk .{ .rgb = c };
            },
            else => out.fg,
        };
        out.bg = switch (out.bg) {
            .@"var" => |name| blk: {
                const c = self.lookupVar(name) orelse {
                    logThemeVarMiss(name);
                    break :blk style.ColorOverride.inherit;
                };
                break :blk .{ .rgb = c };
            },
            else => out.bg,
        };
        return out;
    }

    pub fn resolveEngineOverride(
        self: Theme,
        kind: NodeKind,
        id: []const u8,
        class: ?[]const u8,
        state_flags: StateFlags,
    ) ?style.StyleOverride {
        return self.resolveStyleOverrideVars(self.engine.resolveOverride(kind, id, class, state_flags));
    }
};

pub const OwnedTheme = struct {
    arena: std.heap.ArenaAllocator,
    theme: Theme,

    pub fn deinit(self: *OwnedTheme) void {
        self.arena.deinit();
    }
};

var theme_var_miss_count: usize = 0;
const theme_var_miss_limit: usize = 64;

fn logThemeVarMiss(name: []const u8) void {
    if (theme_var_miss_count >= theme_var_miss_limit) return;
    theme_var_miss_count += 1;
    std.debug.print("THEME_VAR_MISS name={s}\n", .{name});
}

fn rgb(r: u8, g: u8, b: u8) style.Rgb {
    return .{ .r = r, .g = g, .b = b };
}

fn fg(c: style.Rgb) style.StyleOverride {
    return .{ .fg = .{ .rgb = c } };
}

fn bg(c: style.Rgb) style.StyleOverride {
    return .{ .bg = .{ .rgb = c } };
}

fn fgbg(f: style.Rgb, b: style.Rgb) style.StyleOverride {
    return .{ .fg = .{ .rgb = f }, .bg = .{ .rgb = b } };
}

fn attrs(set: u8, values: u8) style.StyleOverride {
    return .{ .attrs_set = set, .attrs_values = values };
}

const BaseRule = struct {
    kind: NodeKind,
    class: ?[]const u8 = null,
    style: style.StyleOverride = .{},
};

const OverlayRule = struct {
    state_mask: u16,
    style: style.StyleOverride,
};

fn buildBuiltinRules(
    comptime base_rules: []const BaseRule,
    comptime overlay_rules: []const OverlayRule,
) [base_rules.len + overlay_rules.len]CompiledRule {
    var out: [base_rules.len + overlay_rules.len]CompiledRule = undefined;
    var order: u16 = 0;

    for (base_rules, 0..) |rule, idx| {
        const classes: []const []const u8 = if (rule.class) |cls| &.{cls} else &.{};
        out[idx] = .{
            .kind = rule.kind,
            .id = null,
            .classes = classes,
            .states_required = .{},
            .style = rule.style,
            .specificity = if (rule.class != null) 11 else 1,
            .order = order,
        };
        order +%= 1;
    }

    const offset: usize = base_rules.len;
    for (overlay_rules, 0..) |ov, idx| {
        out[offset + idx] = .{
            .kind = null,
            .id = null,
            .classes = &.{},
            .states_required = .{ .bits = ov.state_mask },
            .style = ov.style,
            .specificity = 11,
            .order = order,
        };
        order +%= 1;
    }

    return out;
}

const tokens_default: SemanticTokens = .{
    .surface = rgb(0x0f, 0x17, 0x2a),
    .text = rgb(0xe5, 0xe7, 0xeb),
    .muted = rgb(0x94, 0xa3, 0xb8),
    .border = rgb(0x47, 0x55, 0x69),
    .accent = rgb(0x38, 0xbd, 0xf8),
    .success = rgb(0x22, 0xc5, 0x5e),
    .warn = rgb(0xf5, 0x9e, 0x0b),
    .@"error" = rgb(0xef, 0x44, 0x44),
};

const vars_default = [_]VarEntry{
    .{ .name = "surface", .value = tokens_default.surface },
    .{ .name = "surface_2", .value = rgb(0x11, 0x1b, 0x34) },
    .{ .name = "surface_alt", .value = rgb(0x1e, 0x29, 0x47) },
    .{ .name = "text", .value = tokens_default.text },
    .{ .name = "muted", .value = tokens_default.muted },
    .{ .name = "border", .value = tokens_default.border },
    .{ .name = "accent", .value = tokens_default.accent },
    .{ .name = "success", .value = tokens_default.success },
    .{ .name = "warn", .value = tokens_default.warn },
    .{ .name = "error", .value = tokens_default.@"error" },
};

const base_rules_default = [_]BaseRule{
    .{ .kind = .vbox, .class = "surface", .style = bg(tokens_default.surface) },
    .{ .kind = .hbox, .class = "surface", .style = bg(tokens_default.surface) },
    .{ .kind = .box, .class = "panel", .style = fgbg(tokens_default.border, tokens_default.surface) },
    .{ .kind = .text, .class = "text", .style = fg(tokens_default.text) },
    .{ .kind = .styled_text, .class = "text", .style = fg(tokens_default.text) },
    .{ .kind = .text, .class = "muted", .style = fg(tokens_default.muted) },
    .{ .kind = .styled_text, .class = "muted", .style = fg(tokens_default.muted) },
    .{ .kind = .text, .class = "accent", .style = fg(tokens_default.accent) },
    .{ .kind = .styled_text, .class = "accent", .style = fg(tokens_default.accent) },
    .{ .kind = .input, .class = "field", .style = fgbg(tokens_default.text, rgb(0x11, 0x1b, 0x34)) },
    .{ .kind = .textarea, .class = "field", .style = fgbg(tokens_default.text, rgb(0x11, 0x1b, 0x34)) },
    .{ .kind = .box, .class = "button", .style = fgbg(tokens_default.text, rgb(0x1e, 0x29, 0x47)) },
    .{ .kind = .box, .class = "button.primary", .style = fgbg(rgb(0x06, 0x16, 0x2a), tokens_default.accent) },
    .{ .kind = .box, .class = "button.secondary", .style = fgbg(tokens_default.text, rgb(0x33, 0x41, 0x55)) },
    .{ .kind = .box, .class = "button.subtle", .style = fgbg(tokens_default.muted, tokens_default.surface) },
    .{ .kind = .box, .class = "button.danger", .style = fgbg(rgb(0xff, 0xee, 0xee), tokens_default.@"error") },
    .{ .kind = .box, .class = "button.outline", .style = .{
        .fg = .{ .rgb = tokens_default.accent },
        .attrs_set = style.ATTR_UNDERLINE,
        .attrs_values = style.ATTR_UNDERLINE,
    } },
    .{ .kind = .list, .class = "menu", .style = fg(tokens_default.text) },
    .{ .kind = .list, .class = "table", .style = fg(tokens_default.text) },
    .{ .kind = .text, .class = "table.header", .style = attrs(style.ATTR_BOLD, style.ATTR_BOLD) },
    .{ .kind = .text, .class = "status.success", .style = fg(tokens_default.success) },
    .{ .kind = .text, .class = "status.warn", .style = fg(tokens_default.warn) },
    .{ .kind = .text, .class = "status.error", .style = fg(tokens_default.@"error") },
};

const overlay_rules_default = [_]OverlayRule{
    .{ .state_mask = StateFlags.disabled, .style = attrs(style.ATTR_DIM, style.ATTR_DIM) },
    .{ .state_mask = StateFlags.readonly, .style = attrs(style.ATTR_ITALIC, style.ATTR_ITALIC) },
    .{ .state_mask = StateFlags.validation_error, .style = fg(tokens_default.@"error") },
    .{ .state_mask = StateFlags.validation_warning, .style = fg(tokens_default.warn) },
    .{ .state_mask = StateFlags.validation_success, .style = fg(tokens_default.success) },
    .{ .state_mask = StateFlags.focused, .style = attrs(style.ATTR_BOLD, style.ATTR_BOLD) },
    .{ .state_mask = StateFlags.hovered, .style = bg(rgb(0x1e, 0x29, 0x47)) },
    .{
        .state_mask = StateFlags.active,
        .style = .{
            .bg = .{ .rgb = rgb(0x31, 0x41, 0x64) },
            .attrs_set = style.ATTR_BOLD,
            .attrs_values = style.ATTR_BOLD,
        },
    },
};

const compiled_rules_default = buildBuiltinRules(base_rules_default[0..], overlay_rules_default[0..]);
const engine_indices_default = theme_engine.buildConstIndexData(compiled_rules_default[0..]);
const engine_default: ThemeEngine = theme_engine.buildEngineFromConstIndices(compiled_rules_default[0..], &engine_indices_default);

pub const default_theme: Theme = .{
    .tokens = tokens_default,
    .vars = vars_default[0..],
    .engine = engine_default,
};

const tokens_light: SemanticTokens = .{
    .surface = rgb(0xf8, 0xfa, 0xfc),
    .text = rgb(0x0f, 0x17, 0x2a),
    .muted = rgb(0x47, 0x55, 0x69),
    .border = rgb(0x94, 0xa3, 0xb8),
    .accent = rgb(0x0e, 0x74, 0xaf),
    .success = rgb(0x16, 0xa3, 0x4a),
    .warn = rgb(0xd9, 0x77, 0x06),
    .@"error" = rgb(0xdc, 0x26, 0x26),
};

const vars_light = [_]VarEntry{
    .{ .name = "surface", .value = tokens_light.surface },
    .{ .name = "surface_2", .value = rgb(0xef, 0xf6, 0xff) },
    .{ .name = "surface_alt", .value = rgb(0xe2, 0xe8, 0xf0) },
    .{ .name = "text", .value = tokens_light.text },
    .{ .name = "muted", .value = tokens_light.muted },
    .{ .name = "border", .value = tokens_light.border },
    .{ .name = "accent", .value = tokens_light.accent },
    .{ .name = "success", .value = tokens_light.success },
    .{ .name = "warn", .value = tokens_light.warn },
    .{ .name = "error", .value = tokens_light.@"error" },
};

const base_rules_light = [_]BaseRule{
    .{ .kind = .vbox, .class = "surface", .style = bg(tokens_light.surface) },
    .{ .kind = .hbox, .class = "surface", .style = bg(tokens_light.surface) },
    .{ .kind = .box, .class = "panel", .style = fgbg(tokens_light.border, tokens_light.surface) },
    .{ .kind = .text, .class = "text", .style = fg(tokens_light.text) },
    .{ .kind = .styled_text, .class = "text", .style = fg(tokens_light.text) },
    .{ .kind = .text, .class = "muted", .style = fg(tokens_light.muted) },
    .{ .kind = .styled_text, .class = "muted", .style = fg(tokens_light.muted) },
    .{ .kind = .text, .class = "accent", .style = fg(tokens_light.accent) },
    .{ .kind = .styled_text, .class = "accent", .style = fg(tokens_light.accent) },
    .{ .kind = .input, .class = "field", .style = fgbg(tokens_light.text, rgb(0xef, 0xf6, 0xff)) },
    .{ .kind = .textarea, .class = "field", .style = fgbg(tokens_light.text, rgb(0xef, 0xf6, 0xff)) },
    .{ .kind = .box, .class = "button", .style = fgbg(tokens_light.text, rgb(0xe2, 0xe8, 0xf0)) },
    .{ .kind = .box, .class = "button.primary", .style = fgbg(rgb(0xff, 0xff, 0xff), tokens_light.accent) },
    .{ .kind = .box, .class = "button.secondary", .style = fgbg(tokens_light.text, rgb(0xcb, 0xd5, 0xe1)) },
    .{ .kind = .box, .class = "button.subtle", .style = fgbg(tokens_light.muted, tokens_light.surface) },
    .{ .kind = .box, .class = "button.danger", .style = fgbg(rgb(0xff, 0xff, 0xff), tokens_light.@"error") },
    .{ .kind = .box, .class = "button.outline", .style = .{
        .fg = .{ .rgb = tokens_light.accent },
        .attrs_set = style.ATTR_UNDERLINE,
        .attrs_values = style.ATTR_UNDERLINE,
    } },
    .{ .kind = .list, .class = "menu", .style = fg(tokens_light.text) },
    .{ .kind = .list, .class = "table", .style = fg(tokens_light.text) },
    .{ .kind = .text, .class = "table.header", .style = attrs(style.ATTR_BOLD, style.ATTR_BOLD) },
    .{ .kind = .text, .class = "status.success", .style = fg(tokens_light.success) },
    .{ .kind = .text, .class = "status.warn", .style = fg(tokens_light.warn) },
    .{ .kind = .text, .class = "status.error", .style = fg(tokens_light.@"error") },
};

const overlay_rules_light = [_]OverlayRule{
    .{ .state_mask = StateFlags.disabled, .style = attrs(style.ATTR_DIM, style.ATTR_DIM) },
    .{ .state_mask = StateFlags.readonly, .style = attrs(style.ATTR_ITALIC, style.ATTR_ITALIC) },
    .{ .state_mask = StateFlags.validation_error, .style = fg(tokens_light.@"error") },
    .{ .state_mask = StateFlags.validation_warning, .style = fg(tokens_light.warn) },
    .{ .state_mask = StateFlags.validation_success, .style = fg(tokens_light.success) },
    .{ .state_mask = StateFlags.focused, .style = attrs(style.ATTR_UNDERLINE, style.ATTR_UNDERLINE) },
    .{ .state_mask = StateFlags.hovered, .style = bg(rgb(0xe2, 0xe8, 0xf0)) },
    .{
        .state_mask = StateFlags.active,
        .style = .{
            .bg = .{ .rgb = rgb(0xcb, 0xd5, 0xe1) },
            .attrs_set = style.ATTR_BOLD,
            .attrs_values = style.ATTR_BOLD,
        },
    },
};

const compiled_rules_light = buildBuiltinRules(base_rules_light[0..], overlay_rules_light[0..]);
const engine_indices_light = theme_engine.buildConstIndexData(compiled_rules_light[0..]);
const engine_light: ThemeEngine = theme_engine.buildEngineFromConstIndices(compiled_rules_light[0..], &engine_indices_light);

pub const light_theme: Theme = .{
    .tokens = tokens_light,
    .chrome = .{
        .input_prefix = "· ",
        .list_selected_focused_marker = "› ",
        .list_selected_marker = "+ ",
        .list_unselected_marker = "  ",
        .list_selected_inverse = false,
    },
    .vars = vars_light[0..],
    .engine = engine_light,
};

const tokens_ocean: SemanticTokens = .{
    .surface = rgb(0x06, 0x1b, 0x2d),
    .text = rgb(0xd1, 0xfa, 0xff),
    .muted = rgb(0x67, 0xe8, 0xf9),
    .border = rgb(0x0e, 0x74, 0x90),
    .accent = rgb(0x22, 0xd3, 0xee),
    .success = rgb(0x34, 0xd3, 0x99),
    .warn = rgb(0xfb, 0x92, 0x0a),
    .@"error" = rgb(0xfb, 0x71, 0x71),
};

const vars_ocean = [_]VarEntry{
    .{ .name = "surface", .value = tokens_ocean.surface },
    .{ .name = "surface_2", .value = rgb(0x08, 0x2f, 0x49) },
    .{ .name = "surface_alt", .value = rgb(0x08, 0x3e, 0x5a) },
    .{ .name = "text", .value = tokens_ocean.text },
    .{ .name = "muted", .value = tokens_ocean.muted },
    .{ .name = "border", .value = tokens_ocean.border },
    .{ .name = "accent", .value = tokens_ocean.accent },
    .{ .name = "success", .value = tokens_ocean.success },
    .{ .name = "warn", .value = tokens_ocean.warn },
    .{ .name = "error", .value = tokens_ocean.@"error" },
};

const base_rules_ocean = [_]BaseRule{
    .{ .kind = .vbox, .class = "surface", .style = bg(tokens_ocean.surface) },
    .{ .kind = .hbox, .class = "surface", .style = bg(tokens_ocean.surface) },
    .{ .kind = .box, .class = "panel", .style = fgbg(tokens_ocean.border, tokens_ocean.surface) },
    .{ .kind = .text, .class = "text", .style = fg(tokens_ocean.text) },
    .{ .kind = .styled_text, .class = "text", .style = fg(tokens_ocean.text) },
    .{ .kind = .text, .class = "muted", .style = fg(tokens_ocean.muted) },
    .{ .kind = .styled_text, .class = "muted", .style = fg(tokens_ocean.muted) },
    .{ .kind = .text, .class = "accent", .style = fg(tokens_ocean.accent) },
    .{ .kind = .styled_text, .class = "accent", .style = fg(tokens_ocean.accent) },
    .{ .kind = .input, .class = "field", .style = fgbg(tokens_ocean.text, rgb(0x08, 0x2f, 0x49)) },
    .{ .kind = .textarea, .class = "field", .style = fgbg(tokens_ocean.text, rgb(0x08, 0x2f, 0x49)) },
    .{ .kind = .box, .class = "button", .style = fgbg(tokens_ocean.text, rgb(0x0c, 0x4a, 0x6e)) },
    .{ .kind = .box, .class = "button.primary", .style = fgbg(rgb(0x04, 0x1a, 0x2a), tokens_ocean.accent) },
    .{ .kind = .box, .class = "button.secondary", .style = fgbg(tokens_ocean.text, rgb(0x16, 0x63, 0x84)) },
    .{ .kind = .box, .class = "button.subtle", .style = fgbg(tokens_ocean.muted, tokens_ocean.surface) },
    .{ .kind = .box, .class = "button.danger", .style = fgbg(rgb(0xff, 0xef, 0xef), tokens_ocean.@"error") },
    .{ .kind = .box, .class = "button.outline", .style = .{
        .fg = .{ .rgb = tokens_ocean.accent },
        .attrs_set = style.ATTR_UNDERLINE,
        .attrs_values = style.ATTR_UNDERLINE,
    } },
    .{ .kind = .list, .class = "menu", .style = fg(tokens_ocean.text) },
    .{ .kind = .list, .class = "table", .style = fg(tokens_ocean.text) },
    .{ .kind = .text, .class = "table.header", .style = attrs(style.ATTR_BOLD, style.ATTR_BOLD) },
    .{ .kind = .text, .class = "status.success", .style = fg(tokens_ocean.success) },
    .{ .kind = .text, .class = "status.warn", .style = fg(tokens_ocean.warn) },
    .{ .kind = .text, .class = "status.error", .style = fg(tokens_ocean.@"error") },
};

const overlay_rules_ocean = [_]OverlayRule{
    .{ .state_mask = StateFlags.disabled, .style = attrs(style.ATTR_DIM, style.ATTR_DIM) },
    .{ .state_mask = StateFlags.readonly, .style = attrs(style.ATTR_ITALIC, style.ATTR_ITALIC) },
    .{ .state_mask = StateFlags.validation_error, .style = fg(tokens_ocean.@"error") },
    .{ .state_mask = StateFlags.validation_warning, .style = fg(tokens_ocean.warn) },
    .{ .state_mask = StateFlags.validation_success, .style = fg(tokens_ocean.success) },
    .{ .state_mask = StateFlags.focused, .style = attrs(style.ATTR_BOLD | style.ATTR_UNDERLINE, style.ATTR_BOLD | style.ATTR_UNDERLINE) },
    .{ .state_mask = StateFlags.hovered, .style = bg(rgb(0x08, 0x3e, 0x5a)) },
    .{
        .state_mask = StateFlags.active,
        .style = .{
            .bg = .{ .rgb = rgb(0x0e, 0x5c, 0x82) },
            .attrs_set = style.ATTR_BOLD,
            .attrs_values = style.ATTR_BOLD,
        },
    },
};

const compiled_rules_ocean = buildBuiltinRules(base_rules_ocean[0..], overlay_rules_ocean[0..]);
const engine_indices_ocean = theme_engine.buildConstIndexData(compiled_rules_ocean[0..]);
const engine_ocean: ThemeEngine = theme_engine.buildEngineFromConstIndices(compiled_rules_ocean[0..], &engine_indices_ocean);

pub const ocean_theme: Theme = .{
    .tokens = tokens_ocean,
    .chrome = .{
        .input_prefix = "» ",
        .input_placeholder_left = "⟨",
        .input_placeholder_right = "⟩",
        .list_selected_focused_marker = "» ",
        .list_selected_marker = "• ",
        .list_unselected_marker = "· ",
        .box_top_left = "╭",
        .box_top_right = "╮",
        .box_bottom_left = "╰",
        .box_bottom_right = "╯",
        .box_horizontal = "─",
        .box_vertical = "│",
    },
    .vars = vars_ocean[0..],
    .engine = engine_ocean,
};

pub fn themeFromName(name: protocol.ThemeName) Theme {
    return switch (name) {
        .default => default_theme,
        .light => light_theme,
        .ocean => ocean_theme,
    };
}

fn cloneColorOverride(a: std.mem.Allocator, ov: style.ColorOverride) !style.ColorOverride {
    return switch (ov) {
        .inherit => .inherit,
        .clear => .clear,
        .rgb => |c| .{ .rgb = c },
        .@"var" => |name| .{ .@"var" = try a.dupe(u8, name) },
    };
}

fn cloneStyleOverride(a: std.mem.Allocator, ov: style.StyleOverride) !style.StyleOverride {
    return .{
        .fg = try cloneColorOverride(a, ov.fg),
        .bg = try cloneColorOverride(a, ov.bg),
        .attrs_set = ov.attrs_set,
        .attrs_values = ov.attrs_values,
    };
}

fn appendOverlayRule(
    rules: *std.ArrayList(CompiledRule),
    a: std.mem.Allocator,
    state_mask: u16,
    st: style.StyleOverride,
    order: *u16,
) !void {
    if (st.fg == .inherit and st.bg == .inherit and st.attrs_set == 0) return;
    try rules.append(a, .{
        .kind = null,
        .id = null,
        .classes = &.{},
        .states_required = .{ .bits = state_mask },
        .style = try cloneStyleOverride(a, st),
        .specificity = 11,
        .order = order.*,
    });
    order.* +%= 1;
}

fn appendExistingEngineRules(
    rules: *std.ArrayList(CompiledRule),
    a: std.mem.Allocator,
    existing: ThemeEngine,
    order: *u16,
) !void {
    for (existing.all_rules) |rule| {
        const classes = try a.alloc([]const u8, rule.classes.len);
        for (rule.classes, 0..) |cls, idx| {
            classes[idx] = try a.dupe(u8, cls);
        }
        try rules.append(a, .{
            .kind = rule.kind,
            .id = if (rule.id) |id| try a.dupe(u8, id) else null,
            .classes = classes,
            .states_required = rule.states_required,
            .style = try cloneStyleOverride(a, rule.style),
            .specificity = rule.specificity,
            .order = order.*,
        });
        order.* +%= 1;
    }
}

fn mergeVars(a: std.mem.Allocator, base: []const VarEntry, spec: []const protocol.ThemeVarEntry) ![]VarEntry {
    var out = std.ArrayList(VarEntry).empty;
    for (base) |entry| {
        try out.append(a, .{
            .name = try a.dupe(u8, entry.name),
            .value = entry.value,
        });
    }

    for (spec) |entry| {
        var replaced = false;
        for (out.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, entry.name)) continue;
            existing.value = entry.value;
            replaced = true;
            break;
        }
        if (!replaced) {
            try out.append(a, .{
                .name = try a.dupe(u8, entry.name),
                .value = entry.value,
            });
        }
    }
    return try out.toOwnedSlice(a);
}

fn cloneChrome(a: std.mem.Allocator, chrome: ComponentChrome) !ComponentChrome {
    return .{
        .input_prefix = try a.dupe(u8, chrome.input_prefix),
        .input_placeholder_left = try a.dupe(u8, chrome.input_placeholder_left),
        .input_placeholder_right = try a.dupe(u8, chrome.input_placeholder_right),
        .list_selected_focused_marker = try a.dupe(u8, chrome.list_selected_focused_marker),
        .list_selected_marker = try a.dupe(u8, chrome.list_selected_marker),
        .list_unselected_marker = try a.dupe(u8, chrome.list_unselected_marker),
        .list_selected_inverse = chrome.list_selected_inverse,
        .box_top_left = try a.dupe(u8, chrome.box_top_left),
        .box_top_right = try a.dupe(u8, chrome.box_top_right),
        .box_bottom_left = try a.dupe(u8, chrome.box_bottom_left),
        .box_bottom_right = try a.dupe(u8, chrome.box_bottom_right),
        .box_horizontal = try a.dupe(u8, chrome.box_horizontal),
        .box_vertical = try a.dupe(u8, chrome.box_vertical),
    };
}

pub fn buildThemeFromSpec(
    allocator: std.mem.Allocator,
    current_base: Theme,
    spec: protocol.ThemeSpec,
) !OwnedTheme {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var base = current_base;
    if (spec.base) |name| {
        base = themeFromName(name);
    }

    var out_theme = base;
    out_theme.chrome = try cloneChrome(a, base.chrome);

    out_theme.vars = try mergeVars(a, base.vars, spec.vars);

    if (spec.chrome.input_prefix) |v| out_theme.chrome.input_prefix = try a.dupe(u8, v);
    if (spec.chrome.input_placeholder_left) |v| out_theme.chrome.input_placeholder_left = try a.dupe(u8, v);
    if (spec.chrome.input_placeholder_right) |v| out_theme.chrome.input_placeholder_right = try a.dupe(u8, v);
    if (spec.chrome.list_selected_focused_marker) |v| out_theme.chrome.list_selected_focused_marker = try a.dupe(u8, v);
    if (spec.chrome.list_selected_marker) |v| out_theme.chrome.list_selected_marker = try a.dupe(u8, v);
    if (spec.chrome.list_unselected_marker) |v| out_theme.chrome.list_unselected_marker = try a.dupe(u8, v);
    if (spec.chrome.list_selected_inverse) |v| out_theme.chrome.list_selected_inverse = v;
    if (spec.chrome.box_top_left) |v| out_theme.chrome.box_top_left = try a.dupe(u8, v);
    if (spec.chrome.box_top_right) |v| out_theme.chrome.box_top_right = try a.dupe(u8, v);
    if (spec.chrome.box_bottom_left) |v| out_theme.chrome.box_bottom_left = try a.dupe(u8, v);
    if (spec.chrome.box_bottom_right) |v| out_theme.chrome.box_bottom_right = try a.dupe(u8, v);
    if (spec.chrome.box_horizontal) |v| out_theme.chrome.box_horizontal = try a.dupe(u8, v);
    if (spec.chrome.box_vertical) |v| out_theme.chrome.box_vertical = try a.dupe(u8, v);

    var compiled = std.ArrayList(CompiledRule).empty;
    var order: u16 = 0;

    try appendExistingEngineRules(&compiled, a, base.engine, &order);

    if (spec.overlays.disabled) |st| try appendOverlayRule(&compiled, a, StateFlags.disabled, st, &order);
    if (spec.overlays.readonly) |st| try appendOverlayRule(&compiled, a, StateFlags.readonly, st, &order);
    if (spec.overlays.focused) |st| try appendOverlayRule(&compiled, a, StateFlags.focused, st, &order);
    if (spec.overlays.hovered) |st| try appendOverlayRule(&compiled, a, StateFlags.hovered, st, &order);
    if (spec.overlays.active) |st| try appendOverlayRule(&compiled, a, StateFlags.active, st, &order);
    if (spec.overlays.validation_error) |st| try appendOverlayRule(&compiled, a, StateFlags.validation_error, st, &order);
    if (spec.overlays.validation_warning) |st| try appendOverlayRule(&compiled, a, StateFlags.validation_warning, st, &order);
    if (spec.overlays.validation_success) |st| try appendOverlayRule(&compiled, a, StateFlags.validation_success, st, &order);

    for (spec.rules) |rule| {
        const parsed = try theme_engine.parseSelectorLeaky(a, rule.selector, 256, 8);
        const cloned_classes = try a.alloc([]const u8, parsed.classes.len);
        for (parsed.classes, 0..) |cls, idx| {
            cloned_classes[idx] = try a.dupe(u8, cls);
        }
        try compiled.append(a, .{
            .kind = parsed.kind,
            .id = if (parsed.id) |id| try a.dupe(u8, id) else null,
            .classes = cloned_classes,
            .states_required = parsed.states_required,
            .style = try cloneStyleOverride(a, rule.style),
            .specificity = parsed.specificity,
            .order = order,
        });
        order +%= 1;
    }

    const all_rules = try compiled.toOwnedSlice(a);
    out_theme.engine = try theme_engine.buildEngineLeaky(a, all_rules);

    return .{
        .arena = arena,
        .theme = out_theme,
    };
}
