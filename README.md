# Global Workspaces

An [Omarchy](https://omarchy.org/) plugin that makes every monitor switch
together. Press SUPER+3 and all your screens move to desktop 3, the way virtual
desktops work on macOS, Windows and KDE.

Stock Omarchy gives each monitor its own workspaces. With more than one screen,
SUPER+2 often just moves focus to whichever monitor happens to own workspace 2.
Global Workspaces turns that into a set of desktops that span all your screens.

## How it works

A desktop is one workspace on each monitor. The workspace id spells out both:

```
id = desktop × 10 + monitor
```

| | Left (1) | Center (2) | Right (3) |
|---|---|---|---|
| Desktop 0 | 1 | 2 | 3 |
| Desktop 1 | 11 | 12 | 13 |
| Desktop 2 | 21 | 22 | 23 |
| … | | | |
| Desktop 9 | 91 | 92 | 93 |

- The tens digit is always the desktop and the ones digit is always the monitor,
  so workspace 23 is desktop 2 on the third screen.
- Monitors are numbered left to right the first time they are seen, up to nine.
  The numbers are remembered by output name, so a screen you unplug and plug
  back in gets its windows back.
- Hyprland starts on desktop 1. Desktop 0 sits on the 0 key, like a tenth
  desktop.
- Anything that switches one monitor's workspace (the bar, a notification
  focusing a window, `hyprctl`) brings the other monitors along to the same
  desktop.

## Keys

| Keys | Action |
|---|---|
| SUPER + 1…9, 0 | Switch every monitor to that desktop |
| SUPER + SHIFT + 1…9, 0 | Move the window to that desktop (same monitor) and follow it |
| SUPER + SHIFT + ALT + 1…9, 0 | Move the window to that desktop without switching |
| SUPER + TAB / SUPER + SHIFT + TAB | Next / previous desktop that has windows |
| SUPER + CTRL + TAB | Back to the desktop you were on before |
| SUPER + scroll | Next / previous desktop |

SUPER + SHIFT + arrows still moves windows between monitors. SUPER + SHIFT +
ALT + arrows (move a whole workspace to another monitor) is removed, because
it would break the numbering.

The plugin's bindings load before your `~/.config/hypr/bindings.lua`, so you
can rebind anything there. Call the plugin from your own bindings with
`GlobalWorkspaces.switch(n)`, `.move_window(n, follow)`, `.next()`,
`.prev()` and `.former()`.

## Install

Requires Omarchy 4 (Hyprland 0.56+ with Lua config).

```bash
omarchy plugin add https://github.com/OWNER/omarchy-global-workspaces.git --yes
~/.config/omarchy/plugins/gg.arkship.global-workspaces/setup install
```

`setup install` asks before changing anything, then:

1. Backs up `~/.config/hypr/hyprland.lua` and adds a small marked loader block
   after Omarchy's defaults.
2. Replaces the stock workspaces widget in your bar with the desktop widget.
3. Reloads Hyprland and gives any window on a workspace the new numbering
   cannot reach a desktop: stock workspace N becomes desktop N on the same
   screen, and workspace 10 becomes desktop 0.

On the first run your existing workspaces move to the monitors their numbers
belong to, so windows may change screens once.

## Uninstall

```bash
~/.config/omarchy/plugins/gg.arkship.global-workspaces/setup uninstall
omarchy plugin remove gg.arkship.global-workspaces
```

`setup uninstall` moves every window back to stock workspaces (desktop N
becomes workspace N, desktop 0 becomes workspace 10), removes the loader block
and puts the stock widget back.

## Other commands

```bash
setup status    # monitor numbers and the current desktop
setup renumber  # number monitors left to right again, e.g. after rearranging them
```

If a monitor is disconnected, its windows wait on their workspaces for it to
come back. To pull them onto the screen you are using instead, run:

```bash
hyprctl eval 'GlobalWorkspaces.gather()'
```

Window rules can target a desktop and screen directly. For example,
`o.window("Slack", { workspace = "13" })` puts Slack on desktop 1, right
screen (on a three-monitor desk).

## Development

```bash
lua test/run.lua     # switching logic against a fake Hyprland
bash test/setup.sh   # setup install/uninstall against a throwaway HOME
omarchy plugin validate .
```

## Credits

The idea of giving each monitor its own band of workspace ids and switching
them together comes from [@amacieli](https://github.com/amacieli)'s work in
[omacom/omarchy#12978](https://github.com/omacom/omarchy/pull/12978) and the
review it got. That work also mapped out the hard parts: keeping monitor
numbers stable across hotplug, keeping workspaces alive so idle screens can
switch, and switching the focused screen last so focus stays put. This plugin
flips the numbering so the tens digit is the desktop, and runs entirely inside
Hyprland's Lua config.

The bar widget is adapted from Omarchy's own workspaces widget.

## License

[MIT](LICENSE)
