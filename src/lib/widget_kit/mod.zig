const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const style = @import("../style.zig");
const unicode = @import("../unicode.zig");

pub const Common = struct {
    disabled: bool = false,
    readonly: bool = false,
    validation: protocol.ValidationState = .none,
    hoverable: bool = false,
    mouseable: bool = true,
    w: ?usize = null,
    h: ?usize = null,
    class: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
};

pub const ButtonVariant = enum {
    primary,
    secondary,
    danger,
    subtle,
    outline,
};

fn buttonVariantClass(variant: ButtonVariant) []const u8 {
    return switch (variant) {
        .primary => "button.primary",
        .secondary => "button.secondary",
        .danger => "button.danger",
        .subtle => "button.subtle",
        .outline => "button.outline",
    };
}

fn nodePtr(allocator: std.mem.Allocator, node: protocol.Node) !*protocol.Node {
    const p = try allocator.create(protocol.Node);
    p.* = node;
    return p;
}

fn joinId(allocator: std.mem.Allocator, id: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ id, suffix });
}

pub fn button(
    allocator: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    border: bool,
    common: Common,
) !protocol.Node {
    return buttonVariant(allocator, id, label, border, .secondary, common);
}

pub fn buttonVariant(
    allocator: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    border: bool,
    variant: ButtonVariant,
    common: Common,
) !protocol.Node {
    const label_w: usize = unicode.displayWidth(label);
    const chrome: usize = (if (border) 1 else 0);
    const computed_w: usize = label_w + chrome * 2 + 2;
    const w: ?usize = common.w orelse computed_w;

    const label_id = try joinId(allocator, id, "label");
    const child = try nodePtr(allocator, .{ .text = .{
        .id = label_id,
        .ext_align = .center,
        .v_align = .center,
        .text = label,
    } });

    return .{ .box = .{
        .id = id,
        .class = common.class orelse buttonVariantClass(variant),
        .w = w,
        .h = common.h,
        .border = border,
        .pad = 0,
        .clip = true,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .style = common.style,
        .child = child,
    } };
}

pub fn checkbox(
    allocator: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    checked: bool,
    common: Common,
) !protocol.Node {
    const label_w: usize = unicode.displayWidth(label);
    const computed_w: usize = 4 + 1 + label_w;
    const w: ?usize = common.w orelse computed_w;

    const row_id = try joinId(allocator, id, "row");
    const mark_id = try joinId(allocator, id, "mark");
    const label_id = try joinId(allocator, id, "label");

    var row_children = try allocator.alloc(protocol.Node, 2);
    row_children[0] = .{ .text = .{ .id = mark_id, .class = "muted", .w = 4, .text = if (checked) "[x]" else "[ ]" } };
    row_children[1] = .{ .text = .{ .id = label_id, .class = "text", .text = label } };

    const row = try nodePtr(allocator, .{ .hbox = .{
        .id = row_id,
        .class = "surface",
        .gap = 1,
        .children = row_children,
    } });

    return .{ .box = .{
        .id = id,
        .class = common.class orelse "button.subtle",
        .w = w,
        .h = common.h,
        .border = false,
        .pad = 0,
        .clip = true,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .style = common.style,
        .child = row,
    } };
}

pub fn radioItem(
    allocator: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    selected: bool,
    common: Common,
) !protocol.Node {
    const label_w: usize = unicode.displayWidth(label);
    const computed_w: usize = 4 + 1 + label_w;
    const w: ?usize = common.w orelse computed_w;

    const row_id = try joinId(allocator, id, "row");
    const mark_id = try joinId(allocator, id, "mark");
    const label_id = try joinId(allocator, id, "label");

    var row_children = try allocator.alloc(protocol.Node, 2);
    row_children[0] = .{ .text = .{ .id = mark_id, .class = "muted", .w = 4, .text = if (selected) "(•)" else "( )" } };
    row_children[1] = .{ .text = .{ .id = label_id, .class = "text", .text = label } };

    const row = try nodePtr(allocator, .{ .hbox = .{
        .id = row_id,
        .class = "surface",
        .gap = 1,
        .children = row_children,
    } });

    return .{ .box = .{
        .id = id,
        .class = common.class orelse "button.subtle",
        .w = w,
        .h = common.h,
        .border = false,
        .pad = 0,
        .clip = true,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .style = common.style,
        .child = row,
    } };
}

pub fn toggle(
    allocator: std.mem.Allocator,
    id: []const u8,
    label: []const u8,
    on: bool,
    common: Common,
) !protocol.Node {
    const label_w: usize = unicode.displayWidth(label);
    const computed_w: usize = 6 + 1 + label_w;
    const w: ?usize = common.w orelse computed_w;

    const row_id = try joinId(allocator, id, "row");
    const mark_id = try joinId(allocator, id, "mark");
    const label_id = try joinId(allocator, id, "label");

    var row_children = try allocator.alloc(protocol.Node, 2);
    row_children[0] = .{ .text = .{ .id = mark_id, .class = "accent", .w = 6, .text = if (on) "[ON]" else "[OFF]" } };
    row_children[1] = .{ .text = .{ .id = label_id, .class = "text", .text = label } };

    const row = try nodePtr(allocator, .{ .hbox = .{
        .id = row_id,
        .class = "surface",
        .gap = 1,
        .children = row_children,
    } });

    return .{ .box = .{
        .id = id,
        .class = common.class orelse "button.subtle",
        .w = w,
        .h = common.h,
        .border = false,
        .pad = 0,
        .clip = true,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .style = common.style,
        .child = row,
    } };
}

pub const ListOption = struct {
    id: []const u8,
    label: []const u8,
};

pub fn radioGroupList(
    allocator: std.mem.Allocator,
    id: []const u8,
    options: []const ListOption,
    selected_option_id: ?[]const u8,
    marker: protocol.ListMarker,
    common: Common,
) !protocol.Node {
    var children = try allocator.alloc(protocol.Node, options.len);
    for (options, 0..) |opt, idx| {
        var spans = try allocator.alloc(protocol.Span, 2);
        const selected = if (selected_option_id) |sel| std.mem.eql(u8, sel, opt.id) else false;
        spans[0] = .{ .text = if (selected) "(•) " else "( ) " };
        spans[1] = .{ .text = opt.label };
        children[idx] = .{ .styled_text = .{
            .id = opt.id,
            .class = "text",
            .spans = spans,
        } };
    }

    return .{ .list = .{
        .id = id,
        .class = common.class orelse "menu",
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .marker = marker,
        .style = common.style,
        .children = children,
    } };
}

pub const Tab = struct {
    id: []const u8,
    label: []const u8,
};

pub fn tabs(
    allocator: std.mem.Allocator,
    id: []const u8,
    tabs_spec: []const Tab,
    active_tab_id: []const u8,
    content: protocol.Node,
) !protocol.Node {
    const bar_id = try joinId(allocator, id, "bar");

    var bar_children = try allocator.alloc(protocol.Node, tabs_spec.len);
    for (tabs_spec, 0..) |t, idx| {
        const active = std.mem.eql(u8, t.id, active_tab_id);
        bar_children[idx] = try buttonVariant(allocator, t.id, t.label, false, if (active) .primary else .subtle, .{
            .mouseable = true,
            .hoverable = true,
            .class = if (active) "button.primary" else "button.subtle",
        });
    }

    const bar = protocol.Node{ .hbox = .{
        .id = bar_id,
        .class = "surface",
        .gap = 1,
        .children = bar_children,
    } };

    var children = try allocator.alloc(protocol.Node, 2);
    children[0] = bar;
    children[1] = content;
    return .{ .vbox = .{
        .id = id,
        .class = "surface",
        .gap = 1,
        .children = children,
    } };
}

pub fn textarea(
    id: []const u8,
    placeholder: ?[]const u8,
    common: Common,
) protocol.Node {
    return .{ .textarea = .{
        .id = id,
        .class = common.class orelse "field",
        .w = common.w,
        .h = common.h,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .style = common.style,
        .placeholder = placeholder,
    } };
}

pub fn progressBar(
    allocator: std.mem.Allocator,
    id: []const u8,
    width: usize,
    percent: usize,
    common: Common,
) !protocol.Node {
    const p = if (percent > 100) 100 else percent;
    const filled: usize = (width * p) / 100;
    const buf = try allocator.alloc(u8, width + 8);
    var fbs = std.io.fixedBufferStream(buf);
    const out_w = fbs.writer();
    try out_w.writeByte('[');
    var i: usize = 0;
    while (i < width) : (i += 1) try out_w.writeByte(if (i < filled) '#' else '-');
    try out_w.writeByte(']');
    try out_w.print(" {d}%", .{p});
    const s = fbs.getWritten();
    const node_w: ?usize = common.w orelse unicode.displayWidth(s);

    return .{ .text = .{
        .id = id,
        .class = common.class orelse "muted",
        .w = node_w,
        .h = common.h,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = false,
        .style = common.style,
        .text = s,
    } };
}

pub fn spinner(
    id: []const u8,
    frame: usize,
    common: Common,
) protocol.Node {
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    const w: ?usize = common.w orelse 1;
    return .{ .text = .{
        .id = id,
        .class = common.class orelse "accent",
        .w = w,
        .h = common.h,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = false,
        .style = common.style,
        .text = frames[frame % frames.len],
    } };
}

pub const TableColumn = struct {
    id: []const u8,
    label: []const u8,
    width: usize,
};

pub const TableRow = struct {
    id: []const u8,
    cells: []const []const u8,
};

pub fn table(
    allocator: std.mem.Allocator,
    id: []const u8,
    columns: []const TableColumn,
    rows: []const TableRow,
    height: usize,
    common: Common,
) !protocol.Node {
    const header_id = try joinId(allocator, id, "header");
    const scroll_id = try joinId(allocator, id, "scroll");

    var header_children = try allocator.alloc(protocol.Node, columns.len);
    for (columns, 0..) |col, idx| {
        header_children[idx] = .{ .text = .{
            .id = col.id,
            .class = "table.header",
            .w = col.width,
            .text = col.label,
        } };
    }

    const header = protocol.Node{ .hbox = .{
        .id = header_id,
        .class = "surface",
        .gap = 1,
        .children = header_children,
    } };

    var list_children = try allocator.alloc(protocol.Node, rows.len);
    for (rows, 0..) |row, idx| {
        var row_buf = std.ArrayList(u8).empty;
        defer row_buf.deinit(allocator);
        const w = row_buf.writer(allocator);
        for (columns, 0..) |col, cidx| {
            if (cidx != 0) try w.writeAll(" ");
            const cell = if (cidx < row.cells.len) row.cells[cidx] else "";
            const n = @min(cell.len, col.width);
            if (n != 0) try w.writeAll(cell[0..n]);
            var pad: usize = col.width - n;
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        }
        const row_text = try allocator.dupe(u8, row_buf.items);
        list_children[idx] = .{ .text = .{ .id = row.id, .class = "text", .text = row_text } };
    }

    const list_node = protocol.Node{ .list = .{
        .id = id,
        .class = "table",
        .height = height,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .marker = .none,
        .children = list_children,
    } };

    const scroll_child = try nodePtr(allocator, list_node);
    const scroll_node = protocol.Node{ .scroll = .{
        .id = scroll_id,
        .mouseable = common.mouseable,
        .focusable = true,
        .child = scroll_child,
    } };

    var children = try allocator.alloc(protocol.Node, 2);
    children[0] = header;
    children[1] = scroll_node;
    return .{ .vbox = .{
        .id = try joinId(allocator, id, "wrap"),
        .class = "surface",
        .gap = 1,
        .children = children,
    } };
}

pub const TreeRow = struct {
    id: []const u8,
    depth: usize,
    has_children: bool = false,
    expanded: bool = false,
    label: []const u8,
};

pub fn tree(
    allocator: std.mem.Allocator,
    id: []const u8,
    rows: []const TreeRow,
    height: usize,
    common: Common,
) !protocol.Node {
    const scroll_id = try joinId(allocator, id, "scroll");

    var list_children = try allocator.alloc(protocol.Node, rows.len);
    for (rows, 0..) |row, idx| {
        const indent = try allocator.alloc(u8, row.depth * 2);
        @memset(indent, ' ');
        const glyph: []const u8 = if (!row.has_children) "  " else if (row.expanded) "▾ " else "▸ ";
        const text = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ indent, glyph, row.label });
        list_children[idx] = .{ .text = .{ .id = row.id, .class = "text", .text = text } };
    }

    const list_node = protocol.Node{ .list = .{
        .id = id,
        .class = "menu",
        .height = height,
        .hoverable = common.hoverable,
        .mouseable = common.mouseable,
        .disabled = common.disabled,
        .readonly = common.readonly,
        .validation = common.validation,
        .focusable = true,
        .marker = .none,
        .children = list_children,
    } };

    const scroll_child = try nodePtr(allocator, list_node);
    return .{ .scroll = .{
        .id = scroll_id,
        .mouseable = common.mouseable,
        .focusable = true,
        .child = scroll_child,
    } };
}
