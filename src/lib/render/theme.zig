const style = @import("../style.zig");
const protocol = @import("../protocol/mod.zig");

pub const Overlay = struct {
    fg: ?style.Rgb = null,
    bg: ?style.Rgb = null,
    attrs_set: u8 = 0,
    attrs_values: u8 = 0,
};

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

pub const NodeKind = enum {
    vbox,
    hbox,
    grid,
    box,
    scroll,
    overlay,
    text,
    styled_text,
    input,
    textarea,
    list,
};

pub const ClassRule = struct {
    kind: NodeKind,
    class: ?[]const u8 = null,
    style: style.StyleOverride = .{},
};

pub const Theme = struct {
    tokens: SemanticTokens,
    chrome: ComponentChrome = .{},
    disabled_overlay: Overlay,
    readonly_overlay: Overlay,
    validation_error_overlay: Overlay,
    validation_warning_overlay: Overlay,
    validation_success_overlay: Overlay,
    focused_overlay: Overlay,
    hovered_overlay: Overlay,
    active_overlay: Overlay,
    rules: []const ClassRule,

    pub fn resolveBaseStyleOverride(self: Theme, kind: NodeKind, class: ?[]const u8) ?style.StyleOverride {
        if (class) |cls| {
            for (self.rules) |rule| {
                if (rule.kind != kind) continue;
                if (rule.class) |rcls| {
                    if (std.mem.eql(u8, rcls, cls)) return rule.style;
                }
            }
        }
        for (self.rules) |rule| {
            if (rule.kind != kind) continue;
            if (rule.class == null) return rule.style;
        }
        return null;
    }
};

const std = @import("std");

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

const rules_default = [_]ClassRule{
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

pub const default_theme: Theme = .{
    .tokens = tokens_default,
    .disabled_overlay = .{
        .attrs_set = style.ATTR_DIM,
        .attrs_values = style.ATTR_DIM,
    },
    .readonly_overlay = .{
        .attrs_set = style.ATTR_ITALIC,
        .attrs_values = style.ATTR_ITALIC,
    },
    .validation_error_overlay = .{ .fg = tokens_default.@"error" },
    .validation_warning_overlay = .{ .fg = tokens_default.warn },
    .validation_success_overlay = .{ .fg = tokens_default.success },
    .focused_overlay = .{
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    },
    .hovered_overlay = .{ .bg = rgb(0x1e, 0x29, 0x47) },
    .active_overlay = .{
        .bg = rgb(0x31, 0x41, 0x64),
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    },
    .rules = rules_default[0..],
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

const rules_light = [_]ClassRule{
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

pub const light_theme: Theme = .{
    .tokens = tokens_light,
    .chrome = .{
        .input_prefix = "· ",
        .list_selected_focused_marker = "› ",
        .list_selected_marker = "+ ",
        .list_unselected_marker = "  ",
        .list_selected_inverse = false,
    },
    .disabled_overlay = .{
        .attrs_set = style.ATTR_DIM,
        .attrs_values = style.ATTR_DIM,
    },
    .readonly_overlay = .{
        .attrs_set = style.ATTR_ITALIC,
        .attrs_values = style.ATTR_ITALIC,
    },
    .validation_error_overlay = .{ .fg = tokens_light.@"error" },
    .validation_warning_overlay = .{ .fg = tokens_light.warn },
    .validation_success_overlay = .{ .fg = tokens_light.success },
    .focused_overlay = .{
        .attrs_set = style.ATTR_UNDERLINE,
        .attrs_values = style.ATTR_UNDERLINE,
    },
    .hovered_overlay = .{ .bg = rgb(0xe2, 0xe8, 0xf0) },
    .active_overlay = .{
        .bg = rgb(0xcb, 0xd5, 0xe1),
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    },
    .rules = rules_light[0..],
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

const rules_ocean = [_]ClassRule{
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
    .disabled_overlay = .{
        .attrs_set = style.ATTR_DIM,
        .attrs_values = style.ATTR_DIM,
    },
    .readonly_overlay = .{
        .attrs_set = style.ATTR_ITALIC,
        .attrs_values = style.ATTR_ITALIC,
    },
    .validation_error_overlay = .{ .fg = tokens_ocean.@"error" },
    .validation_warning_overlay = .{ .fg = tokens_ocean.warn },
    .validation_success_overlay = .{ .fg = tokens_ocean.success },
    .focused_overlay = .{
        .attrs_set = style.ATTR_BOLD | style.ATTR_UNDERLINE,
        .attrs_values = style.ATTR_BOLD | style.ATTR_UNDERLINE,
    },
    .hovered_overlay = .{ .bg = rgb(0x08, 0x3e, 0x5a) },
    .active_overlay = .{
        .bg = rgb(0x0e, 0x5c, 0x82),
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    },
    .rules = rules_ocean[0..],
};

pub fn themeFromName(name: protocol.ThemeName) Theme {
    return switch (name) {
        .default => default_theme,
        .light => light_theme,
        .ocean => ocean_theme,
    };
}
