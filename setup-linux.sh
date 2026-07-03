#!/usr/bin/env sh
# One-shot permission setup for telemouse on Linux.
#
# On an X11 session you need NONE of this: the client captures via XInput2 and
# the server injects via XTEST, both without permissions. This script is only for
# a Wayland/headless machine (or when forcing --capture evdev / --backend kernel),
# where the kernel devices are used instead:
#
#   ./setup-linux.sh --client            # read access to /dev/input (evdev capture)
#   ./setup-linux.sh --server            # write access to /dev/uinput (uinput injection)
#   ./setup-linux.sh --client --server   # a box that does both
#
# What it does, and nothing more:
#   * adds you to the 'input' group (additive; keeps every group you already have);
#   * --server also installs a udev rule so /dev/uinput carries that group on
#     every boot (packaging/99-telemouse-uinput.rules).
# Re-running is safe. Undo with:  sudo gpasswd -d "$USER" input
#   (and, for the server, delete /etc/udev/rules.d/99-telemouse-uinput.rules).
#
# Run it as your normal user — it calls sudo itself only for the steps that need
# root, and grants access to YOU, not root.
set -eu

CLIENT=0
SERVER=0
for arg in "$@"; do
    case "$arg" in
        --client) CLIENT=1 ;;
        --server) SERVER=1 ;;
        -h | --help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown option: $arg (use --client and/or --server)" >&2; exit 2 ;;
    esac
done

if [ "$CLIENT" -eq 0 ] && [ "$SERVER" -eq 0 ]; then
    echo "nothing to do: pass --client and/or --server (see --help)" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The human user to grant access to — never root.
if [ -n "${SUDO_USER:-}" ]; then
    TARGET_USER="$SUDO_USER"
elif [ "$(id -u)" -ne 0 ]; then
    TARGET_USER="$(id -un)"
else
    echo "run this as your normal user (it invokes sudo itself), not as root" >&2
    exit 1
fi

# Prefix for privileged commands: nothing if already root, else sudo.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

echo "granting '$TARGET_USER' access to input devices"
echo

# Both the evdev capture (client) and the uinput injection (server) live behind
# the 'input' group, so this one step covers either role.
echo "-> adding '$TARGET_USER' to the 'input' group"
$SUDO usermod -aG input "$TARGET_USER"

if [ "$SERVER" -eq 1 ]; then
    RULE=/etc/udev/rules.d/99-telemouse-uinput.rules
    echo "-> installing udev rule: $RULE"
    $SUDO install -Dm644 "$SCRIPT_DIR/packaging/99-telemouse-uinput.rules" "$RULE"
    # Make sure the node exists now, and apply the new rule to it immediately so
    # you don't have to reboot to test.
    $SUDO modprobe uinput 2>/dev/null || true
    echo "-> reloading udev"
    $SUDO udevadm control --reload-rules
    $SUDO udevadm trigger /dev/uinput 2>/dev/null || $SUDO udevadm trigger || true
    if [ -e /dev/uinput ]; then
        echo "-> /dev/uinput is now: $(ls -l /dev/uinput)"
    fi
fi

echo
echo "Done."
echo "The group change takes effect on your NEXT login (log out and back in)."
echo "To use it in the current shell without logging out:  newgrp input"
if [ "$SERVER" -eq 1 ]; then
    echo
    echo "For edge switching, run 'tms' as yourself inside your graphical session"
    echo "so it can read and place the cursor via X. Do NOT run it with sudo or via"
    echo "the headless 'telemouse-server' systemd unit for that use case — a root or"
    echo "system-user process has no access to your X display, and the edge-detection"
    echo "and cursor placement would silently stop working."
fi
