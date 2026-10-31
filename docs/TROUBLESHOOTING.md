# Troubleshooting

Start with `ostreamy status` and `ostreamy-verify`. Both read the same state the
watcher acts on.

## Stream goes black when the monitor is switched off

`STREAM` is missing, so Sunshine fell back to the panel and the panel vanished.

```bash
ostreamy ensure
ostreamy status          # STREAM must exist, mode fixed
systemctl --user restart sunshine
```

## Video freezes after a few seconds, controller still works

The capture target changed under the running encoder. Look for a fallback and a
second resolution in `~/.config/sunshine/sunshine.log`:

```bash
grep -aE 'Resolution:|Name:|Creating encoder|CLIENT' ~/.config/sunshine/sunshine.log | tail -20
```

Bad shape: `Resolution: 2560x1440` at session start, then `1920x1200` later and a
second `Creating encoder`. Fix by keeping `STREAM` allocated:

```bash
ostreamy ensure
systemctl --user restart sunshine
```

## No pointer input, workspace shortcuts dead, only wallpaper visible

An invisible output holds focus or overlaps the primary.

```bash
ostreamy status          # look for STREAM at 0,0 or focused
ostreamy fix             # move workspaces + focus to the panel
```

If `STREAM` sits at the same coordinates as the panel, re-run `./install.sh` — the
shipped snippet parks it at a negative x.

## `off` does not restore the desktop mode

Leftover `TIME-WAIT` sockets used to re-arm the layout. Check:

```bash
ostreamy status
journalctl --user -u ostreamy-watch -n 20 --no-cache 2>/dev/null || journalctl --user -u ostreamy-watch -n 20
```

You want `layout switched off externally -> standby` right after a manual `off`.
If instead you see repeated `client connected -> stream-ready layout`, the installed
watcher predates the endpoint-novelty detection (leftover TIME-WAIT sockets were
being treated as a new client).

## Monitor layout warning: "overlaps with other monitor(s)"

Two enabled outputs share coordinates. `STREAM` must be parked off to the side:

```bash
hyprctl monitors all -j | jq -r '.[] | "\(.name) \(.x),\(.y) \(.width)x\(.height)"'
ostreamy ensure
```

## Desktop returns squashed / stuck at stream resolution

The panel is still mirroring the 16:10 stream.

```bash
ostreamy off
hyprctl monitors all -j | jq -r '.[] | "\(.name) \(.width)x\(.height) mirrorOf=\(.mirrorOf)"'
```

`mirrorOf` must be `none` and the panel must show its native mode.

If the panel keeps the stream's resolution (e.g. 1920x1200 or 1280x800) after a
stream, the restore picked the mode from the *mirroring* state, where the panel
reports the stream's size. Current versions pick the panel's largest available
resolution and highest refresh inside it, independent of the mirror:

```bash
hyprctl monitors all -j | jq -r '.[] | "\(.name) \(.width)x\(.height)@\(.refreshRate)"'
ostreamy off
```

## Client cannot connect

```bash
ss -tulpn | grep -E ':(47984|47989|47990|48010)'
sudo ufw status | grep -E '4798|4799|4801'
```

Add the LAN-scoped rules from `README.md`.

## Picture is soft / blocky

Client-side bitrate. A session at 9–10 Mbps looks soft at 1200p; use 40–50 Mbps on
LAN. Check what was negotiated:

```bash
grep -a 'Streaming bitrate' ~/.config/sunshine/sunshine.log | tail -3
```

## Stutter on the Deck

Force HEVC. If `av1_mode` is not `1`, Sunshine may advertise AV1, which the Deck
cannot hardware-decode.

## `hyprctl` fails with "Couldn't connect to .../.socket.sock"

Stale `HYPRLAND_INSTANCE_SIGNATURE` after a compositor restart. ostreamy resolves it
automatically; if you hit this in your own shell:

```bash
export HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl instances -j | jq -r 'sort_by(.time)|last|.instance')
```

## Sunshine aborts (SIGABRT) when the layout switches

Something removed the captured output. Do not call `hyprctl output remove` while
Sunshine runs; `ostreamy` never does. Check:

```bash
coredumpctl list | tail -5
```

## Watcher does nothing

```bash
systemctl --user status ostreamy-watch
journalctl --user -u ostreamy-watch -n 30
```

It should log `watching Moonlight activity (poll 0.25s ...)` at start. No
`client connected` line while you stream means the port list or socket detection is
wrong — report the `ss -Htan | grep -E ':(47984|47989|48010)'` output.
