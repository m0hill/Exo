const prelude = @import("prelude.zig");
const std = prelude.std;
const tui = prelude.tui;
const protocol = prelude.protocol;
const Frame = prelude.Frame;
const render = prelude.render;
const renderer_mod = prelude.renderer_mod;
const testing_terminal = prelude.testing_terminal;
const input = prelude.input;
const unicode = prelude.unicode;
const state = prelude.state;
const tree = prelude.tree;
const scheduler_mod = prelude.scheduler_mod;
const mouse = prelude.mouse;
const style = prelude.style;
const markdown = prelude.markdown;
const hover = prelude.hover;
const keys = prelude.keys;
const kd = prelude.kd;
const termcaps = prelude.termcaps;
const clipboard = prelude.clipboard;
const runtime_ui = prelude.runtime_ui;
const pointer = prelude.pointer;

const cellByte = prelude.cellByte;
const cellText = prelude.cellText;
const keyEventMatchesNamed = prelude.keyEventMatchesNamed;

test "render.findRectForId: overlay anchored below computes expected rect" {
    var base_children = [_]protocol.Node{
        .{ .text = .{ .id = "anchor", .text = "A" } },
    };
    var base = protocol.Node{ .vbox = .{ .id = "base", .children = base_children[0..] } };

    var layer_node = protocol.Node{ .text = .{ .id = "layer", .text = "B" } };
    var layers = [_]protocol.OverlayLayer{
        .{ .node = &layer_node, .anchor = "anchor", .placement = .below, .w = 4 },
    };
    const root = protocol.Node{ .overlay = .{ .id = "root", .base = &base, .layers = layers[0..] } };

    const r = render.findRectForId(root, 5, 10, "layer") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), r.x);
    try std.testing.expectEqual(@as(usize, 1), r.y);
    try std.testing.expectEqual(@as(usize, 4), r.w);
    try std.testing.expectEqual(@as(usize, 1), r.h);
}
