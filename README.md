# ostreamy-cli

Stream-ready Hyprland layout for **Sunshine → Moonlight on a Steam Deck**, built for
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
                            │ panel  │  free to be switched off / unplugged
                            └────────┘
```

## What it solves

| Problem | Cause | ostreamy's answer |
|---|---|---|
| Stream goes black when the monitor is switched off | the panel's output disappears, Hyprland stops compositing, screencopy has no source | capture a headless output that never disappears |
| Stream freezes after a few seconds, controller still works | Sunshine resolved `output_name` before the output existed, fell back to the panel, then the resolution changed under the live encoder | the output stays enabled with a fixed mode; only the layout moves |
| Invisible 1920x1200 display steals mouse/keyboard and workspace shortcuts | two enabled outputs share coordinates; the virtual one holds focus | the output is parked at a negative x and never overlaps; `fix` restores focus |
| `off` does not restore the desktop | TIME-WAIT sockets from the closed client re-armed the layout | only a *new* client endpoint re-arms it |
| Desktop returns squashed at 60 Hz | panel stuck mirroring the 16:10 stream | `off` reloads a mirror-free rule and restores the panel's own mode |

## Requirements

- Hyprland ≥ 0.50 with the Lua config (tested on Omarchy 4.0.6 / Hyprland 0.56)
- Sunshine (`pacman -S sunshine`), enabled as a user unit
- `jq`, `ss` (iproute2), `systemd` user manager; `grim` + ImageMagick for the
  optional pixel check
- A Sunhine-capable GPU encoder: NVENC, VAAPI
- Optional: `loginctl enable-linger "$USER"` so the host is streamable before login

## Install

```bash
git clone <repo> ~/github/ostreamy-cli
cd ~/github/ostreamy-cli
./install.sh              # scripts, systemd unit, config, Hyprland snippet, sunshine.conf
./install.sh --help       # --no-hypr, --no-sunshine, --encoder nvenc|vaapi|software
```

`install.sh` is idempotent. It edits `~/.config/hypr/monitors.lua` and
`~/.config/sunshine/sunshine.conf` only inside `# >>> ostreamy >>>` markers, and keeps
a timestamped backup first. Firewall rules are printed, never applied silently.

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
ostreamy fix        # pull workspaces/focus back to the panel
```

Normally you never touch it: `ostreamy-watch.service` reacts to Moonlight connecting
(switch to stream-ready) and disconnecting (back to native), so the desktop is never
left on the virtual display.

## Client (Moonlight on Steam Deck)

| Setting | Value |
|---|---|
| Resolution | 1280x800 (panel native) |
| FPS | 90 on OLED, 60 on LCD |
| Codec | HEVC — never AV1 (no Deck has an AV1 hardware decoder) |
| Bitrate | 40–50 Mbps on LAN, 25–30 on weak Wi-Fi |
| Hardware decoding | on |
| V-Sync / frame pacing | on |
| HDR | off unless the host really outputs HDR (see `docs/DESIGN.md`) |

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
bin/ostreamy             switch/status/fix commands
bin/ostreamy-watch       activity watcher (systemd user service)
bin/ostreamy-verify      health + panel-off simulation
lib/ostreamy/common.sh   shared helpers (monitor/workspace/socket plumbing)
config/                  example config (installed to ~/.config/ostreamy/config.sh)
hypr/ostreamy.lua        Hyprland snippet template (inserted by install.sh)
systemd/                 user unit for the watcher
docs/DESIGN.md           why each decision exists, with the log evidence
docs/TROUBLESHOOTING.md  symptom → cause → fix
docs/CLIENT.md           Steam Deck / Moonlight specifics
tests/smoke.sh           end-to-end switch test against the running session
```

Configuration lives in `~/.config/ostreamy/config.sh` (output name, mode, grace,
poll interval, ports). Changing `MODE` means updating the Hyprland snippet
too — re-run `./install.sh` after editing the config, or edit both by hand.

## Uninstall

```bash
./uninstall.sh            # removes scripts, unit, and managed config blocks
./uninstall.sh --purge    # also deletes ~/.config/ostreamy
```

## Notes

- Steam Remote Play is a different capture path (`-pipewire`, portal picker) and is
  not managed by ostreamy. If you use it, it must also capture `STREAM` to survive
  the panel being switched off.
- The virtual display is always allocated. Display settings will list it; do not
  disable or remove it while Sunshine runs.
- HDR is not achievable on an SDR compositor/output; see `docs/DESIGN.md`.

## License

MIT
