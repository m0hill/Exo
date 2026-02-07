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

test "input: insert and backspace edit buffer" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var cursor: usize = 0;

    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 'h'));
    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 'i'));
    try std.testing.expectEqualStrings("hi", buf.items);
    try std.testing.expectEqual(@as(usize, 2), cursor);

    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 127));
    try std.testing.expectEqualStrings("h", buf.items);
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "input: insert utf8 and backspace deletes grapheme" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var cursor: usize = 0;

    try std.testing.expect(try input.insertUtf8Bytes(std.testing.allocator, &buf, &cursor, "漢"));
    try std.testing.expectEqualStrings("漢", buf.items);
    try std.testing.expectEqual(@as(usize, "漢".len), cursor);

    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 127));
    try std.testing.expectEqualStrings("", buf.items);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "input: ensure_cursor_visible scrolls window" {
    const value = "abcdefghijklmnop";
    const visible_cols: usize = 8;
    var scroll_x: usize = 0;

    _ = input.ensure_cursor_visible(&scroll_x, 16, value, visible_cols);
    try std.testing.expectEqual(@as(usize, 8), scroll_x);

    _ = input.ensure_cursor_visible(&scroll_x, 6, value, visible_cols);
    try std.testing.expectEqual(@as(usize, 6), scroll_x);
}

test "input: delete_at_cursor deletes without moving cursor" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "abcd");
    var cursor: usize = 1;

    try std.testing.expect(input.delete_at_cursor(&buf, &cursor));
    try std.testing.expectEqualStrings("acd", buf.items);
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "input: word jumps use ascii word chars" {
    const value = "abc  def_ghi  j";
    try std.testing.expectEqual(@as(usize, 3), input.word_right(value, 0));
    try std.testing.expectEqual(@as(usize, 12), input.word_right(value, 3));
    try std.testing.expectEqual(@as(usize, 5), input.word_left(value, 12));
    try std.testing.expectEqual(@as(usize, 0), input.word_left(value, 5));
}
