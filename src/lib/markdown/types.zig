const std = @import("std");

const style = @import("../style.zig");

pub const Theme = struct {
    heading: style.StyleOverride = attrStyle(.bold, true),
    bold: style.StyleOverride = attrStyle(.bold, true),
    italic: style.StyleOverride = attrStyle(.italic, true),
    code: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0xE5, .g = 0xE7, .b = 0xEB } },
        .bg = .{ .rgb = .{ .r = 0x11, .g = 0x18, .b = 0x27 } },
    },
    quote_prefix: style.StyleOverride = attrStyle(.dim, true),
    bullet_prefix: style.StyleOverride = attrStyle(.dim, true),
};

pub const InlineOptions = struct {
    sanitize_control: bool = true,
    /// When false, spans borrow slices from the input markdown buffer when possible.
    /// Caller must keep `md` alive for as long as the spans are used.
    own_text: bool = true,
    /// Defensive cap; if exceeded, compilation falls back to a single plain span for that node.
    max_spans: usize = 4096,
    theme: Theme = .{},
};

pub const Options = struct {
    /// Root node id.
    id: []const u8 = "md",
    /// Prefix used for generated block ids.
    id_prefix: []const u8 = "md",
    /// Emit `hbox` prefix + body for lists/quotes to align wrapped lines.
    prefix_layout: bool = true,
    /// Use pretty prefixes (`• `, `│ `) instead of ASCII (`- `, `> `).
    pretty_prefixes: bool = true,
    sanitize_control: bool = true,
    /// When false, spans borrow slices from the input markdown buffer when possible.
    /// Caller must keep `md` alive for as long as the compiled tree is used.
    own_text: bool = true,
    /// Defensive cap; if exceeded, compilation falls back to a single plain span for that node.
    max_spans: usize = 4096,
    theme: Theme = .{},
};

pub const CompileError = std.mem.Allocator.Error;

fn attrStyle(attr: style.Attr, value: bool) style.StyleOverride {
    var out: style.StyleOverride = .{};
    out.setAttr(attr, value);
    return out;
}
