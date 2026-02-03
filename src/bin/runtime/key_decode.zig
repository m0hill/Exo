const std = @import("std");

const tui = @import("tui");
const mouse = tui.mouse;
const terminal = tui.terminal;

fn readByteIfReady(term: *terminal.Terminal) !?u8 {
    var fds = [_]std.posix.pollfd{
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const rc = try std.posix.poll(fds[0..], 0);
    if (rc == 0) return null;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) return null;
    return try term.readByte();
}

pub const CsiPending = struct {
    active: bool = false,
    buf: [64]u8 = undefined,
    len: u8 = 0,

    fn reset(self: *CsiPending) void {
        self.active = false;
        self.len = 0;
    }

    fn start(self: *CsiPending) void {
        self.active = true;
        self.len = 0;
    }

    fn feed(self: *CsiPending, b: u8) ?DecodedKey {
        if (!self.active) return null;
        if (@as(usize, self.len) >= self.buf.len) {
            self.reset();
            return null;
        }

        self.buf[@as(usize, self.len)] = b;
        self.len += 1;

        const seq = self.buf[0..@as(usize, self.len)];
        const first = seq[0];

        switch (first) {
            'Z' => {
                self.reset();
                return .shift_tab;
            },
            'D' => {
                self.reset();
                return .left;
            },
            'C' => {
                self.reset();
                return .right;
            },
            'H' => {
                self.reset();
                return .home;
            },
            'F' => {
                self.reset();
                return .end;
            },
            '<' => {
                if (b == 'M' or b == 'm') {
                    defer self.reset();
                    if (mouse.parseSgrMouseSequence(seq)) |ev| {
                        return .{ .mouse = ev };
                    }
                    return null;
                }
                return null;
            },
            '3', '1', '4' => {
                if (seq.len < 2) return null;
                if (seq[1] != '~') {
                    self.reset();
                    return null;
                }
                const out: DecodedKey = switch (first) {
                    '3' => .delete,
                    '1' => .home,
                    '4' => .end,
                    else => unreachable,
                };
                self.reset();
                return out;
            },
            '5', '6' => {
                if (seq.len < 2) return null;
                if (seq[1] != '~') {
                    self.reset();
                    return null;
                }
                const out: DecodedKey = switch (first) {
                    '5' => .page_up,
                    '6' => .page_down,
                    else => unreachable,
                };
                self.reset();
                return out;
            },
            '2' => {
                // Bracketed paste wrappers (ESC[200~ ... ESC[201~).
                // Consume and ignore the wrapper bytes so they don't get inserted into inputs.
                if (seq.len < 4) return null;
                if (seq[3] != '~') {
                    self.reset();
                    return null;
                }
                // "200~" / "201~"
                if (seq[1] == '0' and (seq[2] == '0' or seq[2] == '1')) {
                    self.reset();
                    return null;
                }
                self.reset();
                return null;
            },
            else => {
                self.reset();
                return null;
            },
        }
    }
};

pub const DecodedKey = union(enum) {
    byte: u8,
    utf8: Utf8Bytes,
    tab,
    shift_tab,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    word_left,
    word_right,
    mouse: mouse.MouseEvent,
};

pub const Utf8Bytes = struct {
    bytes: [4]u8,
    len: u3,

    pub fn slice(self: *const Utf8Bytes) []const u8 {
        return self.bytes[0..@as(usize, self.len)];
    }
};

pub const Utf8Pending = struct {
    bytes: [4]u8 = undefined,
    len: u3 = 0,
    expect: u3 = 0,

    fn reset(self: *Utf8Pending) void {
        self.len = 0;
        self.expect = 0;
    }
};

fn isUtf8ContinuationByte(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

fn decodeKey(term: *terminal.Terminal, csi_pending: *CsiPending, first: u8) !?DecodedKey {
    if (first == '\t') return .tab;
    if (first != 0x1b) return .{ .byte = first };

    const b2 = try readByteIfReady(term) orelse return .{ .byte = first };
    switch (b2) {
        '[' => {
            csi_pending.start();

            const b3 = try readByteIfReady(term) orelse return null;
            if (csi_pending.feed(b3)) |ev| return ev;

            while (csi_pending.active) {
                const next = try readByteIfReady(term) orelse break;
                if (csi_pending.feed(next)) |ev| return ev;
            }
            return null;
        },
        'O' => {
            const b3 = try readByteIfReady(term) orelse return null;
            return switch (b3) {
                'H' => .home,
                'F' => .end,
                else => null,
            };
        },
        'b' => return .word_left,
        'f' => return .word_right,
        else => return null,
    }
}

pub fn decodeKeyWithUtf8(term: *terminal.Terminal, pending: *Utf8Pending, csi_pending: *CsiPending, b: u8) !?DecodedKey {
    if (csi_pending.active) {
        return csi_pending.feed(b);
    }

    if (pending.expect != 0) {
        if (isUtf8ContinuationByte(b)) {
            if (@as(usize, pending.len) >= pending.bytes.len) {
                pending.reset();
                return null;
            }
            pending.bytes[@as(usize, pending.len)] = b;
            pending.len += 1;

            if (pending.len == pending.expect) {
                const out: Utf8Bytes = .{ .bytes = pending.bytes, .len = pending.len };
                pending.reset();
                return .{ .utf8 = out };
            }
            return null;
        }

        pending.reset();
    }

    if (b == 0x1b or b < 0x80) return decodeKey(term, csi_pending, b);

    const expect = std.unicode.utf8ByteSequenceLength(b) catch return null;
    if (expect <= 1 or expect > 4) return null;

    pending.bytes[0] = b;
    pending.len = 1;
    pending.expect = expect;
    return null;
}
