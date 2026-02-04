const std = @import("std");
const style = @import("../style.zig");

const protocol = @import("types.zig");

const Msg = protocol.Msg;
const PatchMsg = protocol.PatchMsg;
const PatchMode = protocol.PatchMode;
const EventMsg = protocol.EventMsg;
const Node = protocol.Node;
const JustifyContent = protocol.JustifyContent;
const AlignItems = protocol.AlignItems;
const HorizontalAlign = protocol.HorizontalAlign;
const VerticalAlign = protocol.VerticalAlign;
const OverlayPlacement = protocol.OverlayPlacement;
const OverlayAlign = protocol.OverlayAlign;
const OverlayLayer = protocol.OverlayLayer;
const Span = protocol.Span;
const PointerEvent = protocol.PointerEvent;
const ParseMsgError = protocol.ParseMsgError;

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (b < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{b});
                } else {
                    try writer.writeByte(b);
                }
            },
        }
    }
    try writer.writeByte('"');
}

pub fn writeEventJsonl(writer: anytype, key: []const u8) !void {
    return writeKeyEventJsonl(writer, key);
}

pub fn writeKeyEventJsonl(writer: anytype, key: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"key\",\"key\":");
    try writeJsonString(writer, key);
    try writer.writeAll("}\n");
}

pub fn writeFocusEventJsonl(writer: anytype, id: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"focus\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll("}\n");
}

pub fn writeInputEventJsonl(writer: anytype, id: []const u8, value: []const u8, cursor: usize) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"input\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"value\":");
    try writeJsonString(writer, value);
    try writer.print(",\"cursor\":{d}}}\n", .{cursor});
}

pub fn writeSelectEventJsonl(writer: anytype, id: []const u8, item: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"select\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"item\":");
    try writeJsonString(writer, item);
    try writer.writeAll("}\n");
}

pub fn writeActivateEventJsonl(writer: anytype, id: []const u8, item: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"activate\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"item\":");
    try writeJsonString(writer, item);
    try writer.writeAll("}\n");
}

pub fn writeScrollEventJsonl(writer: anytype, id: []const u8, scroll_y: usize) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"scroll\",\"id\":");
    try writeJsonString(writer, id);
    try writer.print(",\"scroll_y\":{d}}}\n", .{scroll_y});
}

pub fn writeResizeEventJsonl(writer: anytype, rows: usize, cols: usize) !void {
    try writer.print("{{\"type\":\"event\",\"name\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n", .{ rows, cols });
}

pub fn writeHoverEventJsonl(writer: anytype, id: []const u8, x: usize, y: usize, item: ?[]const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"hover\",\"id\":");
    try writeJsonString(writer, id);
    try writer.print(",\"x\":{d},\"y\":{d}", .{ x, y });
    if (item) |it| {
        try writer.writeAll(",\"item\":");
        try writeJsonString(writer, it);
    }
    try writer.writeAll("}\n");
}

pub fn writePointerEventJsonl(writer: anytype, ev: PointerEvent) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"pointer\",\"kind\":");
    try writeJsonString(writer, switch (ev.kind) {
        .down => "down",
        .up => "up",
        .move => "move",
        .drag => "drag",
        .scroll => "scroll",
    });
    try writer.writeAll(",\"id\":");
    try writeJsonString(writer, ev.id);
    try writer.print(
        ",\"x\":{d},\"y\":{d},\"local_x\":{d},\"local_y\":{d}",
        .{ ev.x, ev.y, ev.local_x, ev.local_y },
    );
    try writer.writeAll(",\"button\":");
    try writeJsonString(writer, switch (ev.button) {
        .left => "left",
        .middle => "middle",
        .right => "right",
        .none => "none",
    });
    try writer.print(",\"buttons\":{d},\"mods\":{d},\"clicks\":{d}", .{ ev.buttons, ev.mods, ev.clicks });
    try writer.print(",\"scroll_dx\":{d},\"scroll_dy\":{d}", .{ ev.scroll_dx, ev.scroll_dy });
    if (ev.item) |it| {
        try writer.writeAll(",\"item\":");
        try writeJsonString(writer, it);
    }
    try writer.writeAll(",\"captured\":");
    try writer.writeAll(if (ev.captured) "true" else "false");
    try writer.writeAll("}\n");
}

pub fn writeNodeJson(writer: anytype, node: Node) !void {
    switch (node) {
        .vbox => |v| {
            try writer.writeAll("{\"type\":\"vbox\",\"id\":");
            try writeJsonString(writer, v.id);
            if (v.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (v.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (v.flex != 0) try writer.print(",\"flex\":{d}", .{v.flex});
            if (v.pad != 0) try writer.print(",\"pad\":{d}", .{v.pad});
            if (v.clip) try writer.writeAll(",\"clip\":true");
            if (v.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (v.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (v.justify_content != .start) {
                try writer.writeAll(",\"justify_content\":");
                try writeJsonString(writer, switch (v.justify_content) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .space_between => "space_between",
                    .space_around => "space_around",
                    .space_evenly => "space_evenly",
                });
            }
            if (v.align_items != .stretch) {
                try writer.writeAll(",\"align_items\":");
                try writeJsonString(writer, switch (v.align_items) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (v.gap != 0) try writer.print(",\"gap\":{d}", .{v.gap});
            if (v.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (v.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"children\":[");
            for (v.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
        .hbox => |h| {
            try writer.writeAll("{\"type\":\"hbox\",\"id\":");
            try writeJsonString(writer, h.id);
            if (h.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (h.h) |hh| try writer.print(",\"h\":{d}", .{hh});
            if (h.flex != 0) try writer.print(",\"flex\":{d}", .{h.flex});
            if (h.pad != 0) try writer.print(",\"pad\":{d}", .{h.pad});
            if (h.clip) try writer.writeAll(",\"clip\":true");
            if (h.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (h.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (h.justify_content != .start) {
                try writer.writeAll(",\"justify_content\":");
                try writeJsonString(writer, switch (h.justify_content) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .space_between => "space_between",
                    .space_around => "space_around",
                    .space_evenly => "space_evenly",
                });
            }
            if (h.align_items != .stretch) {
                try writer.writeAll(",\"align_items\":");
                try writeJsonString(writer, switch (h.align_items) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (h.gap != 0) try writer.print(",\"gap\":{d}", .{h.gap});
            if (h.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (h.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"children\":[");
            for (h.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
        .box => |b| {
            try writer.writeAll("{\"type\":\"box\",\"id\":");
            try writeJsonString(writer, b.id);
            if (b.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (b.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (b.flex != 0) try writer.print(",\"flex\":{d}", .{b.flex});
            if (b.title) |t| {
                try writer.writeAll(",\"title\":");
                try writeJsonString(writer, t);
            }
            if (!b.border) try writer.writeAll(",\"border\":false");
            if (b.pad != 0) try writer.print(",\"pad\":{d}", .{b.pad});
            if (!b.clip) try writer.writeAll(",\"clip\":false");
            if (b.shadow) try writer.writeAll(",\"shadow\":true");
            if (b.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (b.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (b.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (b.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"child\":");
            try writeNodeJson(writer, b.child.*);
            try writer.writeByte('}');
        },
        .scroll => |s| {
            try writer.writeAll("{\"type\":\"scroll\",\"id\":");
            try writeJsonString(writer, s.id);
            if (s.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (s.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (s.flex != 0) try writer.print(",\"flex\":{d}", .{s.flex});
            if (s.pad != 0) try writer.print(",\"pad\":{d}", .{s.pad});
            if (!s.clip) try writer.writeAll(",\"clip\":false");
            if (s.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (s.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (s.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (s.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"child\":");
            try writeNodeJson(writer, s.child.*);
            try writer.writeByte('}');
        },
        .overlay => |o| {
            try writer.writeAll("{\"type\":\"overlay\",\"id\":");
            try writeJsonString(writer, o.id);
            if (o.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (o.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (o.flex != 0) try writer.print(",\"flex\":{d}", .{o.flex});
            if (o.pad != 0) try writer.print(",\"pad\":{d}", .{o.pad});
            if (o.clip) try writer.writeAll(",\"clip\":true");
            if (o.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (o.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (o.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (o.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"base\":");
            try writeNodeJson(writer, o.base.*);
            try writer.writeAll(",\"layers\":[");
            for (o.layers, 0..) |layer, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeAll("{\"node\":");
                try writeNodeJson(writer, layer.node.*);
                if (layer.anchor) |a| {
                    try writer.writeAll(",\"anchor\":");
                    try writeJsonString(writer, a);
                }
                try writer.writeAll(",\"placement\":");
                try writeJsonString(writer, switch (layer.placement) {
                    .below => "below",
                    .above => "above",
                    .right => "right",
                    .left => "left",
                    .center => "center",
                });
                if (layer.align_ != .start) {
                    try writer.writeAll(",\"align\":");
                    try writeJsonString(writer, switch (layer.align_) {
                        .start => "start",
                        .center => "center",
                        .end => "end",
                    });
                }
                if (layer.offset_x != 0) try writer.print(",\"offset_x\":{d}", .{layer.offset_x});
                if (layer.offset_y != 0) try writer.print(",\"offset_y\":{d}", .{layer.offset_y});
                if (layer.w) |w| try writer.print(",\"w\":{d}", .{w});
                if (layer.h) |h| try writer.print(",\"h\":{d}", .{h});
                if (!layer.clip) try writer.writeAll(",\"clip\":false");
                if (layer.modal) try writer.writeAll(",\"modal\":true");
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        },
        .text => |t| {
            try writer.writeAll("{\"type\":\"text\",\"id\":");
            try writeJsonString(writer, t.id);
            if (t.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (t.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (t.flex != 0) try writer.print(",\"flex\":{d}", .{t.flex});
            if (t.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (t.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (t.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (t.ext_align != .left) {
                try writer.writeAll(",\"ext_align\":");
                try writeJsonString(writer, switch (t.ext_align) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                });
            }
            if (t.v_align != .top) {
                try writer.writeAll(",\"v_align\":");
                try writeJsonString(writer, switch (t.v_align) {
                    .top => "top",
                    .center => "center",
                    .bottom => "bottom",
                });
            }
            if (t.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"text\":");
            try writeJsonString(writer, t.text);
            try writer.writeByte('}');
        },
        .styled_text => |t| {
            try writer.writeAll("{\"type\":\"styled_text\",\"id\":");
            try writeJsonString(writer, t.id);
            if (t.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (t.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (t.flex != 0) try writer.print(",\"flex\":{d}", .{t.flex});
            if (t.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (t.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (t.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (t.ext_align != .left) {
                try writer.writeAll(",\"ext_align\":");
                try writeJsonString(writer, switch (t.ext_align) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                });
            }
            if (t.v_align != .top) {
                try writer.writeAll(",\"v_align\":");
                try writeJsonString(writer, switch (t.v_align) {
                    .top => "top",
                    .center => "center",
                    .bottom => "bottom",
                });
            }
            if (t.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"spans\":[");
            for (t.spans, 0..) |sp, i| {
                if (i != 0) try writer.writeByte(',');
                try writeSpanJson(writer, sp);
            }
            try writer.writeAll("]}");
        },
        .input => |inp| {
            try writer.writeAll("{\"type\":\"input\",\"id\":");
            try writeJsonString(writer, inp.id);
            if (inp.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (inp.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (inp.flex != 0) try writer.print(",\"flex\":{d}", .{inp.flex});
            if (inp.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (inp.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (inp.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (inp.content_align != .left) {
                try writer.writeAll(",\"content_align\":");
                try writeJsonString(writer, switch (inp.content_align) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                });
            }
            if (inp.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (inp.placeholder_style) |st| {
                try writer.writeAll(",\"placeholder_style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (inp.placeholder) |ph| {
                try writer.writeAll(",\"placeholder\":");
                try writeJsonString(writer, ph);
            }
            try writer.writeByte('}');
        },
        .list => |l| {
            try writer.writeAll("{\"type\":\"list\",\"id\":");
            try writeJsonString(writer, l.id);
            if (l.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (l.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (l.flex != 0) try writer.print(",\"flex\":{d}", .{l.flex});
            if (l.height) |height| try writer.print(",\"height\":{d}", .{height});
            if (l.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (l.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (l.mouseable) try writer.writeAll(",\"mouseable\":true");
            if (l.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"children\":[");
            for (l.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
    }
}

pub fn writeSpanJson(writer: anytype, sp: Span) !void {
    try writer.writeAll("{\"text\":");
    try writeJsonString(writer, sp.text);
    if (sp.style) |st| {
        try writer.writeAll(",\"style\":");
        try writeStyleOverrideJson(writer, st);
    }
    try writer.writeByte('}');
}

pub fn writeStyleOverrideJson(writer: anytype, st: style.StyleOverride) !void {
    var first: bool = true;
    try writer.writeByte('{');

    switch (st.fg) {
        .inherit => {},
        .clear => {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"fg\":null");
        },
        .rgb => |c| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"fg\":");
            try writeRgbHexJsonString(writer, c);
        },
    }

    switch (st.bg) {
        .inherit => {},
        .clear => {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"bg\":null");
        },
        .rgb => |c| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"bg\":");
            try writeRgbHexJsonString(writer, c);
        },
    }

    try writeStyleAttr(writer, "bold", style.ATTR_BOLD, st, &first);
    try writeStyleAttr(writer, "dim", style.ATTR_DIM, st, &first);
    try writeStyleAttr(writer, "italic", style.ATTR_ITALIC, st, &first);
    try writeStyleAttr(writer, "underline", style.ATTR_UNDERLINE, st, &first);
    try writeStyleAttr(writer, "blink", style.ATTR_BLINK, st, &first);
    try writeStyleAttr(writer, "inverse", style.ATTR_INVERSE, st, &first);
    try writeStyleAttr(writer, "hidden", style.ATTR_HIDDEN, st, &first);
    try writeStyleAttr(writer, "strikethrough", style.ATTR_STRIKETHROUGH, st, &first);

    try writer.writeByte('}');
}

fn writeStyleAttr(
    writer: anytype,
    key: []const u8,
    bit: u8,
    st: style.StyleOverride,
    first: *bool,
) !void {
    if ((st.attrs_set & bit) == 0) return;
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    const value = (st.attrs_values & bit) != 0;
    if (value) {
        try writer.print("\"{s}\":true", .{key});
    } else {
        try writer.print("\"{s}\":false", .{key});
    }
}

fn writeRgbHexJsonString(writer: anytype, c: style.Rgb) !void {
    const u: u24 = (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | @as(u24, c.b);
    try writer.print("\"#{X:0>6}\"", .{u});
}
