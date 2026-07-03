// Self-contained multicast DNS / DNS-Service Discovery for telemouse.
//
// No Avahi/Bonjour daemon is involved: the server is its own mDNS responder and
// the client its own querier.
//
//   client  --- PTR query "_telemouse._udp.local" ---> 224.0.0.251:5353
//   server  --- response: PTR + SRV + TXT + A -------> client (unicast)
//   client  --- connects to the address:port from the reply
//
// The client uses the high-level `Io.net`: it queries from an ephemeral port,
// which RFC 6762 treats as a "legacy" querier, so responders answer by unicast
// straight back to that port -- no multicast membership needed on the client.
//
// The server must join the multicast group on UDP 5353 to receive queries,
// which needs socket options `Io.net` does not expose (SO_REUSEADDR/PORT,
// IP_ADD_MEMBERSHIP). It therefore uses raw platform sockets and runs its
// receive/respond loop as an independent task. That task shares only immutable
// data (device name, command port, host address), so no locking is required.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const log = @import("log.zig");
const dns = @import("dns.zig");

pub const group = "224.0.0.251";
pub const port: u16 = 5353;

const service_labels = [_][]const u8{ "_telemouse", "_udp", "local" };
const service_name = "_telemouse._udp.local";
const meta_name = "_services._dns-sd._udp.local";
const meta_labels = [_][]const u8{ "_services", "_dns-sd", "_udp", "local" };

// ===========================================================================
// Client (querier)
// ===========================================================================

pub const Server = struct {
    /// "address:port" of the server's command socket.
    display: []const u8,
    /// Device name reported by the server.
    name: []const u8,
    /// Screen resolution reported by the server (0 if not advertised).
    width: i32 = 0,
    height: i32 = 0,
};

/// Send a DNS-SD query for telemouse servers and collect replies for up to
/// `timeout_ms`. Returned slices are allocated with `arena`.
pub fn discover(
    io: Io,
    arena: std.mem.Allocator,
    logger: *log.Logger,
    timeout_ms: i64,
) error{ DiscoveryFailed, OutOfMemory }![]Server {
    var any = net.IpAddress.parse("0.0.0.0", 0) catch unreachable;
    const sock = any.bind(io, .{ .mode = .dgram }) catch |e| {
        logger.err("discovery: cannot create udp socket: {s}", .{@errorName(e)});
        return error.DiscoveryFailed;
    };
    defer sock.close(io);

    var qbuf: [512]u8 = undefined;
    const query = buildQuery(&qbuf) catch return error.DiscoveryFailed;

    var dest = net.IpAddress.parse(group, port) catch unreachable;
    sock.send(io, &dest, query) catch |e| {
        logger.err("discovery: cannot send mDNS query: {s}", .{@errorName(e)});
        return error.DiscoveryFailed;
    };
    logger.debug("discovery: sent mDNS query for {s}", .{service_name});

    const timeout: Io.Timeout = .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(timeout_ms),
        .clock = .awake,
    } };

    var list: std.ArrayList(Server) = .empty;
    while (true) {
        var buf: [1500]u8 = undefined;
        const msg = sock.receiveTimeout(io, &buf, timeout) catch |e| switch (e) {
            error.Timeout => break,
            else => {
                logger.debug("discovery: receive error: {s}", .{@errorName(e)});
                break;
            },
        };
        const server = parseServer(arena, msg.data, msg.from) catch continue orelse continue;

        var already = false;
        for (list.items) |s| {
            if (std.mem.eql(u8, s.display, server.display)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try list.append(arena, server);
    }
    return list.toOwnedSlice(arena);
}

fn buildQuery(buf: []u8) ![]const u8 {
    var w = dns.Writer.init(buf);
    try w.header(.{ .id = 0, .flags = 0, .qdcount = 1, .ancount = 0, .nscount = 0, .arcount = 0 });
    try w.question(&service_labels, dns.Type.ptr, dns.class_in);
    return w.slice();
}

/// Extract a server from one response datagram: the command port from the SRV
/// record, the device name from the TXT record, and the address from the
/// datagram source.
fn parseServer(arena: std.mem.Allocator, msg: []const u8, from: net.IpAddress) !?Server {
    var parser = dns.Parser.init(msg) catch return null;
    var command_port: ?u16 = null;
    var name: []const u8 = "telemouse";
    var width: i32 = 0;
    var height: i32 = 0;
    var name_buf: [256]u8 = undefined;

    while (try parser.next()) |rec| {
        switch (rec.type) {
            dns.Type.srv => {
                const s = parser.srv(rec, &name_buf) catch continue;
                command_port = s.port;
            },
            dns.Type.txt => {
                const rdata = parser.txt(rec);
                if (txtValue(rdata, "n")) |v| name = v;
                if (txtValue(rdata, "w")) |v| width = std.fmt.parseInt(i32, v, 10) catch width;
                if (txtValue(rdata, "h")) |v| height = std.fmt.parseInt(i32, v, 10) catch height;
            },
            else => {},
        }
    }

    const cport = command_port orelse return null;
    var addr = from;
    addr.setPort(cport);
    var dbuf: [64]u8 = undefined;
    const display = std.fmt.bufPrint(&dbuf, "{f}", .{addr}) catch return null;
    return .{
        .display = try arena.dupe(u8, display),
        .name = try arena.dupe(u8, name),
        .width = width,
        .height = height,
    };
}

/// Find `key` in DNS-SD TXT rdata (a sequence of "key=value" length-prefixed
/// strings) and return its value.
fn txtValue(rdata: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < rdata.len) {
        const len = rdata[i];
        i += 1;
        if (i + len > rdata.len) return null;
        const entry = rdata[i .. i + len];
        i += len;
        if (entry.len > key.len + 1 and std.mem.startsWith(u8, entry, key) and entry[key.len] == '=') {
            return entry[key.len + 1 ..];
        }
    }
    return null;
}

// ===========================================================================
// Response building (shared by the responder)
// ===========================================================================

/// If `query` asks for our service (or the DNS-SD meta-query), build a response
/// into `buf`; otherwise return null.
fn buildResponse(
    buf: []u8,
    query: []const u8,
    command_port: u16,
    device_name: []const u8,
    width: i32,
    height: i32,
    host_ip: ?[4]u8,
    hostname: []const u8,
) ?[]const u8 {
    if (query.len < 12) return null;
    const id = rd16(query, 0);
    const qdcount = rd16(query, 4);
    if (rd16(query, 2) & 0x8000 != 0) return null; // ignore responses
    if (qdcount == 0) return null;

    var qbuf: [256]u8 = undefined;
    const q = dns.decodeName(query, 12, &qbuf) catch return null;
    if (q.next + 4 > query.len) return null;
    const qtype = rd16(query, q.next);
    const qname = q.name;

    const instance = [_][]const u8{ device_name, "_telemouse", "_udp", "local" };
    const host_labels = [_][]const u8{ hostname, "local" };

    var w = dns.Writer.init(buf);

    if (std.mem.eql(u8, qname, meta_name) and (qtype == dns.Type.ptr or qtype == dns.Type.any)) {
        w.header(.{ .id = id, .flags = dns.flags_response, .qdcount = 1, .ancount = 1, .nscount = 0, .arcount = 0 }) catch return null;
        w.question(&meta_labels, dns.Type.ptr, dns.class_in) catch return null;
        writeNamePtr(&w, &meta_labels, dns.Type.ptr, 4500, &service_labels) catch return null;
        return w.slice();
    }

    if (!std.mem.eql(u8, qname, service_name) or (qtype != dns.Type.ptr and qtype != dns.Type.any)) {
        return null;
    }

    var additional: u16 = 2; // SRV + TXT
    if (host_ip != null) additional += 1; // A

    w.header(.{ .id = id, .flags = dns.flags_response, .qdcount = 1, .ancount = 1, .nscount = 0, .arcount = additional }) catch return null;
    // Echo the question.
    w.question(&service_labels, dns.Type.ptr, dns.class_in) catch return null;
    // Answer: PTR service -> instance.
    writeNamePtr(&w, &service_labels, dns.Type.ptr, 120, &instance) catch return null;
    // Additional: SRV instance -> host:command_port.
    writeSrv(&w, &instance, 120, command_port, &host_labels) catch return null;
    // Additional: TXT instance -> n=<device_name>.
    writeTxt(&w, &instance, 4500, device_name, width, height) catch return null;
    // Additional: A host -> ip.
    if (host_ip) |ip| writeA(&w, &host_labels, 120, ip) catch return null;

    return w.slice();
}

fn writeNamePtr(w: *dns.Writer, owner: []const []const u8, rtype: u16, ttl: u32, target: []const []const u8) !void {
    try w.name(owner);
    try w.u16v(rtype);
    try w.u16v(dns.class_in);
    try w.u32v(ttl);
    const len_pos = w.pos;
    try w.u16v(0);
    const start = w.pos;
    try w.name(target);
    backfillRdlen(w, len_pos, start);
}

fn writeSrv(w: *dns.Writer, owner: []const []const u8, ttl: u32, srv_port: u16, target: []const []const u8) !void {
    try w.name(owner);
    try w.u16v(dns.Type.srv);
    try w.u16v(dns.class_in);
    try w.u32v(ttl);
    const len_pos = w.pos;
    try w.u16v(0);
    const start = w.pos;
    try w.u16v(0); // priority
    try w.u16v(0); // weight
    try w.u16v(srv_port);
    try w.name(target);
    backfillRdlen(w, len_pos, start);
}

fn writeTxt(w: *dns.Writer, owner: []const []const u8, ttl: u32, device_name: []const u8, width: i32, height: i32) !void {
    try w.name(owner);
    try w.u16v(dns.Type.txt);
    try w.u16v(dns.class_in);
    try w.u32v(ttl);

    var wbuf: [16]u8 = undefined;
    var hbuf: [16]u8 = undefined;
    const wstr = std.fmt.bufPrint(&wbuf, "w={d}", .{width}) catch return error.NoSpace;
    const hstr = std.fmt.bufPrint(&hbuf, "h={d}", .{height}) catch return error.NoSpace;
    const n_len = 2 + device_name.len; // "n=" + name
    if (n_len > 255) return error.NoSpace;

    // rdata is a sequence of length-prefixed key=value strings.
    const rdlen = (1 + n_len) + (1 + wstr.len) + (1 + hstr.len);
    try w.u16v(@intCast(rdlen));
    try w.u8v(@intCast(n_len));
    try w.bytes("n=");
    try w.bytes(device_name);
    try w.u8v(@intCast(wstr.len));
    try w.bytes(wstr);
    try w.u8v(@intCast(hstr.len));
    try w.bytes(hstr);
}

fn writeA(w: *dns.Writer, owner: []const []const u8, ttl: u32, ip: [4]u8) !void {
    try w.name(owner);
    try w.u16v(dns.Type.a);
    try w.u16v(dns.class_in);
    try w.u32v(ttl);
    try w.u16v(4);
    try w.bytes(&ip);
}

fn backfillRdlen(w: *dns.Writer, len_pos: usize, start: usize) void {
    const rdlen: u16 = @intCast(w.pos - start);
    w.buf[len_pos] = @intCast(rdlen >> 8);
    w.buf[len_pos + 1] = @intCast(rdlen & 0xff);
}

fn rd16(msg: []const u8, off: usize) u16 {
    return (@as(u16, msg[off]) << 8) | msg[off + 1];
}

// ===========================================================================
// Responder (server) — raw multicast socket, platform specific
// ===========================================================================

pub const Handle = switch (builtin.os.tag) {
    .linux => i32,
    .windows => usize,
    else => void,
};

/// Configuration captured by value for the responder task (all immutable).
pub const Responder = struct {
    handle: Handle,
    command_port: u16,
    device_name: []const u8,
    width: i32,
    height: i32,

    /// Blocking receive/respond loop. Runs as its own task; touches no shared
    /// mutable state, so it needs no synchronization.
    pub fn run(self: Responder) void {
        switch (builtin.os.tag) {
            .linux => linux_impl.run(self),
            .windows => windows_impl.run(self),
            else => {},
        }
    }
};

/// Create and configure the multicast responder socket. Returns null (and logs)
/// if discovery cannot be set up; the server then simply is not discoverable.
pub fn openResponder(logger: *log.Logger) ?Handle {
    return switch (builtin.os.tag) {
        .linux => linux_impl.open(logger),
        .windows => windows_impl.open(logger),
        else => {
            logger.warn("discovery unsupported on this platform", .{});
            return null;
        },
    };
}

const linux_impl = struct {
    const linux = std.os.linux;

    const ip_mreq = extern struct {
        multiaddr: [4]u8,
        interface: [4]u8,
    };

    fn open(logger: *log.Logger) ?Handle {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
        if (linux.errno(rc) != .SUCCESS) {
            logger.warn("discovery: cannot create socket", .{});
            return null;
        }
        const fd: i32 = @intCast(rc);

        const one: u32 = 1;
        _ = linux.setsockopt(fd, @intCast(linux.SOL.SOCKET), @intCast(linux.SO.REUSEADDR), @ptrCast(&one), 4);
        _ = linux.setsockopt(fd, @intCast(linux.SOL.SOCKET), @intCast(linux.SO.REUSEPORT), @ptrCast(&one), 4);

        var sa = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
        if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            logger.warn("not discoverable: cannot bind udp {d} (already in use?)", .{port});
            _ = linux.close(fd);
            return null;
        }

        var mreq = ip_mreq{ .multiaddr = .{ 224, 0, 0, 251 }, .interface = .{ 0, 0, 0, 0 } };
        if (linux.errno(linux.setsockopt(fd, linux.IPPROTO.IP, linux.IP.ADD_MEMBERSHIP, @ptrCast(&mreq), @sizeOf(ip_mreq))) != .SUCCESS) {
            logger.warn("not discoverable: cannot join multicast group {s}", .{group});
            _ = linux.close(fd);
            return null;
        }
        return fd;
    }

    fn run(self: Responder) void {
        const host_ip = localIp();
        var hbuf: [128]u8 = undefined;
        const host = hostname(&hbuf);

        var buf: [1500]u8 = undefined;
        while (true) {
            var src: linux.sockaddr.in = undefined;
            var srclen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.recvfrom(self.handle, &buf, buf.len, 0, @ptrCast(&src), &srclen);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            var resp_buf: [1500]u8 = undefined;
            // Advertise the machine's hostname as the display name (not the
            // uinput device name), so clients list the computer, not the device.
            const resp = buildResponse(&resp_buf, buf[0..rc], self.command_port, host, self.width, self.height, host_ip, host) orelse continue;
            // RFC 6762: reply by multicast to a real mDNS querier (source port
            // 5353), by unicast to a legacy querier (ephemeral source port).
            if (std.mem.bigToNative(u16, src.port) == port) {
                var maddr = linux.sockaddr.in{
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = @bitCast([4]u8{ 224, 0, 0, 251 }),
                };
                _ = linux.sendto(self.handle, resp.ptr, resp.len, 0, @ptrCast(&maddr), @sizeOf(linux.sockaddr.in));
            } else {
                _ = linux.sendto(self.handle, resp.ptr, resp.len, 0, @ptrCast(&src), srclen);
            }
        }
    }

    fn hostname(buf: []u8) []const u8 {
        var uts: linux.utsname = undefined;
        if (linux.errno(linux.uname(&uts)) != .SUCCESS) return "telemouse";
        const node = std.mem.sliceTo(&uts.nodename, 0);
        const n = @min(node.len, buf.len);
        @memcpy(buf[0..n], node[0..n]);
        return buf[0..n];
    }

    fn localIp() ?[4]u8 {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var dest = linux.sockaddr.in{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast([4]u8{ 224, 0, 0, 251 }),
        };
        if (linux.errno(linux.connect(fd, @ptrCast(&dest), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return null;
        var local: linux.sockaddr.in = undefined;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&local), &len)) != .SUCCESS) return null;
        return @bitCast(local.addr);
    }
};

const windows_impl = struct {
    const AF_INET: i32 = 2;
    const SOCK_DGRAM: i32 = 2;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_REUSEADDR: i32 = 4;
    const IPPROTO_IP: i32 = 0;
    const IP_ADD_MEMBERSHIP: i32 = 12; // Windows value
    const INVALID_SOCKET: usize = ~@as(usize, 0);

    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *anyopaque) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, type: i32, protocol: i32) callconv(.winapi) usize;
    extern "ws2_32" fn setsockopt(s: usize, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn bind(s: usize, name: *const anyopaque, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recvfrom(s: usize, buf: [*]u8, len: i32, flags: i32, from: *anyopaque, fromlen: *i32) callconv(.winapi) i32;
    extern "ws2_32" fn sendto(s: usize, buf: [*]const u8, len: i32, flags: i32, to: *const anyopaque, tolen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) i32;
    extern "kernel32" fn GetComputerNameA(lpBuffer: [*]u8, nSize: *u32) callconv(.winapi) i32;

    fn computerName(buf: []u8) []const u8 {
        var n: u32 = @intCast(buf.len);
        if (GetComputerNameA(buf.ptr, &n) != 0 and n > 0) return buf[0..n];
        return "telemouse";
    }

    const sockaddr_in = extern struct {
        family: u16 = AF_INET,
        port: u16, // network order
        addr: u32, // network order
        zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    const ip_mreq = extern struct {
        multiaddr: [4]u8,
        interface: [4]u8,
    };

    fn open(logger: *log.Logger) ?Handle {
        var wsadata: [512]u8 = undefined;
        _ = WSAStartup(0x0202, @ptrCast(&wsadata));

        const s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s == INVALID_SOCKET) {
            logger.warn("discovery: cannot create socket", .{});
            return null;
        }

        const one: u32 = 1;
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), 4);

        var sa = sockaddr_in{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
        if (bind(s, @ptrCast(&sa), @sizeOf(sockaddr_in)) != 0) {
            logger.warn("not discoverable: cannot bind udp {d} (already in use?)", .{port});
            _ = closesocket(s);
            return null;
        }

        var mreq = ip_mreq{ .multiaddr = .{ 224, 0, 0, 251 }, .interface = .{ 0, 0, 0, 0 } };
        if (setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, @ptrCast(&mreq), @sizeOf(ip_mreq)) != 0) {
            logger.warn("not discoverable: cannot join multicast group {s}", .{group});
            _ = closesocket(s);
            return null;
        }
        return s;
    }

    fn run(self: Responder) void {
        var hbuf: [256]u8 = undefined;
        const host = computerName(&hbuf);
        var buf: [1500]u8 = undefined;
        while (true) {
            var src: sockaddr_in = undefined;
            var srclen: i32 = @sizeOf(sockaddr_in);
            const n = recvfrom(self.handle, &buf, buf.len, 0, @ptrCast(&src), &srclen);
            if (n <= 0) continue;
            var resp_buf: [1500]u8 = undefined;
            // Advertise the computer name as the display name (not the uinput
            // device name).
            const resp = buildResponse(&resp_buf, buf[0..@intCast(n)], self.command_port, host, self.width, self.height, null, host) orelse continue;
            // Multicast reply to a real mDNS querier (source port 5353),
            // unicast reply to a legacy querier (ephemeral source port).
            if (std.mem.bigToNative(u16, src.port) == port) {
                var maddr = sockaddr_in{
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = @bitCast([4]u8{ 224, 0, 0, 251 }),
                };
                _ = sendto(self.handle, resp.ptr, @intCast(resp.len), 0, @ptrCast(&maddr), @sizeOf(sockaddr_in));
            } else {
                _ = sendto(self.handle, resp.ptr, @intCast(resp.len), 0, @ptrCast(&src), srclen);
            }
        }
    }
};

test "buildResponse answers a service query" {
    var qbuf: [512]u8 = undefined;
    const query = try buildQuery(&qbuf);

    var rbuf: [512]u8 = undefined;
    const resp = buildResponse(&rbuf, query, 24800, "test device", 1920, 1080, .{ 10, 0, 0, 5 }, "host") orelse
        return error.NoResponse;

    var parser = try dns.Parser.init(resp);
    var found_srv = false;
    var found_a = false;
    var name_buf: [256]u8 = undefined;
    while (try parser.next()) |rec| {
        if (rec.type == dns.Type.srv) {
            const s = try parser.srv(rec, &name_buf);
            try std.testing.expectEqual(@as(u16, 24800), s.port);
            found_srv = true;
        }
        if (rec.type == dns.Type.a) {
            try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, parser.a(rec).?);
            found_a = true;
        }
    }
    try std.testing.expect(found_srv and found_a);
}

test "buildResponse ignores unrelated queries" {
    var qbuf: [512]u8 = undefined;
    var w = dns.Writer.init(&qbuf);
    try w.header(.{ .id = 1, .flags = 0, .qdcount = 1, .ancount = 0, .nscount = 0, .arcount = 0 });
    try w.question(&.{ "_other", "_udp", "local" }, dns.Type.ptr, dns.class_in);
    var rbuf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), buildResponse(&rbuf, w.slice(), 24800, "d", 1920, 1080, null, "h"));
}
