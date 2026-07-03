// Windows input capture via low-level hooks.
//
// `WH_MOUSE_LL` and `WH_KEYBOARD_LL` hooks receive every mouse and keyboard
// event before applications do. While control is local the hooks pass events
// through; once the pointer crosses to a neighbour the hooks *suppress* events
// (return non-zero) -- that is the "grab" that freezes the local cursor.
//
// Low-level mouse events carry absolute cursor positions, so while local we
// derive motion by differencing successive positions. While remote we trap the
// cursor at the screen centre (SetCursorPos after each event) and measure the
// offset from the centre.
//
// A low-level hook callback must return quickly or Windows silently removes the
// hook. Mouse motion is fire-and-forget UDP, which never blocks, so the callback
// sends it directly. The reliable TCP events (keys, buttons, scroll) can block,
// so the callback instead pushes them onto a lock-free single-producer/single-
// consumer queue: the hooks run on a dedicated pump thread and the main thread
// -- which owns the `Io` used by the senders -- drains the queue and does those
// sends. A Win32 auto-reset event wakes the drainer. No mutex is involved, and
// because only occasional TCP events are queued the ring never fills.
//
// This module is compiled only for Windows.

const std = @import("std");
const log = @import("../common/log.zig");
const session_mod = @import("session.zig");

const WH_KEYBOARD_LL: i32 = 13;
const WH_MOUSE_LL: i32 = 14;
const SM_CXSCREEN: i32 = 0;
const SM_CYSCREEN: i32 = 1;
const INFINITE: u32 = 0xFFFFFFFF;

const WM_MOUSEMOVE: usize = 0x0200;
const WM_LBUTTONDOWN: usize = 0x0201;
const WM_LBUTTONUP: usize = 0x0202;
const WM_RBUTTONDOWN: usize = 0x0204;
const WM_RBUTTONUP: usize = 0x0205;
const WM_MBUTTONDOWN: usize = 0x0207;
const WM_MBUTTONUP: usize = 0x0208;
const WM_MOUSEWHEEL: usize = 0x020A;
const WM_MOUSEHWHEEL: usize = 0x020E;
const WM_KEYDOWN: usize = 0x0100;
const WM_KEYUP: usize = 0x0101;
const WM_SYSKEYDOWN: usize = 0x0104;
const WM_SYSKEYUP: usize = 0x0105;

const POINT = extern struct { x: i32, y: i32 };

const MSG = extern struct {
    hwnd: ?*anyopaque,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

const MSLLHOOKSTRUCT = extern struct {
    pt: POINT,
    mouseData: u32,
    flags: u32,
    time: u32,
    dwExtraInfo: usize,
};

const KBDLLHOOKSTRUCT = extern struct {
    vkCode: u32,
    scanCode: u32,
    flags: u32,
    time: u32,
    dwExtraInfo: usize,
};

const HOOKPROC = *const fn (code: i32, wParam: usize, lParam: isize) callconv(.winapi) isize;

extern "user32" fn SetWindowsHookExW(idHook: i32, lpfn: HOOKPROC, hmod: ?*anyopaque, dwThreadId: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn UnhookWindowsHookEx(hhk: ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn CallNextHookEx(hhk: ?*anyopaque, nCode: i32, wParam: usize, lParam: isize) callconv(.winapi) isize;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?*anyopaque, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) i32;
extern "user32" fn SetCursorPos(x: i32, y: i32) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) i32;
extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: i32, bInitialState: i32, lpName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(hEvent: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: ?*anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;

// ---- state shared with the C hook callbacks (pump thread only) ------------
var g_session: ?*session_mod.Session = null;
var g_remote: bool = false;
var g_center: POINT = .{ .x = 0, .y = 0 };
var g_last: POINT = .{ .x = 0, .y = 0 };
var g_mouse_hook: ?*anyopaque = null;
var g_kbd_hook: ?*anyopaque = null;
var g_hook_state: std.atomic.Value(u8) = .init(0); // 0 starting, 1 ok, 2 failed

// ---- lock-free single-producer/single-consumer queue (TCP events only) ----
const ring_capacity = 256;
var ring_buf: [ring_capacity]session_mod.OutCmd = undefined;
var ring_head: std.atomic.Value(usize) = .init(0); // written by pump thread
var ring_tail: std.atomic.Value(usize) = .init(0); // written by main thread
var g_event: ?*anyopaque = null;

fn ringPush(cmd: session_mod.OutCmd) void {
    const head = ring_head.load(.monotonic);
    const next = (head + 1) % ring_capacity;
    if (next == ring_tail.load(.acquire)) return; // full: drop
    ring_buf[head] = cmd;
    ring_head.store(next, .release);
    _ = SetEvent(g_event);
}

fn ringPop() ?session_mod.OutCmd {
    const tail = ring_tail.load(.monotonic);
    if (tail == ring_head.load(.acquire)) return null;
    const cmd = ring_buf[tail];
    ring_tail.store((tail + 1) % ring_capacity, .release);
    return cmd;
}

pub fn run(session: *session_mod.Session, logger: *log.Logger) void {
    const w = GetSystemMetrics(SM_CXSCREEN);
    const h = GetSystemMetrics(SM_CYSCREEN);
    session.sw.w = @max(w, 1);
    session.sw.h = @max(h, 1);
    g_center = .{ .x = @divTrunc(w, 2), .y = @divTrunc(h, 2) };
    g_session = session;
    g_remote = false;
    _ = GetCursorPos(&g_last);

    g_event = CreateEventW(null, 0, 0, null); // auto-reset, initially unsignaled
    if (g_event == null) {
        logger.err("cannot create synchronisation event", .{});
        return;
    }

    var thread = std.Thread.spawn(.{}, pumpThread, .{}) catch |e| {
        logger.err("cannot start capture thread: {s}", .{@errorName(e)});
        return;
    };
    thread.detach();

    // Wait for the pump thread to report whether the hooks installed.
    _ = WaitForSingleObject(g_event, INFINITE);
    if (g_hook_state.load(.acquire) == 2) {
        logger.err("cannot install input hooks", .{});
        return;
    }
    logger.info("edge switching active on a {d}x{d} screen; push the pointer to a configured edge", .{ w, h });

    // Send side: drain the queue on this (Io-owning) thread.
    while (true) {
        while (ringPop()) |cmd| session.forward(cmd);
        _ = WaitForSingleObject(g_event, INFINITE);
    }
}

fn pumpThread() void {
    const hmod = GetModuleHandleW(null);
    g_mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, mouseProc, hmod, 0);
    g_kbd_hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, hmod, 0);
    if (g_mouse_hook == null or g_kbd_hook == null) {
        g_hook_state.store(2, .release);
        _ = SetEvent(g_event);
        return;
    }
    g_hook_state.store(1, .release);
    _ = SetEvent(g_event);

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {}

    if (g_mouse_hook) |hh| _ = UnhookWindowsHookEx(hh);
    if (g_kbd_hook) |hh| _ = UnhookWindowsHookEx(hh);
}

fn recenter() void {
    _ = SetCursorPos(g_center.x, g_center.y);
}

fn mouseProc(code: i32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (code >= 0) {
        if (g_session) |s| {
            const info: *const MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            switch (wparam) {
                WM_MOUSEMOVE => {
                    const pt = info.pt;
                    if (g_remote and pt.x == g_center.x and pt.y == g_center.y) return 1;

                    const dx = if (g_remote) pt.x - g_center.x else pt.x - g_last.x;
                    const dy = if (g_remote) pt.y - g_center.y else pt.y - g_last.y;
                    g_last = pt;

                    const d = s.decide(dx, dy);
                    switch (d.transition) {
                        .none => {},
                        .grab => {
                            g_remote = true;
                            recenter();
                        },
                        .ungrab => |p| {
                            g_remote = false;
                            _ = SetCursorPos(p.x, p.y);
                            g_last = .{ .x = p.x, .y = p.y };
                        },
                    }
                    // Relative motion (UDP) is fire-and-forget: send it right
                    // here. The absolute placement on entry (TCP) is queued.
                    if (d.out) |cmd| emit(s, cmd);
                    while (s.nextPending()) |cmd| emit(s, cmd); // modifier hand-off
                    if (g_remote) {
                        recenter();
                        return 1;
                    }
                },
                WM_LBUTTONDOWN => if (g_remote) return pushButton(s, true, "left"),
                WM_LBUTTONUP => if (g_remote) return pushButton(s, false, "left"),
                WM_RBUTTONDOWN => if (g_remote) return pushButton(s, true, "right"),
                WM_RBUTTONUP => if (g_remote) return pushButton(s, false, "right"),
                WM_MBUTTONDOWN => if (g_remote) return pushButton(s, true, "middle"),
                WM_MBUTTONUP => if (g_remote) return pushButton(s, false, "middle"),
                WM_MOUSEWHEEL => if (g_remote) {
                    if (s.captureScroll(0, wheelNotches(info.mouseData))) |cmd| emit(s, cmd);
                    return 1;
                },
                WM_MOUSEHWHEEL => if (g_remote) {
                    if (s.captureScroll(wheelNotches(info.mouseData), 0)) |cmd| emit(s, cmd);
                    return 1;
                },
                else => {},
            }
        }
    }
    return CallNextHookEx(null, code, wparam, lparam);
}

/// UDP commands are non-blocking, so send them straight from the callback; TCP
/// commands are queued for the drainer thread.
fn emit(s: *session_mod.Session, cmd: session_mod.OutCmd) void {
    if (cmd.transport() == .udp) s.forward(cmd) else ringPush(cmd);
}

fn pushButton(s: *session_mod.Session, down: bool, name: []const u8) isize {
    if (s.captureButton(down, name)) |cmd| emit(s, cmd);
    return 1;
}

fn wheelNotches(mouse_data: u32) i32 {
    const raw: i16 = @bitCast(@as(u16, @truncate(mouse_data >> 16)));
    return @divTrunc(@as(i32, raw), 120); // WHEEL_DELTA
}

fn keyboardProc(code: i32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (code >= 0 and g_remote) {
        if (g_session) |s| {
            const info: *const KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const down = wparam == WM_KEYDOWN or wparam == WM_SYSKEYDOWN;
            const up = wparam == WM_KEYUP or wparam == WM_SYSKEYUP;
            if (down or up) {
                if (vkName(info.vkCode)) |name| {
                    if (s.captureKey(down, name)) |cmd| emit(s, cmd);
                }
                return 1; // swallow while remote
            }
        }
    }
    return CallNextHookEx(null, code, wparam, lparam);
}

const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
const digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
const fkeys = [_][]const u8{ "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" };

/// Map a Windows virtual key code to a protocol key name.
fn vkName(vk: u32) ?[]const u8 {
    if (vk >= 0x41 and vk <= 0x5A) return letters[vk - 0x41];
    if (vk >= 0x30 and vk <= 0x39) return digits[vk - 0x30];
    if (vk >= 0x70 and vk <= 0x7B) return fkeys[vk - 0x70];
    return switch (vk) {
        0x10, 0xA0 => "shift",
        0xA1 => "rightshift",
        0x11, 0xA2 => "ctrl",
        0xA3 => "rightctrl",
        0x12, 0xA4 => "alt",
        0xA5 => "altgr",
        0x5B, 0x5C => "super",
        0x0D => "enter",
        0x1B => "escape",
        0x09 => "tab",
        0x20 => "space",
        0x08 => "backspace",
        0x2E => "delete",
        0x2D => "insert",
        0x24 => "home",
        0x23 => "end",
        0x21 => "pageup",
        0x22 => "pagedown",
        0x26 => "up",
        0x28 => "down",
        0x25 => "left",
        0x27 => "right",
        0x14 => "capslock",
        0xBD => "minus",
        0xBB => "equal",
        0xDB => "leftbrace",
        0xDD => "rightbrace",
        0xBA => "semicolon",
        0xDE => "apostrophe",
        0xC0 => "grave",
        0xDC => "backslash",
        0xBC => "comma",
        0xBE => "dot",
        0xBF => "slash",
        else => null,
    };
}
