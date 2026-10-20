# CLAUDE.md

macOS-style three-finger drag as a libinput Lua plugin. Four files matter:

- `50-three-finger-drag.lua`: the plugin
- `install.sh` / `uninstall.sh`: run via `curl ... | bash` from raw GitHub,
  or locally from a clone
- `tests/run.lua`: offline test harness, run with `luajit tests/run.lua`

## How the plugin works

It rewrites evdev frames below libinput. It doesn't use libinput's own
3fg-drag config option, because KWin doesn't expose it and nothing else
can set it for the compositor.

- Pre-pass simulates each frame to learn the post-frame contact set.
- With three contacts down for at least `ARM_MS`, it waits for the topmost
  slot (smallest y; the thumb sits lowest and a finger in libinput's bottom
  software-button area neither moves the pointer nor left-clicks) to move
  `THRESHOLD_MM`, then hides the other slots (sending `TRACKING_ID -1` for
  the ones libinput already knew about) and injects `BTN_LEFT 1`.
- Hidden slots stay hidden until the kernel lifts them. New touches during a
  drag are hidden. When the primary lifts, a touch that landed this frame
  becomes the new primary; failing that, a hidden finger still on the pad is
  revealed with a synthetic tracking id plus its current x/y, so the drag
  survives partial lifts without the pointer jumping.
- `BTN_TOUCH` / `BTN_TOOL_*` from the kernel are dropped and regenerated
  from the visible contact count, so libinput's finger count matches the
  slots it can see.
- After all fingers lift, `BTN_LEFT 0` is sent via the plugin timer
  (`timer-expired` + `device:append_frame`) after `RELEASE_MS`, or after
  `REPOSITION_MS` when the primary's speed over the last `SPEED_WINDOW_MS`
  was at least `REPOSITION_MM_S` or it lifted within `EDGE_MM` of the pad
  edge. Speed is tracked as per-frame motion increments so it survives a
  primary promotion and reads as zero after the finger has been still.

## Lua plugin API constraints

- Plugin API version 1; frames are arrays of `{ usage = evdev.X, value = n }`
  without `SYN_REPORT`. Returning `nil` keeps the frame, returning `{}` drops it.
- Sandboxed: only `assert error ipairs next pairs tonumber pcall select print
  tostring type xpcall table string math`. No `io`, `os` or `require`.
- One timer per plugin (`libinput:timer_set_relative(us)` / `timer_cancel()`).
- Method calls must use `:` syntax.
- Reference: https://wayland.freedesktop.org/libinput/doc/latest/lua-plugins.html

## Testing

`tests/run.lua` is an offline harness: it stubs the `libinput` and `evdev`
globals, loads the plugin with a fake touchpad (100 x 60 mm, 50 units/mm,
slot 0 is the topmost finger) and feeds frames to the `evdev-frame` handler
with microsecond timestamps, checking the emitted frames and timer calls.
Run it with `luajit tests/run.lua` from the repo root; add a `test(...)`
block for every behavior change. CI (`.github/workflows/ci.yml`) runs it
plus `shellcheck -S style` on the scripts and a non-ASCII check on all text
files. Feel must still be checked on hardware:

```sh
./install.sh
sudo libinput debug-events --verbose --enable-plugins 2>&1 \
  | grep -iE 'plugin|3fg-drag|POINTER_BUTTON|GESTURE_SWIPE_BEGIN'
```

- `debug-events` in libinput 1.31.3 ignores `--set-plugin-path` (bug in
  `tools/shared.c` `add_path()`), so plugins must be installed under
  `/etc/libinput/plugins` to test.
- KWin only loads plugins at session start, so the desktop picks up changes
  after a re-login. `debug-events` picks them up immediately.
- Plugin errors appear as `plugin bug: ...` in `--verbose` output, and libinput
  unloads the plugin.

## Conventions

- Keep the scripts POSIX-friendly bash with `set -euo pipefail` and the body
  inside `main()` so a truncated `curl | bash` download never runs partially.
  Escalate with the `as_root` helper, never an unquoted `$sudo` variable.
- ASCII only in every file: no em dashes or typographic quotes. CI enforces it.
- Raw URLs point at `alex-spataru/three-finger-drag` on `main`
  (`THREE_FINGER_DRAG_REF` overrides the ref in `install.sh`).
- Tested on Fedora Asahi Remix 44, libinput 1.31.3, KWin 6.7.5, Apple MTP
  touchpad.
