// Smoke test for the ween32 dependency: drive the win32-compatible API from
// Zig, headless (no display). Proves the bindings' ABI, the message loop, the
// control classes and painting work end to end before the config UI moves
// onto them. Runs only on Linux (on Windows the same bindings are the real
// user32, which has no headless mode).

const std = @import("std");
const builtin = @import("builtin");
const w = @import("ween32");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const ID_OK = 1;

var got_create: bool = false;
var got_paint: bool = false;
var got_click: bool = false;

fn wndProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.c) w.LRESULT {
    switch (msg) {
    w.WM_CREATE => {
        got_create = true;
        _ = w.CreateWindowA("BUTTON", "OK", w.WS_CHILD | w.WS_VISIBLE | w.BS_PUSHBUTTON, 20, 20, 75, 23, hwnd, @ptrFromInt(ID_OK), null, null);
        return 0;
    },
    w.WM_PAINT => {
        var ps: w.PAINTSTRUCT = undefined;
        const dc = w.BeginPaint(hwnd, &ps) orelse return 0;
        got_paint = true;
        // exercise the GDI surface the config UI will use
        var well = w.RECT{ .left = 10, .top = 60, .right = 150, .bottom = 100 };
        _ = w.FillRect(dc, &well, w.CreateSolidBrush(w.RGB(58, 110, 165)).?);
        _ = w.DrawEdge(dc, &well, w.EDGE_SUNKEN, w.BF_RECT);
        _ = w.FrameRect(dc, &well, w.GetSysColorBrush(w.COLOR_BTNTEXT).?);
        _ = w.SetTextColor(dc, w.GetSysColor(w.COLOR_BTNTEXT));
        _ = w.TextOutA(dc, 12, 62, "hello from zig", 14);
        _ = w.EndPaint(hwnd, &ps);
        return 0;
    },
    w.WM_COMMAND => {
        if (w.LOWORD(wp) == ID_OK) {
            got_click = true;
            _ = w.DestroyWindow(hwnd);
        }
        return 0;
    },
    w.WM_DESTROY => {
        w.PostQuitMessage(0);
        return 0;
    },
    else => return w.DefWindowProcA(hwnd, msg, wp, lp),
    }
}

test "ween32 from zig: window, paint, button click, message loop" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    _ = setenv("WEEN32_HEADLESS", "1", 1);
    // click the OK button: client (20,20)+37,11 -> window coords (+3,+23)
    _ = setenv("WEEN32_SCRIPT", "d:60,54 u:60,54", 1);

    var wc = std.mem.zeroInit(w.WNDCLASSA, .{
        .lpfnWndProc = &wndProc,
        .lpszClassName = "zigsmoke",
        .hbrBackground = w.GetSysColorBrush(w.COLOR_BTNFACE),
    });
    try std.testing.expect(w.RegisterClassA(&wc) != 0);

    const wnd = w.CreateWindowExA(0, "zigsmoke", "ween32 x zig", w.WS_POPUP | w.WS_CAPTION | w.WS_SYSMENU | w.WS_VISIBLE, 0, 0, 320, 180, null, null, null, null) orelse return error.CreateFailed;
    try std.testing.expect(got_create);
    try std.testing.expect(w.GetDlgItem(wnd, ID_OK) != null);

    var rc: w.RECT = undefined;
    _ = w.GetClientRect(wnd, &rc);
    try std.testing.expectEqual(@as(w.LONG, 314), rc.right);
    try std.testing.expectEqual(@as(w.LONG, 154), rc.bottom);

    // dialog-unit sanity: the classic 50x14 DLU button is 75x23 px
    const base = w.GetDialogBaseUnits();
    try std.testing.expectEqual(@as(c_int, 75), w.MulDiv(50, w.LOWORD(base), 4));
    try std.testing.expectEqual(@as(c_int, 23), w.MulDiv(14, w.HIWORD(base), 8));

    _ = w.UpdateWindow(wnd);
    try std.testing.expect(got_paint);

    var msg: w.MSG = undefined;
    while (w.GetMessageA(&msg, null, 0, 0) != 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageA(&msg);
    }
    try std.testing.expect(got_click);
}
