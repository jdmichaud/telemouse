# telemouse

Control a computer's mouse and keyboard over the network.

`telemouse` is two small programs:

- **`tms`** — the *server*: a headless daemon that generates mouse and keyboard
  input on the machine it runs on, driven by remote clients.
- **`tmc`** — the *client*: discovers servers on the local network and sends
  them commands.

It works on **Linux** (injecting via `XTEST` on X11 — no permissions needed — or
the `uinput` kernel subsystem on Wayland/headless) and **Windows** (via the Win32
`SendInput` / `SetCursorPos` APIs); the backend is chosen from the platform and,
on Linux, the session.

## Transport

Commands travel over the transport that best fits them:

- **Relative pointer motion (`move dx dy`) goes over UDP.** This is the streamed
  motion during edge switching. Being relative it is loss- and order-tolerant (a
  dropped delta just leaves you a pixel short, which you correct without
  noticing; reordered deltas still sum to the same place), and it composes
  across chained servers — so it favours low latency over reliability.
- **Everything else goes over TCP** — clicks, key strokes, and absolute
  placement (`mouse x y`). These are discrete events where a lost or reordered
  event would be wrong, so they use a reliable, ordered channel.

Edge switching combines the two: on crossing onto a neighbour it places the
pointer once with an absolute `mouse` (reliable), then streams `move` deltas.

Both share the same address and port. Commands are **fire-and-forget**: the
server does not acknowledge them (it logs failures instead), and the client
validates command syntax locally before sending.

The server services both sockets from a single event loop (`Io.Select`): it
waits for whichever socket has an event and handles it to completion. Every
command is applied on that one loop, so the input device is never touched
concurrently — concurrency without parallelism, and no locking.

## Discovery

Discovery uses **mDNS / DNS-SD** (the multicast-DNS zeroconf mechanism, on
`224.0.0.251:5353`) — implemented in-process, with no Avahi or Bonjour daemon
required. Every `tms` advertises the service type `_telemouse._udp.local` and
answers queries with the standard records (PTR, SRV, TXT, A), so the client
learns each server's address and command port regardless of which port it runs
on. Launched with **no arguments from a terminal**, `tmc` sends a query and
prints what answers:

```sh
$ tmc
10.0.2.15:24801  telemouse virtual input
192.168.1.42:24800  living-room htpc
```

Because it is standard DNS-SD, servers also show up in other zeroconf tools:

```sh
$ avahi-browse -r _telemouse._udp
```

The client queries from an ephemeral port, so (per RFC 6762) responders answer
by unicast straight back to it — no multicast group membership is needed on the
client. The server does join the group on UDP 5353 (coexisting with a system
mDNS responder via `SO_REUSEADDR`/`SO_REUSEPORT`); if it cannot, it logs a
warning and simply runs without being discoverable.

## Building

Requires a recent Zig (0.17-dev or newer).

```sh
zig build                        # builds ./zig-out/bin/tms and ./zig-out/bin/tmc
zig build -Doptimize=ReleaseSafe
zig build test                   # run the unit tests
zig build -Dtarget=x86_64-windows  # cross-compile tms.exe and tmc.exe
```

Convenience run steps (arguments after `--` are passed through):

```sh
zig build run-tms -- --dry-run --log-level debug
zig build run-tmc -- -e "mouse 100 200"
```

## Running

Start the server (defaults to `0.0.0.0:24800`):

```sh
tms                              # serve on every interface, port 24800
tms -a 127.0.0.1 -p 9000         # bind a specific address / port
tms --dry-run --log-level debug  # log commands instead of emitting them
```

Use the client:

```sh
tmc                              # (in a terminal) discover servers on the LAN
tmc -a 10.0.2.15 -e "mouse 960 540"    # send one command, then exit
tmc -a 10.0.2.15 -e "key ctrl+alt+t"
printf 'mouse 0 0\nclick left\n' | tmc -a 10.0.2.15   # stream commands from stdin
```

`tmc` chooses its mode automatically: with `-e` it sends a single command; if
any edge neighbour is configured (see [Edge switching](#edge-switching)) it runs
as an edge-switching client; with input piped or redirected on stdin it forwards
each line; run bare from a terminal it discovers servers.

## Edge switching

Configure a neighbour server for one or more screen edges and `tmc` behaves like
Synergy/Barrier: push the pointer off that edge and mouse **and** keyboard
control jump to the neighbour. The local pointer freezes (the input devices are
grabbed, so it "disappears"), and motion, clicks, key strokes and scrolling are
forwarded to the neighbour until the pointer crosses back.

```zig
// in tmc.zon
.{
    .screen_width = 1920,
    .screen_height = 1080,
    .right = "192.168.1.20:24800",   // a tms to the right of this screen
    .left = "192.168.1.21:24800",
}
```

Then just run `tmc` (no arguments). It reports which neighbour has control as
the pointer moves between screens.

Capture is platform specific:

- **Linux** captures through `XInput2` on an X11 session (no permissions — see
  [Linux permissions](#linux-permissions)) and falls back to evdev
  (`/dev/input/event*` + `EVIOCGRAB`, needs the `input` group) on
  Wayland/headless. Either way it grabs input while control is remote so local
  apps stop seeing it. The client's own resolution is detected from the display,
  and captured keys are forwarded through your local layout, so an `xmodmap`
  remap (e.g. Caps Lock → a meta modifier) carries over to the server.
- **Windows** uses low-level hooks (`WH_MOUSE_LL` / `WH_KEYBOARD_LL`): while
  control is remote the hooks suppress local input and the cursor is trapped at
  the screen centre to read relative motion. The real screen size is queried
  from the system, so `screen_width`/`screen_height` are only used on Linux.
  Because a hook callback must return quickly, it does no network I/O: it runs
  on a dedicated pump thread and hands each event to the main thread through a
  lock-free queue, and the main thread does the sending.

Either way the neighbour is assumed to have the same resolution as the local
screen (used to decide when the pointer crosses back).

### Linux permissions

telemouse picks its input mechanism from the session, the way Synergy does — so
**on an X11 session, neither end needs any setup at all** (no root, no `input`
group, no udev rule):

| | X11 session | Wayland / headless |
|---|---|---|
| **server** (`tms`) injects via | `XTEST` — **no permissions** | `uinput` — `input` group + udev |
| **client** (`tmc`) captures via | `XInput2` — **no permissions** | `evdev` — `input` group |

- **On X11, nothing to do.** The server injects through the X server (`XTEST`) and
  the client captures through it (`XInput2` raw events while local; a pointer +
  keyboard grab while control is remote, so local apps stop seeing input). Both
  are ordinary X clients needing no privilege — just `libXtst` / `libXi` present
  (every X desktop has them). Force the backend with `--backend xtest|kernel`
  (server) or `--capture xinput|evdev` (client).
- **Server on Wayland/headless:** falls back to `uinput` (needs `/dev/uinput`).
- **Client on Wayland:** falls back to `evdev` (needs `/dev/input/event*`).

The remaining (Wayland/headless) cases live behind the `input` group. The setup
script grants it (and, for a Wayland/headless server, installs the udev rule that
keeps `/dev/uinput` in that group across reboots):

```sh
./setup-linux.sh --client            # only needed on a Wayland client
./setup-linux.sh --server            # only needed on a Wayland/headless server
./setup-linux.sh --client --server   # a box that does both
```

Log out and back in for the group to take effect (or `newgrp input` in the
current shell). By hand: `sudo usermod -aG input $USER`, plus — for a
Wayland/headless server — a udev rule (`packaging/99-telemouse-uinput.rules`):

```
# /etc/udev/rules.d/99-telemouse-uinput.rules
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
```

then `sudo udevadm control --reload-rules && sudo udevadm trigger`. When it can
reach neither backend, `tms` prints a clear error; use `--dry-run` to exercise
the rest of the pipeline without a real device.

**Run the server as yourself, in your graphical session.** For edge switching
`tms` reads and places the cursor through X (that is how it detects the pointer
reaching a screen edge and hands control back) — and, on X11, injects through it
too. A root process, or the headless `telemouse-server` systemd unit (a dedicated
system user), has no access to your X display, so both stop working; that unit is
only for headless remote-injection, not the KVM/edge-switching setup.

### Windows

No special setup is required. Mouse coordinates are absolute screen pixels;
`screen_width` / `screen_height` are ignored on Windows.

## Commands

| Command                | Transport | Effect                                            |
|------------------------|-----------|---------------------------------------------------|
| `mouse <x> <y>`        | TCP       | Move the pointer to absolute screen pixel (x, y). |
| `move <dx> <dy>`       | UDP       | Move the pointer by a relative delta.             |
| `click <button>`       | TCP       | Click a button: `left`, `right` or `middle`.      |
| `key <combo>`          | TCP       | Generate a key stroke.                            |
| `keydown <key>`        | TCP       | Press a key without releasing it.                 |
| `keyup <key>`          | TCP       | Release a key.                                    |
| `buttondown <button>`  | TCP       | Press a mouse button without releasing it.        |
| `buttonup <button>`    | TCP       | Release a mouse button.                           |
| `scroll <dx> <dy>`     | TCP       | Scroll by `dx` (horizontal) / `dy` (vertical) notches. |

The `keydown`/`keyup`/`buttondown`/`buttonup`/`scroll` commands exist mainly so
edge switching can forward captured input faithfully (held modifiers, drags),
but they work over the plain protocol too.

`<combo>` is a `+`-separated list where every element but the last is a modifier
and the last is the key: `a`, `ctrl+c`, `ctrl+alt+t`, `shift+1`, `alt+f4`,
`Return`.

Recognised names (case-insensitive):

- **Modifiers:** `ctrl`, `shift`, `alt`, `altgr`, `super` (aka `meta`, `win`).
- **Letters / digits:** `a`–`z`, `0`–`9`.
- **Named keys:** `space`, `tab`, `enter`/`return`, `esc`/`escape`,
  `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`,
  `up`, `down`, `left`, `right`, `capslock`, `f1`–`f12`.
- **Punctuation:** `minus`, `equal`, `leftbrace`, `rightbrace`, `semicolon`,
  `apostrophe`, `grave`, `backslash`, `comma`, `dot`/`period`, `slash`.

## Configuration

Both programs read an optional [ZON](https://ziglang.org/documentation/master/#Zig-Object-Notation)
configuration file under the XDG config directory:

- `$XDG_CONFIG_HOME/telemouse/tms.zon` / `tmc.zon` when `XDG_CONFIG_HOME` is set,
- otherwise `~/.config/telemouse/{tms,tmc}.zon`
  (`%APPDATA%\telemouse\{tms,tmc}.zon` on Windows).

`-c/--config` overrides the path. A missing file is not an error — defaults are
used. Command-line options take precedence over the file. Examples:
[`config/tms.zon.example`](config/tms.zon.example),
[`config/tmc.zon.example`](config/tmc.zon.example).

Server (`tms.zon`):

```zig
.{
    .addr = "0.0.0.0",
    .port = 24800,
    .log_level = "info",                  // silent|error|warn|info|debug
    .log_file = "/var/log/telemouse.log", // omit to log to stdout
    .syslog = false,
    .screen_width = 1920,                 // absolute positioning (Linux)
    .screen_height = 1080,
    .device_name = "telemouse virtual input",
    .dry_run = false,
}
```

Client (`tmc.zon`):

```zig
.{
    .addr = "127.0.0.1",
    .port = 24800,
    .log_level = "info",
    .log_file = null,
    .syslog = false,
    .discover_timeout_ms = 600,           // how long a discovery scan waits
    .screen_width = 1920,                 // local screen, for edge detection
    .screen_height = 1080,
    .left = null,                         // "ip:port" of the neighbour on each
    .right = "192.168.1.20:24800",        // edge, or null (see Edge switching)
    .top = null,
    .bottom = null,
}
```

## Logging

Both programs are quiet by default: at the default `info` level the server only
announces what it is listening on (and dry-run mode). Use `--log-level debug`
for per-command activity, or `silent` for nothing. Destinations: stdout (the
default), `--log-file <path>` (append), or `--syslog` (Linux only; falls back to
stdout with a warning elsewhere).

## Command-line reference

```
tms [OPTIONS]
    -a, --addr <addr>        Address to bind (default 0.0.0.0)
    -p, --port <port>        Port to listen on (default 24800)
    -c, --config <file>      Configuration file (default: XDG config path)
    -L, --log-level <level>  silent|error|warn|info|debug (default info)
        --log-file <file>    Log to this file instead of stdout
        --syslog             Log to the system logger (Linux only)
        --dry-run            Do not emit real input, only log commands
    -h, --help               Show help
        --version            Show version

tmc [OPTIONS]
    -a, --addr <addr>        Server address (default 127.0.0.1)
    -p, --port <port>        Server port (default 24800)
    -e, --execute <command>  Send a single command then exit
    -c, --config <file>      Configuration file (default: XDG config path)
    -L, --log-level <level>  silent|error|warn|info|debug (default info)
        --log-file <file>    Log to this file instead of stdout
        --syslog             Log to the system logger (Linux only)
    -h, --help               Show help
        --version            Show version

    With no arguments, tmc discovers and lists servers on the LAN.
```

## Layout

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
  tms/
    config.zig     server configuration
    input.zig      backend abstraction (dry-run / native)
    uinput.zig     Linux backend
    winput.zig     Windows backend
  tmc/
    switcher.zig   edge-switching state machine
    session.zig    sender + edge-switch session (drives both capture backends)
    evdev.zig      Linux input capture (read + grab /dev/input)
    wincapture.zig Windows input capture (low-level hooks)
  tms.zig          server entry point (Io.Select event loop)
  tmc.zig          client entry point
```
