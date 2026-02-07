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

test "unicode: combining mark stays together and width=1" {
    const s = "e\u{0301}";
    const g = unicode.nextGrapheme(s, 0);
    try std.testing.expectEqual(@as(usize, 0), g.start);
    try std.testing.expectEqual(@as(usize, s.len), g.end);
    try std.testing.expectEqual(@as(usize, 1), g.width);
    try std.testing.expectEqual(@as(usize, s.len), unicode.sliceEndByWidth(s, 0, 1));
}

test "unicode: cjk is width 2 and does not render into 1 col" {
    try std.testing.expectEqual(@as(u2, 2), unicode.cellWidth('漢'));

    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 1, .cols = 1 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    const root = protocol.Node{ .text = .{ .id = "t", .text = "漢" } };
    try renderer.draw(&term, root, .{});
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "漢") == null);
}

test "unicode: flag cluster treated as one grapheme width 2" {
    const flag = "🇯🇵";
    const g = unicode.nextGrapheme(flag, 0);
    try std.testing.expectEqual(@as(usize, flag.len), g.end);
    try std.testing.expectEqual(@as(usize, 2), g.width);
}
