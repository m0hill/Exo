const std = @import("std");

const keys = @import("keys.zig");
const mouse = @import("mouse.zig");

pub const Options = struct {
    esc_timeout_ns: u64 = 25 * std.time.ns_per_ms,
    csi_timeout_ns: u64 = 40 * std.time.ns_per_ms,
    max_seq_len: usize = 64,
    max_paste_bytes: usize = 256 * 1024,
};

pub const Decoded = union(enum) {
    key: keys.KeyEvent,
    /// Raw paste bytes (UTF-8 assumed but not enforced).
    /// Ownership: decoder-owned, valid until next feedByte()/tick().
    paste: []const u8,
    mouse: mouse.MouseEvent,
};

const State = enum {
    ground,
    utf8_pending,
    esc_pending,
    csi,
    ss3,
    paste,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    state: State = .ground,

    // Output buffer for Key.text.
    out_text_buf: [4]u8 = undefined,
    out_text_len: u8 = 0,

    // UTF-8 pending.
    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_expect: u8 = 0,
    utf8_mods: keys.Modifiers = .{},

    // ESC ambiguity.
    esc_last_ns: u64 = 0,
    esc_mods: keys.Modifiers = .{},

    // CSI/SS3 buffering (includes the leading ESC byte).
    seq_buf: [256]u8 = undefined,
    seq_len: u16 = 0,
    seq_base_mods: keys.Modifiers = .{},
    seq_last_ns: u64 = 0,

    // Bracketed paste.
    paste_buf: std.ArrayList(u8) = .empty,
    paste_overflow: bool = false,
    paste_match_len: u3 = 0,
    paste_match_buf: [6]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Decoder {
        if (opts.max_seq_len + 1 > 256) return error.InvalidMaxSeqLen;
        var d: Decoder = .{ .allocator = allocator, .opts = opts };
        try d.paste_buf.ensureTotalCapacity(allocator, 256);
        return d;
    }

    pub fn deinit(self: *Decoder) void {
        self.paste_buf.deinit(self.allocator);
    }

    pub fn nextDeadlineNs(self: *const Decoder) ?u64 {
        return switch (self.state) {
            .esc_pending => self.esc_last_ns + self.opts.esc_timeout_ns,
            .csi, .ss3 => self.seq_last_ns + self.opts.csi_timeout_ns,
            else => null,
        };
    }

    pub fn tick(self: *Decoder, now_ns: u64) ?Decoded {
        switch (self.state) {
            .esc_pending => {
                if (now_ns < self.esc_last_ns + self.opts.esc_timeout_ns) return null;
                const mods = self.esc_mods;
                self.resetToGround();
                return self.emitNamed(.escape, mods);
            },
            .csi, .ss3 => {
                if (now_ns < self.seq_last_ns + self.opts.csi_timeout_ns) return null;
                return self.emitUnknownEscapeAndReset();
            },
            else => return null,
        }
    }

    pub fn feedByte(self: *Decoder, b: u8, now_ns: u64) ?Decoded {
        switch (self.state) {
            .ground => return self.feedGround(b, now_ns),
            .utf8_pending => return self.feedUtf8Pending(b),
            .esc_pending => return self.feedEscPending(b, now_ns),
            .csi => return self.feedCsi(b, now_ns),
            .ss3 => return self.feedSs3(b, now_ns),
            .paste => return self.feedPaste(b),
        }
    }

    fn resetToGround(self: *Decoder) void {
        self.state = .ground;
        self.utf8_len = 0;
        self.utf8_expect = 0;
        self.esc_last_ns = 0;
        self.esc_mods = .{};
        self.seq_len = 0;
        self.seq_base_mods = .{};
        self.seq_last_ns = 0;
        self.paste_match_len = 0;
        self.paste_overflow = false;
    }

    fn outText(self: *Decoder, bytes: []const u8) keys.Key {
        std.debug.assert(bytes.len <= self.out_text_buf.len);
        self.out_text_len = @as(u8, @intCast(bytes.len));
        std.mem.copyForwards(u8, self.out_text_buf[0..bytes.len], bytes);
        return .{ .text = self.out_text_buf[0..bytes.len] };
    }

    fn emitKey(self: *Decoder, key: keys.Key, mods: keys.Modifiers) Decoded {
        _ = self;
        return .{ .key = .{ .key = key, .mods = mods } };
    }

    fn emitNamed(self: *Decoder, k: keys.NamedKey, mods: keys.Modifiers) Decoded {
        return self.emitKey(.{ .named = k }, mods);
    }

    fn emitFunction(self: *Decoder, n: u8, mods: keys.Modifiers) Decoded {
        return self.emitKey(.{ .function = n }, mods);
    }

    fn emitUnknownEscapeAndReset(self: *Decoder) Decoded {
        const seq = self.seqSlice();
        const mods = self.seq_base_mods;
        self.resetToGround();
        return self.emitKey(.{ .unknown_escape = seq }, mods);
    }

    fn seqSlice(self: *Decoder) []const u8 {
        return self.seq_buf[0..@as(usize, self.seq_len)];
    }

    fn startEscPending(self: *Decoder, now_ns: u64, base_mods: keys.Modifiers) void {
        self.state = .esc_pending;
        self.esc_last_ns = now_ns;
        self.esc_mods = base_mods;
    }

    fn startSeq(self: *Decoder, st: State, base_mods: keys.Modifiers, now_ns: u64, prefix2: u8) void {
        self.state = st;
        self.seq_len = 0;
        self.seq_base_mods = base_mods;
        self.seq_last_ns = now_ns;
        self.seq_buf[0] = 0x1b;
        self.seq_buf[1] = prefix2;
        self.seq_len = 2;
    }

    fn appendSeqByte(self: *Decoder, b: u8) ?Decoded {
        const max_len = self.opts.max_seq_len;
        if (@as(usize, self.seq_len) >= max_len) {
            // Include the overflow byte for observability.
            self.seq_buf[@as(usize, self.seq_len)] = b;
            self.seq_len += 1;
            return self.emitUnknownEscapeAndReset();
        }
        self.seq_buf[@as(usize, self.seq_len)] = b;
        self.seq_len += 1;
        return null;
    }

    fn feedGround(self: *Decoder, b: u8, now_ns: u64) ?Decoded {
        // Collision priorities over Ctrl-char mapping.
        if (b == 0x09) return self.emitNamed(.tab, .{});
        if (b == 0x0d or b == 0x0a) return self.emitNamed(.enter, .{});
        if (b == 0x7f or b == 0x08) return self.emitNamed(.backspace, .{});

        if (b == 0x1b) {
            self.startEscPending(now_ns, .{});
            return null;
        }

        if (b >= 0x01 and b <= 0x1a) {
            const letter: u8 = @as(u8, 'a') + (b - 1);
            return self.emitKey(self.outText(&.{letter}), .{ .ctrl = true });
        }

        if (b < 0x80) {
            if (b < 0x20) return null;
            return self.emitKey(self.outText(&.{b}), .{});
        }

        const expect = std.unicode.utf8ByteSequenceLength(b) catch return null;
        if (expect <= 1 or expect > 4) return null;
        self.state = .utf8_pending;
        self.utf8_buf[0] = b;
        self.utf8_len = 1;
        self.utf8_expect = @as(u8, @intCast(expect));
        self.utf8_mods = .{};
        return null;
    }

    fn isUtf8ContinuationByte(b: u8) bool {
        return (b & 0b1100_0000) == 0b1000_0000;
    }

    fn feedUtf8Pending(self: *Decoder, b: u8) ?Decoded {
        if (!isUtf8ContinuationByte(b)) {
            self.state = .ground;
            self.utf8_len = 0;
            self.utf8_expect = 0;
            return null;
        }

        if (@as(usize, self.utf8_len) >= self.utf8_buf.len) {
            self.state = .ground;
            self.utf8_len = 0;
            self.utf8_expect = 0;
            return null;
        }

        self.utf8_buf[@as(usize, self.utf8_len)] = b;
        self.utf8_len += 1;

        if (self.utf8_len != self.utf8_expect) return null;

        const slice = self.utf8_buf[0..@as(usize, self.utf8_len)];
        _ = std.unicode.utf8Decode(slice) catch {
            self.state = .ground;
            self.utf8_len = 0;
            self.utf8_expect = 0;
            return null;
        };

        const mods = self.utf8_mods;
        self.state = .ground;
        self.utf8_len = 0;
        self.utf8_expect = 0;
        return self.emitKey(self.outText(slice), mods);
    }

    fn feedEscPending(self: *Decoder, b: u8, now_ns: u64) ?Decoded {
        // Double ESC is commonly used as Alt-prefix for escape sequences.
        if (b == 0x1b) {
            self.esc_mods.alt = true;
            self.esc_last_ns = now_ns;
            return null;
        }

        const base_mods = self.esc_mods;
        self.resetToGround();

        switch (b) {
            '[' => {
                self.startSeq(.csi, base_mods, now_ns, '[');
                return null;
            },
            'O' => {
                self.startSeq(.ss3, base_mods, now_ns, 'O');
                return null;
            },
            else => {
                return self.feedGroundWithBaseMods(b, keys.Modifiers.merge(base_mods, .{ .alt = true }));
            },
        }
    }

    fn feedGroundWithBaseMods(self: *Decoder, b: u8, base_mods: keys.Modifiers) ?Decoded {
        // Collision priorities over Ctrl-char mapping.
        if (b == 0x09) return self.emitNamed(.tab, base_mods);
        if (b == 0x0d or b == 0x0a) return self.emitNamed(.enter, base_mods);
        if (b == 0x7f or b == 0x08) return self.emitNamed(.backspace, base_mods);

        if (b >= 0x01 and b <= 0x1a) {
            const letter: u8 = @as(u8, 'a') + (b - 1);
            const mods = keys.Modifiers.merge(base_mods, .{ .ctrl = true });
            return self.emitKey(self.outText(&.{letter}), mods);
        }

        if (b < 0x80) {
            if (b < 0x20) return null;
            return self.emitKey(self.outText(&.{b}), base_mods);
        }

        const expect = std.unicode.utf8ByteSequenceLength(b) catch return null;
        if (expect <= 1 or expect > 4) return null;
        self.state = .utf8_pending;
        self.utf8_buf[0] = b;
        self.utf8_len = 1;
        self.utf8_expect = @as(u8, @intCast(expect));
        self.utf8_mods = base_mods;
        return null;
    }

    fn isCsiFinalByte(b: u8) bool {
        return b >= 0x40 and b <= 0x7e;
    }

    fn feedCsi(self: *Decoder, b: u8, now_ns: u64) ?Decoded {
        self.seq_last_ns = now_ns;
        if (self.appendSeqByte(b)) |d| return d;
        if (!isCsiFinalByte(b)) return null;
        return self.decodeCsiFinal();
    }

    fn feedSs3(self: *Decoder, b: u8, now_ns: u64) ?Decoded {
        self.seq_last_ns = now_ns;
        if (self.appendSeqByte(b)) |d| return d;
        // SS3 sequences are 3 bytes: ESC O <final>.
        return self.decodeSs3Final();
    }

    fn modsFromXtermParam(p: u32) keys.Modifiers {
        return switch (p) {
            2 => .{ .shift = true },
            3 => .{ .alt = true },
            4 => .{ .shift = true, .alt = true },
            5 => .{ .ctrl = true },
            6 => .{ .shift = true, .ctrl = true },
            7 => .{ .alt = true, .ctrl = true },
            8 => .{ .shift = true, .alt = true, .ctrl = true },
            else => .{},
        };
    }

    fn parseSimpleParams(bytes: []const u8, out: *[3]u32) ?usize {
        if (bytes.len == 0) return 0;
        var i: usize = 0;
        var nparams: usize = 0;
        while (i < bytes.len and nparams < out.len) : (nparams += 1) {
            if (i >= bytes.len) break;
            if (bytes[i] < '0' or bytes[i] > '9') return null;
            var v: u32 = 0;
            while (i < bytes.len) : (i += 1) {
                const c = bytes[i];
                if (c < '0' or c > '9') break;
                const digit: u32 = @as(u32, c - '0');
                if (v > (std.math.maxInt(u32) - digit) / 10) return null;
                v = v * 10 + digit;
            }
            out[nparams] = v;
            if (i == bytes.len) return nparams + 1;
            if (bytes[i] != ';') return null;
            i += 1;
            if (i == bytes.len) return null;
        }
        if (i != bytes.len) return null;
        return nparams;
    }

    fn decodeSs3Final(self: *Decoder) ?Decoded {
        const seq = self.seqSlice();
        if (seq.len != 3) return self.emitUnknownEscapeAndReset();
        const final = seq[2];
        const mods = self.seq_base_mods;
        self.resetToGround();
        return switch (final) {
            'P' => self.emitFunction(1, mods),
            'Q' => self.emitFunction(2, mods),
            'R' => self.emitFunction(3, mods),
            'S' => self.emitFunction(4, mods),
            'A' => self.emitNamed(.up, mods),
            'B' => self.emitNamed(.down, mods),
            'C' => self.emitNamed(.right, mods),
            'D' => self.emitNamed(.left, mods),
            'H' => self.emitNamed(.home, mods),
            'F' => self.emitNamed(.end, mods),
            else => self.emitKey(.{ .unknown_escape = seq }, mods),
        };
    }

    fn decodeCsiFinal(self: *Decoder) ?Decoded {
        const seq = self.seqSlice();
        if (seq.len < 3) return self.emitUnknownEscapeAndReset();
        const final = seq[seq.len - 1];

        // Mouse SGR (ESC[<...M / ESC[<...m).
        if (seq.len >= 4 and seq[2] == '<' and (final == 'M' or final == 'm')) {
            defer self.resetToGround();
            if (mouse.parseSgrMouseSequence(seq)) |ev| {
                return .{ .mouse = ev };
            }
            return self.emitKey(.{ .unknown_escape = seq }, self.seq_base_mods);
        }

        const params_bytes = seq[2 .. seq.len - 1];

        if (final == 'Z') {
            const mods = keys.Modifiers.merge(self.seq_base_mods, .{ .shift = true });
            self.resetToGround();
            return self.emitNamed(.tab, mods);
        }

        if (final == 'A' or final == 'B' or final == 'C' or final == 'D' or final == 'H' or final == 'F') {
            var parsed: [3]u32 = .{ 0, 0, 0 };
            const n = parseSimpleParams(params_bytes, &parsed) orelse {
                return self.emitUnknownEscapeAndReset();
            };

            var mods: keys.Modifiers = self.seq_base_mods;
            if (n == 0) {
                // ok
            } else if (n == 2 and parsed[0] == 1) {
                mods = keys.Modifiers.merge(mods, modsFromXtermParam(parsed[1]));
            } else {
                return self.emitUnknownEscapeAndReset();
            }

            const named: keys.NamedKey = switch (final) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                else => unreachable,
            };

            self.resetToGround();
            return self.emitNamed(named, mods);
        }

        if (final == '~') {
            var parsed: [3]u32 = .{ 0, 0, 0 };
            const n = parseSimpleParams(params_bytes, &parsed) orelse {
                return self.emitUnknownEscapeAndReset();
            };
            if (n < 1) return self.emitUnknownEscapeAndReset();

            const code = parsed[0];
            var mods: keys.Modifiers = self.seq_base_mods;
            if (n >= 2) mods = keys.Modifiers.merge(mods, modsFromXtermParam(parsed[1]));

            switch (code) {
                1 => {
                    self.resetToGround();
                    return self.emitNamed(.home, mods);
                },
                2 => {
                    self.resetToGround();
                    return self.emitNamed(.insert, mods);
                },
                3 => {
                    self.resetToGround();
                    return self.emitNamed(.delete, mods);
                },
                4 => {
                    self.resetToGround();
                    return self.emitNamed(.end, mods);
                },
                5 => {
                    self.resetToGround();
                    return self.emitNamed(.page_up, mods);
                },
                6 => {
                    self.resetToGround();
                    return self.emitNamed(.page_down, mods);
                },
                15, 17, 18, 19, 20, 21, 23, 24 => {
                    const fn_key: u8 = switch (code) {
                        15 => 5,
                        17 => 6,
                        18 => 7,
                        19 => 8,
                        20 => 9,
                        21 => 10,
                        23 => 11,
                        24 => 12,
                        else => unreachable,
                    };
                    self.resetToGround();
                    return self.emitFunction(fn_key, mods);
                },
                200 => {
                    // Bracketed paste start.
                    self.state = .paste;
                    self.paste_buf.clearRetainingCapacity();
                    self.paste_overflow = false;
                    self.paste_match_len = 0;
                    return null;
                },
                201 => return self.emitUnknownEscapeAndReset(),
                else => return self.emitUnknownEscapeAndReset(),
            }
        }

        return self.emitUnknownEscapeAndReset();
    }

    fn feedPaste(self: *Decoder, b: u8) ?Decoded {
        const end_marker: [6]u8 = .{ 0x1b, '[', '2', '0', '1', '~' };

        const cur: u8 = b;
        while (true) {
            if (self.paste_match_len == 0) {
                if (cur == end_marker[0]) {
                    self.paste_match_buf[0] = cur;
                    self.paste_match_len = 1;
                    return null;
                }
                self.appendPasteByte(cur);
                return null;
            }

            if (cur == end_marker[@as(usize, self.paste_match_len)]) {
                self.paste_match_buf[@as(usize, self.paste_match_len)] = cur;
                self.paste_match_len += 1;
                if (self.paste_match_len == end_marker.len) {
                    self.paste_match_len = 0;
                    self.state = .ground;
                    return .{ .paste = self.paste_buf.items };
                }
                return null;
            }

            // Mismatch: flush pending bytes, then re-process current byte.
            var i: usize = 0;
            while (i < @as(usize, self.paste_match_len)) : (i += 1) {
                self.appendPasteByte(self.paste_match_buf[i]);
            }
            self.paste_match_len = 0;
            continue;
        }
    }

    fn appendPasteByte(self: *Decoder, b: u8) void {
        if (self.paste_overflow) return;
        if (self.paste_buf.items.len >= self.opts.max_paste_bytes) {
            self.paste_overflow = true;
            return;
        }
        self.paste_buf.append(self.allocator, b) catch {
            self.paste_overflow = true;
        };
    }
};
