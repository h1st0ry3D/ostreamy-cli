# Design notes and evidence

Every rule here exists because a simpler version broke in a specific, observable
way. Logs are from a host running Hyprland 0.56.2 on Omarchy 4.0.6, with an RTX 4070
and a Steam Deck OLED client.

## 1. Capture a headless output, not the panel

Switching a monitor off drops its link. Hyprland is then left with no enabled
output, stops compositing, and `wlr-screencopy` has nothing to hand the encoder:

```
DEBUG from aquamarine ]: drm: Connector DP-3 disconnected
DEBUG from aquamarine ]: drm: DP-3 is not connected, clearing stale crtc 92
```

The stream goes black and comes back when the panel returns. A headless output that
is always present is the fix.

## 2. Never create, destroy, disable or resize it while Sunshine runs

First attempt: create `STREAM` on connect, remove it on disconnect. Two failure
modes, both reproduced:

```
Sunshine SIGABRT four times (13:59:31, 13:59:42, 13:59:54, 14:00:06)  # output removed under capture
Hyprland SIGSEGV (14:00:13) CFocusState::fullWindowFocus on CWindow::unmapWindow
                              std::__throw_bad_variant_access
```

Second attempt: disable/enable it instead of removing. That races the client, because
Sunshine resolves `output_name` **once, at session start**, and falls back to
`monitors[0]` when the target is missing:

```
14:34:49.487 Resolution: 2560x1440     # session started on the panel
14:34:51.729 Error: Couldn't import RGB Image: 0000300C
14:34:51.812 Resolution: 1920x1200     # output changed under the live encoder
14:34:51.833 Creating encoder [hevc_nvenc]
```

Symptom: video freezes after a few seconds while the controller keeps working.
Input is a separate channel, so it does not notice. The conclusion is that the
capture target and its mode must stay constant. Only the layout changes.

## 3. The output must never overlap the primary

Two enabled outputs at the same origin produce:

```
Your monitor layout is set up incorrectly. Monitor HDMI-A-1 overlaps with other
monitor(s) in the layout. This will cause issues.
```

and, worse, pointer input and workspace shortcuts land on the invisible output. Park
`STREAM` at a negative x (`-<stream width>x0`); the primary output's `position =
"auto"` then places it at 0,0 by itself. No panel rule needs editing.

## 4. Mirrors are runtime-only, cleared by a reload

A monitor rule can add a mirror; re-applying a rule without `mirror` does **not**
remove it. Mirror is therefore applied at runtime (`hyprctl eval`) and cleared by
`hyprctl reload` against a mirror-free config rule. Two extra consequences:

- apply the mirror *after* moving workspaces, because moving re-applies the config
  and drops the runtime rule;
- mode strings for runtime rules must use an integer refresh (`@144`); Hyprland
  rejects `@143.96899` silently.

## 5. Detection: TIME-WAIT is a trigger, not a state

Moonlight's control connections are short-lived. A 0.25 s poll almost always sees them
already closed:

```
TIME-WAIT  192.168.0.99:47989   192.168.0.74:57852
```

Counting only `ESTABLISHED` made real clients invisible (a held-open `nc` test passed,
the Deck did not). But counting TIME-WAIT as "still connected" caused `off` to be
re-mirrored within a poll, so the desktop never came back to its native mode.

Final rules:

| Signal | Meaning | Use |
|---|---|---|
| `ESTAB`, `CLOSE-WAIT` or `SYN` on Sunshine ports | live session | keep layout armed, re-assert mirror |
| a **new** remote endpoint on those ports | a fresh client | trigger switch-on |
| `CLIENT DISCONNECTED` in `sunshine.log` | session ended | switch back (about 0.22 s) |
| Sunshine unit inactive | host gone | switch back |
| native layout + nothing live | deliberate manual `off` | standby, do not re-arm |

The watcher keeps a snapshot of client endpoints and switches on when one appears
that was not in the snapshot. A count of sockets alone cannot do this. A leftover
`TIME-WAIT` from a session that ended is already in the snapshot, so it cannot
re-arm the layout.

New endpoints alone were not enough either. When the Deck quits a stream it keeps
polling its host list. Those polls create new short-lived connections, and they
re-armed the layout two seconds after the session ended. A 20 s quiet window after
a switch-off that came from a session end ignores them. A quiet socket table is
never used to end a session either: Moonlight's control connections close right
after an app launches, so the watcher stayed armed on the log signal alone and a
live-socket timeout would have disarmed mid-game. A manual `ostreamy off`
opens no window, because the next real client has to arm immediately. A live
connection or a `New streaming session started` line always arms.

Endpoints are normalised to the client end. Inbound connections carry the client in
the peer column; a local test connection carries it in the local column.

## 6. Safety net for a late switch

If `New streaming session started` appears while the layout is still native, the
watcher switches the layout and restarts Sunshine. The restart costs about two
seconds; a frozen frame needs a reconnect anyway.

## 7. Focus must move with the workspaces

Moving workspaces onto `STREAM` is not enough. Hyprland opens new windows on the
focused monitor, so if the panel keeps focus, the next app launched by Sunshine
(Steam Big Picture, a game) opens on the panel and the Deck shows an extended
desktop instead of the game. `ostreamy on` now focuses a workspace on `STREAM` after
mirroring, and the watcher calls `ostreamy recover` when the mirror drops or a
windowed workspace appears on the panel. Recovery only moves workspaces and
re-applies the mirror, never the mode, so it is safe mid-session.

## 8. Workspace ids are numbers

`hl.dsp.workspace.move({ workspace = "1", ... })` is accepted by the dispatcher but
does nothing; the window then ends up on `mon=-1` when the output is removed. Pass an
integer.

## 9. A stale instance signature breaks everything silently

After a compositor restart, long-lived shells and services keep the old
`HYPRLAND_INSTANCE_SIGNATURE`, and every `hyprctl` call fails. Every script resolves
the live instance from `hyprctl instances` instead of trusting the environment.

## 10. Codec and HDR reality

- HEVC only. AV1 must not be advertised: no Steam Deck has an AV1 hardware decoder,
  so a session would software-decode and stutter. `av1_mode = 1`.
- 10-bit HEVC is SDR in a 10-bit container (less banding), not HDR.
- HDR is out of reach on a Hyprland/SDR host: Sunshine's Linux HDR path requires the
  KMS capture backend (not `wlr`), is documented for Intel/AMD VAAPI Main10 rather
  than NVENC, and the headless output is 8-bit `XRGB8888` with an sRGB preset.
- VP9 is unavailable: Sunshine's encoders are nvenc/quicksync/amdvce/vaapi/vulkan/
  software, NVENC has no VP9 encoder, and Moonlight supports H.264/HEVC/AV1 only.

## 11. Restoring the panel means its native mode, not its current one

While the panel mirrors a 16:10 output it reports that output's size. Deriving the
"restore" mode from the panel's current resolution therefore restores the Deck's
resolution (1920x1200) instead of the monitor's (2560x1440@144). Ostreamy picks the
panel's largest available mode and the highest refresh within it, so the result does
not depend on whether a mirror is active.

## 12. Ordering that avoids the overlap warning

Both directions used to overlap for a moment:

| step | `on` | `off` |
|---|---|---|
| 1 | ensure output exists (parked, negative x) | disable nothing; reload clears the mirror |
| 2 | move workspaces onto `STREAM` | move workspaces back to the panel |
| 3 | apply the mirror | focus a workspace that has windows |
| 4 | re-apply the mirror | `ostreamy fix` if focus is still on `STREAM` |

## 13. Scale must be given explicitly

A monitor rule that omits `scale` gets **auto** scale, and auto resolves to 2 on a
headless output at 1920x1200 -- and at 2560x1440. Measured on Hyprland 0.56.2:

```
hyprctl output create headless TEST                                         -> scale=1
hyprctl eval 'hl.monitor({ output = "TEST", mode = "1920x1200@60", ... })'  -> scale=2
hyprctl eval 'hl.monitor({ output = "TEST", mode = "2560x1440@144", ... })' -> scale=2
```

The buffer stays 1920x1200, but the logical desktop becomes 960x600, so every
window is drawn at half size and upscaled: the client gets a zoomed, soft picture
and games lose their real UI density. `SCALE` (default 1) is therefore passed on
every `hl.monitor` call Ostreamy makes -- creation, `ensure`, `ostreamy mode`, and
the rule `sync_hypr_mode` writes -- so the value cannot be lost by a rewrite.

It also makes the layout self-healing: Omarchy's `SUPER + /` monitor-scaling action
targets the *focused* monitor, which while streaming is `STREAM`. That is how the
scale reached 2 here in the first place (see `~/.local/state/omarchy/monitor-scaling.log`).
A pinned `SCALE` is reapplied at the next switch-on.

## 14. A parked output is a pointer target, and a mirror of the panel is a crash

The hidden output is enabled, so it holds a region of the virtual layout. The first
version parked it flush against the panel (`-<width>x0`), which made the panel's left
edge a doorway into it. With Hyprland's defaults:

```
input:follow_mouse            = 1     # movement always changes focus
cursor:warp_on_monitor_change = -1    # follows cursor:warp_on_change_workspace = 1
```

crossing the edge focuses `STREAM`, its (empty) workspace becomes active and the
cursor is warped to that output's last focus position -- "the mouse at the border
switches workspace and jumps back to the middle of the screen". Measured on 0.56.2
(`hl.dsp.cursor.move` is a warp, so it doubles as a worst-case single event):

```
STREAM at 4000x0, panel at 0x0 (gap 1440)
  aim x=3000  -> cursor 2559,700, HDMI-A-1        # clamped: panel is nearer
  aim x=3999  -> cursor 4000,700, STREAM          # nearest monitor wins
```

The clamp is to the *nearest* monitor, so the gap is the defence: a gap wider than
one pointer motion event makes `STREAM` unreachable, and pushing against the edge
sticks at the edge instead of focusing anything. A 1000 Hz mouse reports at most
~250 px per event; `PARK_X=6000` leaves thousands on a 2560-wide panel, and
`park_position()` widens it if a wider panel would leave less than 1500 px.

The obvious alternative -- make `STREAM` mirror the panel while idle so it owns no
layout region at all -- is not safe on this hardware. It works until the panel goes
away: disabling (or unplugging) an output that is the source of a mirror aborts the
compositor.

```
ctr  Command Line: Hyprland --watchdog-fd 4
     Signal: 6 (ABRT)
     #2  abort
     #6  CInputManager::refocusLastWindow(CSharedPointer<CMonitor>)
     #7  Desktop::View::CLayerSurface::onUnmap()
     #8  Desktop::View::CLayerSurface::onDestroy()
     ... wl_event_loop_dispatch -> wl_display_run
```

The panel is the output that can vanish, so it must never be a mirror source. That is
also why the shipped topology mirrors *onto* the panel and never the reverse:
`STREAM` is the permanent output and stays the source. The core dump and the exact
repro are written up in `UPSTREAM-BUGS.md`.
