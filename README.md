# three-finger-drag

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

To check whether your compositor loads plugins:

```sh
nm -D /usr/lib64/libkwin.so.6 | grep libinput_plugin_system_load_plugins
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/alex-spataru/three-finger-drag/main/install.sh | bash
```

Then **log out and back in**. The installer asks for your `sudo` password and
copies the plugin to `/etc/libinput/plugins/50-three-finger-drag.lua`. Running it
again updates an existing install.

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
| Three fingers down and moving | Left-button drag |
| Lift all fingers | Drag ends after 50 ms; fingers placed back down within that window continue the drag |
| Physical click during a drag | Takes over the drag; releasing the click ends it |
| Three-finger tap without movement | Middle click (unchanged) |
| Four- and five-finger swipes | Unchanged |
| Three-finger swipes | **Replaced by drag**: compositor shortcuts bound to three-finger swipes no longer fire |

## Tuning

Two constants at the top of `50-three-finger-drag.lua` control the feel:

| Constant | Default | Meaning |
|---|---|---|
| `THRESHOLD_MM` | `1.5` | How far the fingers must move before a drag starts. Lower values feel more eager, higher values make three-finger taps more forgiving. |
| `RELEASE_MS` | `50` | How long the button stays held after lifting. Raise it (e.g. `400`) to be able to lift and reposition your fingers mid-drag. |

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

## License

MIT, see [LICENSE](LICENSE).
