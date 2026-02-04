const std = @import("std");

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    _pad: u5 = 0,

    pub fn toMask(self: Modifiers) u8 {
        var mask: u8 = 0;
        if (self.shift) mask |= 1;
        if (self.ctrl) mask |= 2;
        if (self.alt) mask |= 4;
        return mask;
    }

    pub fn fromMask(mask: u8) Modifiers {
        return .{
            .shift = (mask & 1) != 0,
            .ctrl = (mask & 2) != 0,
            .alt = (mask & 4) != 0,
        };
    }

    pub fn merge(a: Modifiers, b: Modifiers) Modifiers {
        return fromMask(a.toMask() | b.toMask());
    }
};

pub const NamedKey = enum {
    escape,
    enter,
    tab,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
};

pub const Key = union(enum) {
    /// One UTF-8 sequence from the terminal (usually 1 codepoint).
    text: []const u8,
    named: NamedKey,
    /// F1..F24 (store 1..24).
    function: u8,
    /// Raw bytes of an unrecognized escape sequence, including leading ESC.
    unknown_escape: []const u8,
};

pub const KeyEvent = struct {
    key: Key,
    mods: Modifiers = .{},
    is_repeat: bool = false,
};

pub fn namedKeyString(k: NamedKey) []const u8 {
    return switch (k) {
        .escape => "Escape",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .delete => "Delete",
        .insert => "Insert",
        .home => "Home",
        .end => "End",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .up => "ArrowUp",
        .down => "ArrowDown",
        .left => "ArrowLeft",
        .right => "ArrowRight",
    };
}

pub fn functionKeyString(n: u8, buf: *[4]u8) []const u8 {
    if (n < 1 or n > 24) return "F?";
    return std.fmt.bufPrint(buf, "F{d}", .{n}) catch "F?";
}

pub fn keyToString(key: Key, fbuf: *[4]u8) []const u8 {
    return switch (key) {
        .text => |s| s,
        .named => |k| namedKeyString(k),
        .function => |n| functionKeyString(n, fbuf),
        .unknown_escape => "Unidentified",
    };
}
