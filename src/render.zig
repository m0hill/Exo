const std = @import("std");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");

pub fn render(term: *terminal.Terminal, root: protocol.Node) !void {
    try term.writeAll("\x1b[2J\x1b[H");
    const size = term.getSize() catch terminal.Size{ .rows = 0, .cols = 0 };
    var rows_left: usize = if (size.rows == 0) std.math.maxInt(usize) else size.rows;
    try renderNode(term, root, size.cols, &rows_left);
}

fn renderNode(term: *terminal.Terminal, node: protocol.Node, cols: u16, rows_left: *usize) !void {
    if (rows_left.* == 0) return;
    switch (node) {
        .text => |t| {
            const line = if (cols == 0 or t.text.len <= cols) t.text else t.text[0..@intCast(cols)];
            try term.writeAll(line);
            try term.writeAll("\x1b[K\n");
            rows_left.* -= 1;
        },
        .vbox => |v| {
            _ = v.id;
            for (v.children) |child| {
                if (rows_left.* == 0) break;
                try renderNode(term, child, cols, rows_left);
            }
        },
    }
}
