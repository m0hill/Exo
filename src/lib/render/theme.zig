const style = @import("../style.zig");

pub const Overlay = struct {
    fg: ?style.Rgb = null,
    bg: ?style.Rgb = null,
    attrs_set: u8 = 0,
    attrs_values: u8 = 0,
};

pub const Theme = struct {
    disabled_overlay: Overlay,
    readonly_overlay: Overlay,
    validation_error_overlay: Overlay,
    validation_warning_overlay: Overlay,
    validation_success_overlay: Overlay,
    focused_overlay: Overlay,
    hovered_overlay: Overlay,
    active_overlay: Overlay,
};

pub const default_theme: Theme = .{
    .disabled_overlay = .{
        .attrs_set = style.ATTR_DIM,
        .attrs_values = style.ATTR_DIM,
    },
    .readonly_overlay = .{
        .attrs_set = style.ATTR_ITALIC,
        .attrs_values = style.ATTR_ITALIC,
    },
    .validation_error_overlay = .{
        .fg = .{ .r = 0xef, .g = 0x44, .b = 0x44 },
    },
    .validation_warning_overlay = .{
        .fg = .{ .r = 0xf5, .g = 0x9e, .b = 0x0b },
    },
    .validation_success_overlay = .{
        .fg = .{ .r = 0x22, .g = 0xc5, .b = 0x5e },
    },
    .focused_overlay = .{
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    },
    .hovered_overlay = .{
        .bg = .{ .r = 0x11, .g = 0x18, .b = 0x27 },
    },
    .active_overlay = .{
        .bg = .{ .r = 0x1f, .g = 0x29, .b = 0x37 },
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    },
};
