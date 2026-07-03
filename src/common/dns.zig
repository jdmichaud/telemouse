// A minimal DNS message encoder/decoder, just enough for multicast DNS and
// DNS-Service Discovery: questions plus PTR, SRV, TXT and A resource records,
// including decompression of names.
//
// Only what telemouse needs is implemented; this is not a general DNS library.

const std = @import("std");

pub const Type = struct {
    pub const a: u16 = 1;
    pub const ptr: u16 = 12;
    pub const txt: u16 = 16;
    pub const srv: u16 = 33;
    pub const any: u16 = 255;
};

pub const class_in: u16 = 1;
/// mDNS "cache flush" / "unicast response" bit in the top of a class field.
pub const class_flush: u16 = 0x8000;

/// Header flag bits for a query response: QR (response) + AA (authoritative).
pub const flags_response: u16 = 0x8400;

pub const Header = struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,
};

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub const WriteError = error{NoSpace};

/// A cursor writing a DNS message into a fixed buffer.
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn bytes(w: *Writer, b: []const u8) WriteError!void {
        if (w.pos + b.len > w.buf.len) return error.NoSpace;
        @memcpy(w.buf[w.pos..][0..b.len], b);
        w.pos += b.len;
    }

    pub fn u8v(w: *Writer, v: u8) WriteError!void {
        if (w.pos + 1 > w.buf.len) return error.NoSpace;
        w.buf[w.pos] = v;
        w.pos += 1;
    }

    pub fn u16v(w: *Writer, v: u16) WriteError!void {
        try w.bytes(&.{ @intCast(v >> 8), @intCast(v & 0xff) });
    }

    pub fn u32v(w: *Writer, v: u32) WriteError!void {
        try w.bytes(&.{
            @intCast((v >> 24) & 0xff),
            @intCast((v >> 16) & 0xff),
            @intCast((v >> 8) & 0xff),
            @intCast(v & 0xff),
        });
    }

    /// Write a name as a sequence of labels (no compression). Each label is
    /// written verbatim, so labels may contain spaces or dots (as DNS-SD
    /// instance names do).
    pub fn name(w: *Writer, labels: []const []const u8) WriteError!void {
        for (labels) |label| {
            if (label.len > 63) return error.NoSpace;
            try w.u8v(@intCast(label.len));
            try w.bytes(label);
        }
        try w.u8v(0);
    }

    pub fn header(w: *Writer, h: Header) WriteError!void {
        try w.u16v(h.id);
        try w.u16v(h.flags);
        try w.u16v(h.qdcount);
        try w.u16v(h.ancount);
        try w.u16v(h.nscount);
        try w.u16v(h.arcount);
    }

    pub fn question(w: *Writer, labels: []const []const u8, qtype: u16, qclass: u16) WriteError!void {
        try w.name(labels);
        try w.u16v(qtype);
        try w.u16v(qclass);
    }

    pub fn slice(w: *const Writer) []const u8 {
        return w.buf[0..w.pos];
    }
};

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

pub const ParseError = error{ Malformed, NoSpace };

/// Decode a (possibly compressed) name starting at `start` into `out` as a
/// lowercase dotted string. Returns the decoded name and the offset just past
/// the name in the original record stream (compression pointers do not count).
pub fn decodeName(msg: []const u8, start: usize, out: []u8) ParseError!struct { name: []const u8, next: usize } {
    var pos = start;
    var out_len: usize = 0;
    var next: ?usize = null;
    var jumps: usize = 0;

    while (true) {
        if (pos >= msg.len) return error.Malformed;
        const len = msg[pos];
        if (len == 0) {
            if (next == null) next = pos + 1;
            break;
        }
        if (len & 0xc0 == 0xc0) {
            // Compression pointer.
            if (pos + 1 >= msg.len) return error.Malformed;
            const ptr = (@as(usize, len & 0x3f) << 8) | msg[pos + 1];
            if (next == null) next = pos + 2;
            jumps += 1;
            if (jumps > 64 or ptr >= msg.len) return error.Malformed;
            pos = ptr;
            continue;
        }
        if (len & 0xc0 != 0) return error.Malformed;
        pos += 1;
        if (pos + len > msg.len) return error.Malformed;
        if (out_len != 0) {
            if (out_len + 1 > out.len) return error.NoSpace;
            out[out_len] = '.';
            out_len += 1;
        }
        if (out_len + len > out.len) return error.NoSpace;
        for (msg[pos..][0..len]) |c| {
            out[out_len] = std.ascii.toLower(c);
            out_len += 1;
        }
        pos += len;
    }
    return .{ .name = out[0..out_len], .next = next.? };
}

pub const Record = struct {
    /// Owner name (lowercase dotted).
    name: []const u8,
    type: u16,
    class: u16,
    ttl: u32,
    /// Offset of the record's RDATA within the full message.
    rdata_off: usize,
    rdata_len: usize,
};

/// Iterates the resource records of a message (answer + authority +
/// additional sections), skipping the questions.
pub const Parser = struct {
    msg: []const u8,
    pos: usize,
    header: Header,
    remaining_records: usize,
    name_buf: [256]u8 = undefined,

    pub fn init(msg: []const u8) ParseError!Parser {
        if (msg.len < 12) return error.Malformed;
        const h = Header{
            .id = rd16(msg, 0),
            .flags = rd16(msg, 2),
            .qdcount = rd16(msg, 4),
            .ancount = rd16(msg, 6),
            .nscount = rd16(msg, 8),
            .arcount = rd16(msg, 10),
        };
        var p = Parser{
            .msg = msg,
            .pos = 12,
            .header = h,
            .remaining_records = @as(usize, h.ancount) + h.nscount + h.arcount,
        };
        // Skip the questions.
        var q: usize = 0;
        while (q < h.qdcount) : (q += 1) {
            var scratch: [256]u8 = undefined;
            const n = try decodeName(msg, p.pos, &scratch);
            p.pos = n.next + 4; // qtype + qclass
            if (p.pos > msg.len) return error.Malformed;
        }
        return p;
    }

    pub fn next(p: *Parser) ParseError!?Record {
        if (p.remaining_records == 0) return null;
        p.remaining_records -= 1;
        const n = try decodeName(p.msg, p.pos, &p.name_buf);
        var off = n.next;
        if (off + 10 > p.msg.len) return error.Malformed;
        const rtype = rd16(p.msg, off);
        const rclass = rd16(p.msg, off + 2);
        const ttl = rd32(p.msg, off + 4);
        const rdlen = rd16(p.msg, off + 8);
        off += 10;
        if (off + rdlen > p.msg.len) return error.Malformed;
        const rec = Record{
            .name = n.name,
            .type = rtype,
            .class = rclass,
            .ttl = ttl,
            .rdata_off = off,
            .rdata_len = rdlen,
        };
        p.pos = off + rdlen;
        return rec;
    }

    /// Decode the target name of an SRV record and its port.
    pub fn srv(p: *Parser, rec: Record, out: []u8) ParseError!struct { port: u16, target: []const u8 } {
        if (rec.rdata_len < 7) return error.Malformed;
        const port = rd16(p.msg, rec.rdata_off + 4);
        const target = try decodeName(p.msg, rec.rdata_off + 6, out);
        return .{ .port = port, .target = target.name };
    }

    /// Decode the target name of a PTR record.
    pub fn ptr(p: *Parser, rec: Record, out: []u8) ParseError![]const u8 {
        const t = try decodeName(p.msg, rec.rdata_off, out);
        return t.name;
    }

    /// The four bytes of an A record.
    pub fn a(p: *Parser, rec: Record) ?[4]u8 {
        if (rec.type != Type.a or rec.rdata_len != 4) return null;
        return p.msg[rec.rdata_off..][0..4].*;
    }

    /// Raw TXT rdata (a sequence of length-prefixed strings).
    pub fn txt(p: *Parser, rec: Record) []const u8 {
        return p.msg[rec.rdata_off..][0..rec.rdata_len];
    }
};

fn rd16(msg: []const u8, off: usize) u16 {
    return (@as(u16, msg[off]) << 8) | msg[off + 1];
}

fn rd32(msg: []const u8, off: usize) u32 {
    return (@as(u32, msg[off]) << 24) | (@as(u32, msg[off + 1]) << 16) |
        (@as(u32, msg[off + 2]) << 8) | msg[off + 3];
}

test "round trip a query and response" {
    var buf: [512]u8 = undefined;
    var w = Writer.init(&buf);
    try w.header(.{ .id = 0x1234, .flags = 0, .qdcount = 1, .ancount = 0, .nscount = 0, .arcount = 0 });
    try w.question(&.{ "_telemouse", "_udp", "local" }, Type.ptr, class_in);

    var p = try Parser.init(w.slice());
    try std.testing.expectEqual(@as(u16, 0x1234), p.header.id);
    try std.testing.expectEqual(@as(u16, 1), p.header.qdcount);
    try std.testing.expectEqual(@as(?Record, null), try p.next());
}

test "srv and a records decode" {
    var buf: [512]u8 = undefined;
    var w = Writer.init(&buf);
    try w.header(.{ .id = 0, .flags = flags_response, .qdcount = 0, .ancount = 0, .nscount = 0, .arcount = 2 });
    // SRV instance._telemouse._udp.local -> host.local:24800
    try w.name(&.{ "inst", "_telemouse", "_udp", "local" });
    try w.u16v(Type.srv);
    try w.u16v(class_in);
    try w.u32v(120);
    const rdlen_pos = w.pos;
    try w.u16v(0); // placeholder
    const rd_start = w.pos;
    try w.u16v(0); // priority
    try w.u16v(0); // weight
    try w.u16v(24800); // port
    try w.name(&.{ "host", "local" });
    const rdlen: u16 = @intCast(w.pos - rd_start);
    buf[rdlen_pos] = @intCast(rdlen >> 8);
    buf[rdlen_pos + 1] = @intCast(rdlen & 0xff);
    // A host.local -> 10.0.0.5
    try w.name(&.{ "host", "local" });
    try w.u16v(Type.a);
    try w.u16v(class_in);
    try w.u32v(120);
    try w.u16v(4);
    try w.bytes(&.{ 10, 0, 0, 5 });

    var p = try Parser.init(w.slice());
    var name_buf: [256]u8 = undefined;

    const r1 = (try p.next()).?;
    try std.testing.expectEqual(Type.srv, r1.type);
    const s = try p.srv(r1, &name_buf);
    try std.testing.expectEqual(@as(u16, 24800), s.port);
    try std.testing.expectEqualStrings("host.local", s.target);

    const r2 = (try p.next()).?;
    try std.testing.expectEqual(Type.a, r2.type);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, p.a(r2).?);
}
