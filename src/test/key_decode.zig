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

test "key_decode: ESC ambiguity (timeout vs Alt-prefix)" {
    var d = try kd.Decoder.init(std.testing.allocator, .{ .esc_timeout_ns = 10, .csi_timeout_ns = 10 });
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    const out1 = d.tick(11) orelse return error.TestUnexpectedResult;
    const ev1 = switch (out1) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const k1 = switch (ev1.key) {
        .named => |k| k,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(keys.NamedKey.escape, k1);
    try std.testing.expectEqual(@as(u8, 0), ev1.mods.toMask());

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    const out2 = d.feedByte('b', 1) orelse return error.TestUnexpectedResult;
    const ev2 = switch (out2) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const s2 = switch (ev2.key) {
        .text => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("b", s2);
    try std.testing.expect(ev2.mods.alt);
    try std.testing.expect(!ev2.mods.ctrl);
    try std.testing.expect(!ev2.mods.shift);
}

test "key_decode: control collisions prioritize named keys" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    const tab = d.feedByte(0x09, 0) orelse return error.TestUnexpectedResult;
    const t_ev = switch (tab) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(t_ev, .tab));

    const cr = d.feedByte(0x0d, 0) orelse return error.TestUnexpectedResult;
    const cr_ev = switch (cr) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(cr_ev, .enter));

    const lf = d.feedByte(0x0a, 0) orelse return error.TestUnexpectedResult;
    const lf_ev = switch (lf) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(lf_ev, .enter));

    const bs = d.feedByte(0x7f, 0) orelse return error.TestUnexpectedResult;
    const bs_ev = switch (bs) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(bs_ev, .backspace));
}

test "key_decode: partial CSI timeout emits unknown_escape" {
    var d = try kd.Decoder.init(std.testing.allocator, .{ .esc_timeout_ns = 10, .csi_timeout_ns = 10 });
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 1) == null);
    const out = d.tick(12) orelse return error.TestUnexpectedResult;
    const ev = switch (out) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const seq = switch (ev.key) {
        .unknown_escape => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(u8, "\x1b[", seq);
}

test "key_decode: arrows + modifiers" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 0) == null);
    const out1 = d.feedByte('A', 0) orelse return error.TestUnexpectedResult;
    const ev1 = switch (out1) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(ev1, .up));

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 0) == null);
    try std.testing.expect(d.feedByte('1', 0) == null);
    try std.testing.expect(d.feedByte(';', 0) == null);
    try std.testing.expect(d.feedByte('5', 0) == null);
    const out2 = d.feedByte('A', 0) orelse return error.TestUnexpectedResult;
    const ev2 = switch (out2) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const k2 = switch (ev2.key) {
        .named => |k| k,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(keys.NamedKey.up, k2);
    try std.testing.expect(ev2.mods.ctrl);
    try std.testing.expect(!ev2.mods.alt);
    try std.testing.expect(!ev2.mods.shift);
}

test "key_decode: function keys (SS3 + CSI ~)" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('O', 0) == null);
    const f1 = d.feedByte('P', 0) orelse return error.TestUnexpectedResult;
    const ev1 = switch (f1) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const n1 = switch (ev1.key) {
        .function => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), n1);

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 0) == null);
    try std.testing.expect(d.feedByte('1', 0) == null);
    try std.testing.expect(d.feedByte('5', 0) == null);
    const f5 = d.feedByte('~', 0) orelse return error.TestUnexpectedResult;
    const ev5 = switch (f5) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const n5 = switch (ev5.key) {
        .function => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 5), n5);
}

test "key_decode: bracketed paste emits literal body" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    const paste_input = "\x1b[200~hello\x1b[Aworld\x1b[201~";
    var now: u64 = 0;
    var outputs: usize = 0;
    var got: ?[]const u8 = null;
    for (paste_input) |b| {
        if (d.feedByte(b, now)) |out| {
            outputs += 1;
            switch (out) {
                .paste => |p| got = p,
                else => return error.TestUnexpectedResult,
            }
        }
        now += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), outputs);
    try std.testing.expectEqualSlices(u8, "hello\x1b[Aworld", got orelse return error.TestUnexpectedResult);
}

test "key_decode: UTF-8 text emits a single Key.text" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    const han = "漢";
    var out: ?kd.Decoded = null;
    for (han, 0..) |b, i| {
        if (d.feedByte(b, @as(u64, i))) |o| out = o;
    }
    const got = out orelse return error.TestUnexpectedResult;
    const ev = switch (got) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const s = switch (ev.key) {
        .text => |ss| ss,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(han, s);
    try std.testing.expectEqual(@as(u8, 0), ev.mods.toMask());
}
