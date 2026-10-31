# Steam Deck / Moonlight client notes

## Pairing

1. Install Moonlight on the Deck (Flatpak or Discover).
2. It should find the host over mDNS; otherwise add it by IP.
3. Moonlight shows a 4-digit PIN. Enter it at `https://<host-ip>:47990`
   (Sunshine Web UI → PIN).

## Settings

| Setting | Value | Why |
|---|---|---|
| Resolution | 1280x800 | panel native; avoids an extra scale |
| FPS | 90 (OLED) / 60 (LCD) | matches the panel |
| Codec | HEVC | best quality per bit that the Deck decodes in hardware |
| Bitrate | 40–50 Mbps LAN, 25–30 weak Wi-Fi | at 1200p, 10 Mbps looks soft |
| Hardware decoding | on | VCN handles HEVC 10-bit |
| V-Sync | on | removes tearing inside the stream |
| Frame pacing | on | smooths 60 fps content on a 90 Hz panel |
| HDR | off | host is SDR (see docs/DESIGN.md §9) |

Do not pick AV1: no Steam Deck model has an AV1 hardware decoder, so it would decode
in software and stutter. `av1_mode = 1` in `sunshine.conf` hides it from the client.

Do not pick VP9: neither Sunshine nor Moonlight supports it as a stream codec, and
NVENC has no VP9 encoder.

## Odds and ends

- The host mirrors the headless output to its own monitor while you play, so the
  physical screen shows the same picture (vertically squashed, 16:10 → 16:9).
  `ostreamy off` restores the native desktop when you are done.
- Controller passthrough needs `/dev/uinput` (group `input`); ostreamy-verify checks
  it.
- Audio is captured from a temporary `sink-sunshine-stereo` sink and the host's sink
  is restored after the stream.
- Host bitrate ceiling is 0 (client decides). Only set `max_bitrate` if you must cap
  a client.

## Launch options (optional)

Only useful for forcing codec/bitrate; they cannot fix aspect. Verify flags with
`--help` on your Moonlight build.

```bash
flatpak run com.moonlight_stream.Moonlight stream <host> \
  -app Desktop -width 1280 -height 800 -fps 90 -bitrate 40000 -codec hevc -display-mode fullscreen
```
