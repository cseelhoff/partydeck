#!/usr/bin/env python3
"""Per-pad gamepad -> keyboard/mouse bridge for PartyDeck split-screen.

PartyDeck isolates ONE input device per instance by exclusively grabbing it in
its gamescope fork (--libinput-hold-dev). Keyboard/mouse-only games (e.g.
Neverwinter Nights: EE) read no gamepad, and every shared virtual-input tool
(antimicrox, input-remapper, Steam Input desktop layouts) emits a SINGLE global
virtual keyboard/mouse that cannot be routed to a specific instance.

This bridge runs ONE process per physical pad and creates ONE dedicated virtual
device per pad, so N pads yield N distinct nodes that PartyDeck can assign to N
instances. The virtual device carries mouse buttons + relative motion + the
mapped keyboard keys, but deliberately NO gamepad buttons, so PartyDeck
classifies it as a mouse (its device scan matches BTN_SOUTH->Gamepad first, then
BTN_LEFT->Mouse) rather than as another gamepad.

Right stick drives the cursor with a velocity loop (a held stick must produce
continuous motion, which evdev's discrete ABS events don't give on their own).
The left stick and D-pad map to keys; everything else is a direct
event->event translation.
"""

import argparse
import glob
import os
import sys
import threading
import time

from evdev import InputDevice, UInput, ecodes as e


# --- Mapping (edit here) --------------------------------------------------
# Source gamepad button (evdev BTN_*) -> action. Actions:
#   ("click", code)  press/release a mouse button (BTN_LEFT/RIGHT/MIDDLE)
#   ("key",   code)  press/release a keyboard key (KEY_*)
# Tuned for Neverwinter Nights: EE (point-and-click). Unmapped buttons ignored.
BUTTON_MAP = {
    e.BTN_SOUTH:  ("key", e.KEY_I),    # A  -> left click (move/select/attack)
    e.BTN_EAST:   ("key", e.KEY_C),   # B  -> right click (context/examine)
    e.BTN_WEST:   ("key", e.KEY_SPACE),   # X  -> pause (critical in combat)
    e.BTN_NORTH:  ("key", e.KEY_M),       # Y  -> map
    e.BTN_TL:     ("key", e.KEY_UP),      # LB -> up arrow
    e.BTN_TR:     ("key", e.KEY_DOWN),    # RB -> down arrow
    e.BTN_SELECT: ("key", e.KEY_J),       # Back  -> journal
    e.BTN_START:  ("key", e.KEY_ESC),     # Start -> menu / cancel
    e.BTN_THUMBL: ("key", e.KEY_LEFTCTRL),
    e.BTN_THUMBR: ("key", e.KEY_LEFTSHIFT),
    # e.BTN_MODE:   ("key", e.KEY_C),       # Guide -> character sheet
}

# D-pad (ABS_HAT0X/Y) -> keys, on press of each direction.
DPAD_MAP = {
    ("HAT0Y", -1): ("key", e.KEY_PAGEUP),    # up    -> page up
    ("HAT0Y", 1):  ("key", e.KEY_PAGEDOWN),  # down  -> page down
    ("HAT0X", -1): ("key", e.KEY_LEFT),      # left  -> left arrow
    ("HAT0X", 1):  ("key", e.KEY_RIGHT),     # right -> right arrow
}

# Analog triggers (0..1 after normalize) -> action, engaged past THRESHOLD.
TRIGGER_MAP = {
    e.ABS_Z:  ("click", e.BTN_RIGHT),   # LT -> shift (add-to-quickbar / run)
    e.ABS_RZ: ("click", e.BTN_LEFT),        # RT -> alt confirm/attack
}
TRIGGER_THRESHOLD = 0.5

# Left stick -> WASD, pressed past the deadzone on each axis. (axis, sign) -> key.
STICK_MAP = {
    ("X", -1): ("key", e.KEY_A),   # left  -> A
    ("X", 1):  ("key", e.KEY_D),   # right -> D
    ("Y", -1): ("key", e.KEY_W),   # up    -> W
    ("Y", 1):  ("key", e.KEY_S),   # down  -> S
}
STICK_DEADZONE = 0.5

# Right stick -> mouse cursor via a velocity loop (held stick = continuous motion).
MOUSE_TICK_HZ = 125.0
MOUSE_MAX_SPEED = 14.0      # px per tick at full deflection
MOUSE_DEADZONE = 0.15
MOUSE_EXPONENT = 1.6        # >1 = finer control near center
# --------------------------------------------------------------------------


def norm(value, absinfo):
    """Normalize a raw ABS value to [-1, 1] using the axis's own range."""
    center = (absinfo.max + absinfo.min) / 2.0
    half = (absinfo.max - absinfo.min) / 2.0
    if half <= 0:
        return 0.0
    n = (value - center) / half
    if n < -1.0:
        return -1.0
    if n > 1.0:
        return 1.0
    return n


def curve(n, deadzone):
    """Deadzone + expo response. Returns a signed [-1,1] magnitude."""
    mag = abs(n)
    if mag <= deadzone:
        return 0.0
    scaled = (mag - deadzone) / (1.0 - deadzone)
    shaped = scaled ** MOUSE_EXPONENT
    return shaped if n >= 0 else -shaped


def build_uinput(name):
    """A virtual mouse+keyboard: mouse buttons + rel motion + every mapped key.
    No gamepad buttons, so PartyDeck classifies it as a mouse, not a pad."""
    keys = {e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE}
    for action, code in list(BUTTON_MAP.values()) + list(DPAD_MAP.values()) + list(TRIGGER_MAP.values()) + list(STICK_MAP.values()):
        keys.add(code)
    cap = {
        e.EV_KEY: sorted(keys),
        e.EV_REL: [e.REL_X, e.REL_Y],
    }
    return UInput(cap, name=name)


class Bridge:
    def __init__(self, path, name, sensitivity):
        self.dev = InputDevice(path)
        self.ui = build_uinput(name)
        self.sensitivity = sensitivity
        self.absinfo = {code: info for code, info in self.dev.capabilities().get(e.EV_ABS, [])}
        # Stick state: rx/ry drive the mouse cursor, left stick maps to WASD keys.
        self.rx = 0.0
        self.ry = 0.0
        self.trigger_state = {code: False for code in TRIGGER_MAP}
        self.hat = {"HAT0X": 0, "HAT0Y": 0}
        self.stick = {"X": 0, "Y": 0}
        self.stop = threading.Event()

    def press(self, code, down):
        self.ui.write(e.EV_KEY, code, 1 if down else 0)
        self.ui.syn()

    def do_action(self, action, down):
        kind, code = action
        # click and key are both EV_KEY at the uinput layer.
        self.press(code, down)

    def handle_key(self, code, value):
        # value: 1 down, 0 up, 2 autorepeat (ignore repeats).
        if value == 2:
            return
        action = BUTTON_MAP.get(code)
        if action is None:
            return
        self.do_action(action, value == 1)

    def handle_abs(self, code, value):
        info = self.absinfo.get(code)
        if info is None:
            return
        if code == e.ABS_X:
            self._handle_stick("X", norm(value, info))
        elif code == e.ABS_Y:
            self._handle_stick("Y", norm(value, info))
        elif code == e.ABS_RX:
            self.rx = norm(value, info)
        elif code == e.ABS_RY:
            self.ry = norm(value, info)
        elif code == e.ABS_HAT0X:
            self._handle_hat("HAT0X", value)
        elif code == e.ABS_HAT0Y:
            self._handle_hat("HAT0Y", value)
        elif code in TRIGGER_MAP:
            # Triggers rest at min and rise to max, so a plain 0..1 scale (not
            # the centered norm() used for sticks) gives the pull fraction.
            span = max(1, info.max - info.min)
            engaged = (value - info.min) / span >= TRIGGER_THRESHOLD
            if engaged != self.trigger_state[code]:
                self.trigger_state[code] = engaged
                self.do_action(TRIGGER_MAP[code], engaged)

    def _handle_hat(self, axis, value):
        prev = self.hat[axis]
        if prev == value:
            return
        self.hat[axis] = value
        # Release the previously-held direction, press the new one.
        if prev != 0:
            act = DPAD_MAP.get((axis, prev))
            if act:
                self.do_action(act, False)
        if value != 0:
            act = DPAD_MAP.get((axis, value))
            if act:
                self.do_action(act, True)

    def _handle_stick(self, axis, n):
        # Quantize the axis to -1/0/1 past the deadzone, then edge-trigger keys
        # so a held direction stays pressed until the stick crosses back.
        sign = -1 if n <= -STICK_DEADZONE else 1 if n >= STICK_DEADZONE else 0
        prev = self.stick[axis]
        if prev == sign:
            return
        self.stick[axis] = sign
        if prev != 0:
            act = STICK_MAP.get((axis, prev))
            if act:
                self.do_action(act, False)
        if sign != 0:
            act = STICK_MAP.get((axis, sign))
            if act:
                self.do_action(act, True)

    def motion_loop(self):
        period = 1.0 / MOUSE_TICK_HZ
        while not self.stop.is_set():
            dx = curve(self.rx, MOUSE_DEADZONE) * self.sensitivity
            dy = curve(self.ry, MOUSE_DEADZONE) * self.sensitivity
            moved = False
            if dx != 0.0:
                self.ui.write(e.EV_REL, e.REL_X, int(round(dx)))
                moved = True
            if dy != 0.0:
                self.ui.write(e.EV_REL, e.REL_Y, int(round(dy)))
                moved = True
            if moved:
                self.ui.syn()
            time.sleep(period)

    def run(self, grab):
        if grab:
            self.dev.grab()
        motion = threading.Thread(target=self.motion_loop, daemon=True)
        motion.start()
        try:
            for event in self.dev.read_loop():
                if event.type == e.EV_KEY:
                    self.handle_key(event.code, event.value)
                elif event.type == e.EV_ABS:
                    self.handle_abs(event.code, event.value)
        except OSError:
            pass  # device unplugged
        finally:
            self.stop.set()
            motion.join(timeout=1.0)
            if grab:
                try:
                    self.dev.ungrab()
                except OSError:
                    pass
            self.ui.close()


def list_pads():
    for link in sorted(glob.glob("/dev/input/by-id/*-event-joystick")):
        target = os.path.realpath(link)
        try:
            name = InputDevice(target).name
        except OSError:
            name = "?"
        print(f"{target}\t{name}\t({os.path.basename(link)})")


def main():
    ap = argparse.ArgumentParser(description="Per-pad gamepad->kbd/mouse bridge for PartyDeck.")
    ap.add_argument("--device", help="evdev path, e.g. /dev/input/event6")
    ap.add_argument("--name", default=None, help="virtual device name (default: partydeck-kbm-<basename>)")
    ap.add_argument("--sensitivity", type=float, default=MOUSE_MAX_SPEED, help="max px/tick at full stick")
    ap.add_argument("--no-grab", action="store_true", help="do not exclusively grab the pad (debug)")
    ap.add_argument("--list", action="store_true", help="list connected gamepads and exit")
    args = ap.parse_args()

    if args.list:
        list_pads()
        return 0
    if not args.device:
        ap.error("--device is required (or use --list)")
    if not os.path.exists(args.device):
        print(f"[bridge] no such device: {args.device}", file=sys.stderr)
        return 1

    name = args.name or f"partydeck-kbm-{os.path.basename(args.device)}"
    bridge = Bridge(args.device, name, args.sensitivity)
    print(f"[bridge] {args.device} ({bridge.dev.name}) -> virtual '{name}'", flush=True)
    bridge.run(grab=not args.no_grab)
    return 0


if __name__ == "__main__":
    sys.exit(main())
