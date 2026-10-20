# three-finger-drag

[![CI](https://github.com/alex-spataru/three-finger-drag/actions/workflows/ci.yml/badge.svg)](https://github.com/alex-spataru/three-finger-drag/actions/workflows/ci.yml)

macOS-style three-finger drag for Linux touchpads, implemented as a
[libinput Lua plugin](https://wayland.freedesktop.org/libinput/doc/latest/lua-plugins.html).

Put three fingers on the touchpad and move them to drag windows, select text or
move files, the same way the macOS accessibility option works. Lift your fingers
to drop.

## Why a plugin?

libinput 1.28+ ships three-finger drag natively, but it's a configuration
option that only the compositor can enable, and KWin (Plasma) doesn't expose
it. Lua plugins run inside libinput below the compositor, so this one works
without compositor support: once three fingers move, it hides two of the
contacts and holds the left button, so the compositor sees an ordinary
one-finger click-and-drag.

## Requirements

- libinput **1.30 or newer**, built with Lua support (Fedora 43+, Arch and other
  current distros)
- A compositor that loads libinput plugins. Tested on **KWin 6.7.5** (Plasma,
  Wayland) on Fedora Asahi Remix 44 with an Apple Silicon MacBook Pro
  touchpad.

To check whether KWin was built against a libinput with plugin support:

```sh
nm -D /usr/lib64/libkwin.so.6 | grep libinput_plugin_system_load_plugins
```

On Debian-based distributions the library lives under
`/usr/lib/<arch>-linux-gnu/` instead of `/usr/lib64/`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/alex-spataru/three-finger-drag/main/install.sh | bash
```

Then **log out and back in**. The installer asks for your `sudo` password and
copies the plugin to `/etc/libinput/plugins/50-three-finger-drag.lua`. Running it
again updates an existing install. Set `THREE_FINGER_DRAG_REF` to install from
a branch or tag other than `main`.

From a clone:

```sh
git clone https://github.com/alex-spataru/three-finger-drag.git
cd three-finger-drag
./install.sh
```

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/alex-spataru/three-finger-drag/main/uninstall.sh | bash
```

Then log out and back in. You can also remove it by hand with
`sudo rm /etc/libinput/plugins/50-three-finger-drag.lua`.

## Behavior

| Gesture | Result |
|---|---|
| Three fingers down and moving | Left-button drag, driven by the finger highest on the pad |
| Lift some fingers | Drag continues with whichever finger is still down |
| Lift all fingers | Drag ends after 50 ms. If the fingers were still moving, or lifted at the pad edge, the window is 250 ms instead so you can land again and keep dragging |
| Place fingers back down in that window | Drag continues |
| Physical click during a drag | Takes over the drag; releasing the click ends it |
| Three-finger tap without movement | Middle click (unchanged) |
| Four- and five-finger swipes | Unchanged |
| Three-finger swipes | **Replaced by drag**: compositor shortcuts bound to three-finger swipes no longer fire. Rebind them to four fingers, which is what macOS does when the option is on |

## Tuning

Constants at the top of `50-three-finger-drag.lua` control the feel:

| Constant | Default | Meaning |
|---|---|---|
| `THRESHOLD_MM` | `1.5` | How far the fingers must move before a drag starts. Lower values feel more eager, higher values make three-finger taps more forgiving. |
| `ARM_MS` | `30` | Three fingers must be down this long before a drag can start, so a fast four-finger swipe whose fourth finger lands late is not mistaken for a drag. |
| `RELEASE_MS` | `50` | How long the button stays held after a still lift. |
| `REPOSITION_MS` | `250` | How long it stays held after a lift that looks like a mid-stroke reposition. Set it equal to `RELEASE_MS` to disable the adaptive behavior. |
| `REPOSITION_MM_S` | `25` | Finger speed at lift above which the lift counts as a reposition. |
| `EDGE_MM` | `5` | Lifts closer than this to the pad edge count as repositions. |
| `SPEED_WINDOW_MS` | `60` | Window over which the lift speed is measured. |

Edit `/etc/libinput/plugins/50-three-finger-drag.lua` and log out and back in.
Running the installer again overwrites your edits.

## Troubleshooting

Watch libinput's view of the touchpad with the plugin loaded:

```sh
sudo libinput debug-events --verbose --enable-plugins 2>&1 \
  | grep -iE 'plugin|3fg-drag|POINTER_BUTTON|GESTURE_SWIPE_BEGIN'
```

You should see `Loading plugin from /etc/libinput/plugins/50-three-finger-drag.lua`
and `3fg-drag: enabled on <your touchpad>`. A three-finger drag then shows
`POINTER_BUTTON BTN_LEFT pressed` / `released` instead of `GESTURE_SWIPE_BEGIN 3`.

`debug-events` only reads plugins from the system plugin directories. In
libinput 1.31.3, `--set-plugin-path` ignores its argument.

If the plugin loads in `debug-events` but does nothing on the desktop, your
compositor probably doesn't load libinput plugins.

Plugin errors show up as `plugin bug: ...` in the `--verbose` output, after
which libinput unloads the plugin for the rest of the session.

## Development

The plugin can be exercised offline with LuaJIT. `tests/run.lua` stubs the
libinput plugin API, feeds synthetic evdev frames through the plugin and
checks the frames it emits:

```sh
luajit tests/run.lua
```

The same tests, plus `shellcheck` on the scripts, run in CI on every push.
Feel on real hardware still has to be checked with the `debug-events` command
above or after a re-login.

## License

MIT, see [LICENSE](LICENSE).
