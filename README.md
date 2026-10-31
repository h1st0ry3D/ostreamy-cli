# Ostreamy CLI

Stream-ready Hyprland layout for Sunshine to Moonlight on a Steam Deck, built for
Omarchy. It makes streaming work while the host monitor is switched off, and hides
the virtual display again when nobody is streaming.

```
                   workspaces move here while streaming
                                │
                            ┌───▼────┐
              Moonlight ◄───┤ STREAM │  headless, 1920x1200@60, always exists
                            └───┬────┘
                                │ mirror (holds no workspaces of its own)
                            ┌───▼────┐
                            │ panel  │  free to be switched off or unplugged
                            └────────┘
```

## What it solves

| Problem | Cause | Ostreamy's answer |
|---|---|---|
| Stream goes black when the monitor is switched off | the panel's output disappears, Hyprland stops compositing, screencopy has no source | capture a headless output that never disappears |
| Stream freezes after a few seconds, controller still works | Sunshine resolved `output_name` before the output existed, fell back to the panel, then the resolution changed under the live encoder | the output stays enabled with a fixed mode; only the layout moves |
| Invisible 1920x1200 display steals mouse/keyboard and workspace shortcuts | two enabled outputs share coordinates; the virtual one holds focus | the output is parked at a negative x and never overlaps; `fix` restores focus |
| `off` does not restore the desktop | closed-client sockets or menu polling re-armed the layout | only a *new* client endpoint outside a 20 s post-session quiet window re-arms it |
| Desktop returns squashed at 60 Hz | panel stuck mirroring the 16:10 stream | `off` reloads a mirror-free rule and restores the panel's own mode |

## Requirements

- Hyprland 0.50 or newer with the Lua config (tested on Omarchy 4.0.6, Hyprland 0.56)
- Sunshine (`pacman -S sunshine`), enabled as a user unit
- `jq`, `ss` (iproute2), `systemd` user manager; `grim` + ImageMagick for the
  optional pixel check
- A Sunshine-capable GPU encoder: NVENC, VAAPI
- Optional: `loginctl enable-linger "$USER"` so the host is streamable before login

## Install

```bash
git clone <repo> ~/github/ostreamy-cli
cd ~/github/ostreamy-cli
./install.sh              # scripts, systemd unit, config, Hyprland snippet, sunshine.conf
./install.sh --help       # --no-hypr, --no-sunshine, --encoder nvenc|vaapi|software
```

`install.sh` is idempotent. It edits `~/.config/hypr/monitors.lua` and
`~/.config/sunshine/sunshine.conf` only inside `ostreamy` marker blocks, using `--`
comments in the Lua file and `#` in the Sunshine config, and it keeps a timestamped
backup first. The script prints firewall rules instead of applying them.

Then:

```bash
ostreamy-verify
ostreamy-verify --simulate-off     # disables the panel, screenshots STREAM, restores
```

Both must end with `verdict: PASS`.

## Usage

```bash
ostreamy status     # layout, modes, mirrors, workspace placement
ostreamy on         # force stream-ready
ostreamy off        # force native desktop
ostreamy ensure     # create/park STREAM (normally done by the watcher)
ostreamy fix        # pull workspaces and focus back to the panel
ostreamy mode 1920x1200@90   # change captured resolution and refresh, saved to config
ostreamy state      # JSON: mode, output, panel, streaming, width, height, fps
ostreamy edit       # open ~/.config/ostreamy/config.sh
```

A companion Omarchy shell plugin (`h1st0ry3d.ostreamy`) drives the same commands
from the bar. The CLI stays the only writer of the config and the Hyprland rule.

Resolution and frame rate come from the headless output's mode. `ostreamy mode`
writes the new value to `~/.config/ostreamy/config.sh`, updates the Hyprland rule,
and applies it when nothing is streaming. During a stream it only saves the value,
because changing the mode under a live encoder stalls the video; the next session
uses it.

Normally you never touch it: `ostreamy-watch.service` reacts to Moonlight connecting
(switch to stream-ready) and disconnecting (back to native), so the desktop is never
left on the virtual display.

## Client (Moonlight on Steam Deck)

| Setting | Value |
|---|---|
| Resolution | 1280x800 (panel native) |
| FPS | 90 on OLED, 60 on LCD |
| Codec | HEVC. Never AV1: no Deck has an AV1 hardware decoder |
| Bitrate | 40 to 50 Mbps on LAN, 25 to 30 on weak Wi-Fi |
| Hardware decoding | on |
| V-Sync and frame pacing | on |
| HDR | off unless the host outputs HDR (see `docs/DESIGN.md`) |

Pairing: Moonlight shows a PIN, enter it at `https://<host-ip>:47990`.

## Firewall (ufw)

```bash
sudo ufw allow from 192.168.0.0/16 to any port 47984 proto tcp comment 'sunshine https'
sudo ufw allow from 192.168.0.0/16 to any port 47989 proto tcp comment 'sunshine http'
sudo ufw allow from 192.168.0.0/16 to any port 48010 proto tcp comment 'sunshine rtsp'
sudo ufw allow from 192.168.0.0/16 to any port 47998:48002 proto udp comment 'sunshine stream'
```

## Layout

```
bin/ostreamy             switch, status and fix commands
bin/ostreamy-watch       activity watcher (systemd user service)
bin/ostreamy-verify      health checks and panel-off simulation
lib/ostreamy/common.sh   shared monitor, workspace and socket helpers
config/                  example config (installed to ~/.config/ostreamy/config.sh)
hypr/ostreamy.lua        Hyprland snippet template (inserted by install.sh)
systemd/                 user unit for the watcher
docs/DESIGN.md           why each decision exists, with the log evidence
docs/TROUBLESHOOTING.md  symptoms, causes and fixes
docs/CLIENT.md           Steam Deck and Moonlight specifics
tests/smoke.sh           end-to-end switch test against the running session
tests/lint.sh            syntax and hygiene checks, plus shellcheck when installed
Makefile                 make check runs lint, smoke and verify
```

Configuration lives in `~/.config/ostreamy/config.sh` (output name, mode, grace,
poll interval, ports). `MODE` is `WIDTHxHEIGHT@HZ`; prefer `ostreamy mode` over
editing it by hand, because the command also updates the Hyprland rule. If you do
edit it, run `ostreamy ensure` afterwards to sync the rule.

## Checks

```bash
make check        # lint + smoke + verify
tests/lint.sh     # bash -n everywhere, shellcheck if present, hygiene greps
```

`tests/smoke.sh` drives both switches against the live session: a short-lived
connection must arm the layout, a manual `off` must stick, and a held connection
must re-arm it.

## Uninstall

```bash
./uninstall.sh            # removes scripts, unit, and managed config blocks
./uninstall.sh --purge    # also deletes ~/.config/ostreamy
```

## Notes

- Steam Remote Play uses a different capture path (`-pipewire`, portal picker) and
  Ostreamy does not manage it. If you use it, it must also capture `STREAM` to survive
  the panel being switched off.
- The virtual display is always allocated. Display settings will list it; do not
  disable or remove it while Sunshine runs.
- HDR is not achievable on an SDR compositor/output; see `docs/DESIGN.md`.

## License

MIT
