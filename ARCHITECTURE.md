# telemouse architecture

Design and internals. For installing and using telemouse, see the
[README](README.md).

telemouse is two programs:

- **`tms`** (server) — a headless daemon that *injects* mouse/keyboard input on
  the machine it runs on.
- **`tmc`** (client) — owns the physical keyboard and mouse; it *captures* local
  input and forwards it, and drives the edge-switching state machine.

## Transport

Commands travel over whichever transport fits them, both on the same address and
port:

- **Relative pointer motion (`move dx dy`) goes over UDP.** It is the streamed
  motion during edge switching. Being relative it is loss- and order-tolerant (a
  dropped delta just leaves you a pixel short; reordered deltas still sum to the
  same place), so it favours latency over reliability.
- **Everything else goes over TCP** — clicks, key strokes, absolute placement,
  cursor visibility and clipboard updates. These are discrete events where a lost
  or reordered event would be wrong, so they need a reliable, ordered channel.

Commands are otherwise **fire-and-forget**: the server does not acknowledge them
(it logs failures), and the client validates syntax locally before sending. The
one exception is `place` (the placement at an edge crossing), which the server
acknowledges with `placed` so the client can gate its UDP motion stream on the
ack and never let a `move` overtake the placement.

## Server event loop

The server services both sockets (and the connected client's TCP channel) from a
single `Io.Select` event loop: it waits for whichever source has an event and
handles it to completion. Every command is applied on that one loop, so the input
device is never touched concurrently — concurrency without parallelism, no
locking. The loop also wakes periodically to poll for local pointer activity (see
[cursor management](#cursor-management)) and to forward local clipboard changes.

Discovery runs on its own thread (it only reads immutable data), as does the
clipboard worker (its own X connection; it exchanges text with the main loop
through small mutex-guarded slots).

## Discovery

Discovery uses **mDNS / DNS-SD** (multicast DNS on `224.0.0.251:5353`),
implemented in-process — no Avahi or Bonjour daemon. Every `tms` advertises the
service type `_telemouse._udp.local` and answers queries with the standard
records (PTR, SRV, TXT, A), so the client learns each server's address and
command port regardless of which port it runs on. Because it is standard DNS-SD,
servers also appear in tools like `avahi-browse -r _telemouse._udp`.

The client queries from an ephemeral port, so (per RFC 6762) responders answer by
unicast straight back — no multicast group membership needed on the client. The
server joins the group on UDP 5353 (coexisting with a system responder via
`SO_REUSEADDR`/`SO_REUSEPORT`); if it cannot, it logs a warning and runs
un-discoverable.

## Edge switching

Configure neighbour servers around the client's screen and pushing the pointer
off an edge hands mouse **and** keyboard control to the neighbour, Synergy-style.

### Server-driven crossing (the "reach" model)

The client streams *relative* motion to the server. The server owns the remote
cursor, so it is authoritative about where that cursor actually is (after pointer
acceleration). After each `move` the server queries the real cursor position; the
first time it reaches a screen edge it sends the client a `reach <side> <perp>`
event, and the client decides whether to cross to the neighbour on that side.
This is what makes the crossing point line up with the edge regardless of pointer
speed — an earlier design that integrated raw client-side deltas drifted, because
raw motion diverges from the accelerated cursor.

Entry onto a screen is an absolute `place x y` (acked); the server places the
cursor with `XWarpPointer` (a REL/ABS-mixed uinput device has its absolute events
ignored by libinput, so warping is the reliable path).

### Backend selection

Both ends pick their input mechanism from the platform and, on Linux, the
session — so an X11 session needs no permissions at all:

| | X11 | Wayland / headless |
|---|---|---|
| **server** injects via | `XTEST` (no permissions) | `uinput` (`/dev/uinput`) |
| **client** captures via | `XInput2` (no permissions) | `evdev` (`/dev/input`) |

The session is detected from `WAYLAND_DISPLAY` / `DISPLAY`. `XTEST`/`XInput2` are
ordinary X-client operations needing no privilege; `libXtst` is loaded at runtime
via `dlopen`, so it is an optional dependency that degrades to uinput if absent.
`--backend xtest|kernel` (server) and `--capture xinput|evdev` (client) force the
choice.

### Capture, grabbing and the cooked/raw split

While control is **local**, the XInput2 backend selects *raw* device events on
the root window — global monitoring with no grab, so the apps you're using keep
working. While control is **remote**, it grabs the pointer and keyboard
(`XGrabPointer`/`XGrabKeyboard`) so local apps stop seeing input, and drives off
the grab's *cooked* events (relative motion is recovered by warping the pointer to
screen centre and reading each event's offset — a grab suppresses raw events, so
raw motion can't be used here). Raw events that arrive while grabbed are
stragglers queued before the grab took effect and are still processed, so a
key-release begun just before crossing isn't dropped.

evdev is simpler: it reads `/dev/input/event*` and `EVIOCGRAB`s the devices while
control is remote (the grab is why the local pointer "freezes"). On Windows,
low-level hooks (`WH_MOUSE_LL` / `WH_KEYBOARD_LL`) suppress local input and trap
the cursor at screen centre; because a hook callback must return quickly it does
no network I/O — it runs on a pump thread and hands events to the main thread over
a lock-free queue.

### Modifier hand-off

A modifier held across a crossing (Ctrl during a drag) must stay held on the new
screen. On crossing the client releases every held key on the screen being *left*
(so nothing sticks there) but re-presses only **modifiers** on the one being
*entered* — a non-modifier in the held set can be a phantom from a timing race,
and re-pressing it with no matching release would leave it stuck auto-repeating.

### Cursor management

The neighbour's cursor is hidden while it isn't the focused screen and revealed
when control enters it (`XFixes`). If the server's own physical mouse moves while
it is "away", it reveals the cursor at screen centre and hands control back to the
local mouse, so the machine stays usable directly. On a lost connection each side
recentres and restores its cursor.

### Safety

Because grabbing input can otherwise strand the pointer, several guards exist:

- **Connectivity gate** — the client only commits a handover (grab + hide) once
  the server acknowledges the placement; an absent server can't strand the cursor.
- **Panic escape** — `Ctrl+Alt+Esc` while control is remote force-returns it to
  the local screen.
- **Connection-loss recovery** — if the server being controlled drops, the client
  returns home; if the controlling client drops, the server restores its cursor.
- **Key release on exit** — the server releases every held key on client
  disconnect, graceful shutdown, and crash signals (a modifier would otherwise
  stay pressed, since XTEST key state lives in the X server). `SIGKILL` is
  uncatchable.

### Keyboard layout

Captured keys are forwarded through the client's local layout, so an `xmodmap`
remap (e.g. Caps Lock → a meta modifier) carries over to the server: the client
snapshots the X keymap and translates each scancode through it.

## Shared clipboard

Copy on any machine, paste on any other (UTF-8 text, the `CLIPBOARD` selection).
Each process runs a clipboard worker on its own thread with its own X connection:
it notices local copies (XFixes owner-change) and *owns* the selection to serve
pastes of text from another machine. The client is the hub — a copy is relayed to
every other machine — and a loop-guard stops echoes. Sent as `clipboard <base64>`
over TCP. v1 is text only, capped in size, no chunked transfer.

## Protocol

A command is one text line: a verb and arguments. Names are case-insensitive.

| Command | Transport | Effect |
|---|---|---|
| `mouse <x> <y>` | TCP | Move the pointer to absolute pixel (x, y). |
| `move <dx> <dy>` | UDP | Move the pointer by a relative delta. |
| `place <x> <y>` | TCP | Absolute placement at an edge crossing (acked with `placed`). |
| `click <button>` | TCP | Click `left` \| `right` \| `middle`. |
| `key <combo>` | TCP | Generate a key stroke. |
| `keydown <key>` / `keyup <key>` | TCP | Press / release a key without the other. |
| `buttondown <b>` / `buttonup <b>` | TCP | Press / release a mouse button. |
| `scroll <dx> <dy>` | TCP | Scroll by dx (horizontal) / dy (vertical) notches. |
| `hide` | TCP | Hide the server's cursor (control left this screen). |
| `clipboard <base64>` | TCP | Shared-clipboard text update. |

`<combo>` is a `+`-separated list where every element but the last is a modifier
and the last is the key: `a`, `ctrl+c`, `ctrl+alt+t`, `shift+1`, `alt+f4`.

Recognised key names:

- **Modifiers:** `ctrl`, `shift`, `alt`, `altgr`, `super` (aka `meta`, `win`).
- **Letters / digits:** `a`–`z`, `0`–`9`.
- **Named keys:** `space`, `tab`, `enter`/`return`, `esc`/`escape`, `backspace`,
  `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, `up`, `down`, `left`,
  `right`, `capslock`, `f1`–`f12`.
- **Punctuation:** `minus`, `equal`, `leftbrace`, `rightbrace`, `semicolon`,
  `apostrophe`, `grave`, `backslash`, `comma`, `dot`/`period`, `slash`.

## Source layout

```
src/
  common/
    clap.zig       command-line parser (ported from jdmichaud/zig-utils)
    config.zig     generic ZON configuration loading
    log.zig        leveled logging to stdout / file / syslog
    protocol.zig   command parsing and transport routing
    dns.zig        minimal DNS message encoder/decoder
    mdns.zig       mDNS / DNS-SD responder and querier
    keymap.zig     Linux input-event codes and key-name table
    keysyms.zig    X keysym -> key-name translation (layout honouring)
    xdisplay.zig   shared X helper (place/track/hide the cursor)
    clipboard.zig  shared-clipboard worker
  tms/
    config.zig     server configuration
    input.zig      injection backend abstraction (dry-run / native)
    linux.zig      Linux backend dispatcher (XTEST vs uinput)
    xtest.zig      X11 injection (XTEST)
    uinput.zig     kernel injection (uinput)
    winput.zig     Windows injection (SendInput)
  tmc/
    switcher.zig   edge-switching state machine
    session.zig    sender + edge-switch session (drives both capture backends)
    xcapture.zig   X11 capture (XInput2)
    evdev.zig      kernel capture (read + grab /dev/input)
    xcursor.zig    X cursor tracking / hiding for the client
    wincapture.zig Windows capture (low-level hooks)
  ui/              framebuffer-rendered screen-arrangement configuration UI
  tms.zig          server entry point (Io.Select event loop)
  tmc.zig          client entry point
```

`PLAN.md` and `STATUS.md` hold the original design-of-record and a running status
checklist.
