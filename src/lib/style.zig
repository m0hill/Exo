const std = @import("std");
const color = @import("color.zig");

pub const Rgb = color.Rgb;
pub const ColorMode = color.ColorMode;

pub const Attr = enum(u3) {
    bold,
    dim,
    italic,
    underline,
    blink,
    inverse,
    hidden,
    strikethrough,
};

pub const ATTR_BOLD: u8 = 1 << @intFromEnum(Attr.bold);
pub const ATTR_DIM: u8 = 1 << @intFromEnum(Attr.dim);
pub const ATTR_ITALIC: u8 = 1 << @intFromEnum(Attr.italic);
pub const ATTR_UNDERLINE: u8 = 1 << @intFromEnum(Attr.underline);
pub const ATTR_BLINK: u8 = 1 << @intFromEnum(Attr.blink);
pub const ATTR_INVERSE: u8 = 1 << @intFromEnum(Attr.inverse);
pub const ATTR_HIDDEN: u8 = 1 << @intFromEnum(Attr.hidden);
pub const ATTR_STRIKETHROUGH: u8 = 1 << @intFromEnum(Attr.strikethrough);

pub const ATTR_AFFECTS_BLANK: u8 = ATTR_UNDERLINE | ATTR_BLINK | ATTR_INVERSE | ATTR_HIDDEN | ATTR_STRIKETHROUGH;

pub const ColorOverride = union(enum) {
    inherit,
    clear,
    rgb: Rgb,
};

/// Node-provided style (tri-state fields allow inheritance and clearing).
pub const StyleOverride = struct {
    fg: ColorOverride = .inherit,
    bg: ColorOverride = .inherit,
    attrs_set: u8 = 0,
    attrs_values: u8 = 0,

    pub fn setAttr(self: *StyleOverride, attr: Attr, value: bool) void {
        const bit: u8 = @as(u8, 1) << @intFromEnum(attr);
        self.attrs_set |= bit;
        if (value) {
            self.attrs_values |= bit;
        } else {
            self.attrs_values &= ~bit;
        }
    }
};

/// Fully-resolved style after inheritance/merging.
pub const Style = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    attrs: u8 = 0,

    pub fn isDefault(self: Style) bool {
        return self.fg == null and self.bg == null and self.attrs == 0;
    }

    pub fn affectsBlank(self: Style) bool {
        if (self.bg != null) return true;
        return (self.attrs & ATTR_AFFECTS_BLANK) != 0;
    }
};

/// Compact per-cell style for the frame.
pub const PackedStyle = packed struct(u64) {
    fg: u24 = 0, // 0xRRGGBB
    bg: u24 = 0, // 0xRRGGBB
    attrs: u8 = 0,
    has_fg: u1 = 0,
    has_bg: u1 = 0,
    _pad: u6 = 0,

    pub fn isDefault(self: PackedStyle) bool {
        return self.has_fg == 0 and self.has_bg == 0 and self.attrs == 0;
    }

    pub fn affectsBlank(self: PackedStyle) bool {
        if (self.has_bg == 1) return true;
        return (self.attrs & ATTR_AFFECTS_BLANK) != 0;
    }
};

pub fn pack(style: Style) PackedStyle {
    var out: PackedStyle = .{};
    out.attrs = style.attrs;
    if (style.fg) |c| {
        out.has_fg = 1;
        out.fg = color.rgbToU24(c);
    }
    if (style.bg) |c| {
        out.has_bg = 1;
        out.bg = color.rgbToU24(c);
    }
    return out;
}

pub fn unpack(p: PackedStyle) Style {
    return .{
        .fg = if (p.has_fg == 1) color.u24ToRgb(p.fg) else null,
        .bg = if (p.has_bg == 1) color.u24ToRgb(p.bg) else null,
        .attrs = p.attrs,
    };
}

pub fn merge(parent: Style, override: ?StyleOverride) Style {
    var out = parent;
    const o = override orelse return out;

    out.fg = switch (o.fg) {
        .inherit => out.fg,
        .clear => null,
        .rgb => |c| c,
    };
    out.bg = switch (o.bg) {
        .inherit => out.bg,
        .clear => null,
        .rgb => |c| c,
    };

    const set_mask = o.attrs_set;
    out.attrs = (out.attrs & ~set_mask) | (o.attrs_values & set_mask);
    return out;
}

pub fn overlayAttrs(base: Style, overlay_set: u8, overlay_values: u8) Style {
    var out = base;
    out.attrs = (out.attrs & ~overlay_set) | (overlay_values & overlay_set);
    return out;
}

pub fn stylesEqual(a: Style, b: Style) bool {
    if (a.attrs != b.attrs) return false;
    if (a.fg == null and b.fg != null) return false;
    if (a.fg != null and b.fg == null) return false;
    if (a.bg == null and b.bg != null) return false;
    if (a.bg != null and b.bg == null) return false;
    if (a.fg) |afg| {
        const bfg = b.fg.?;
        if (afg.r != bfg.r or afg.g != bfg.g or afg.b != bfg.b) return false;
    }
    if (a.bg) |abg| {
        const bbg = b.bg.?;
        if (abg.r != bbg.r or abg.g != bbg.g or abg.b != bbg.b) return false;
    }
    return true;
}

pub fn parseColorSpec(s: []const u8) color.ParseColorError!Rgb {
    return color.parseColorSpec(s);
}
