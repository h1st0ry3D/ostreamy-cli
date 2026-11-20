# Upstream crash reports

Two crashes were observed on this host while testing an idle layout in which the
headless output `STREAM` mirrored the physical panel (instead of being parked
unmirrored). That layout has been removed from Ostreamy; these reports exist so the
underlying defects can be fixed upstream.

Host: Arch, Hyprland 0.56.2 (`efb5099`), aquamarine 0.15.1, NVIDIA RTX 4070
(nvidia-drm), Omarchy shell (Quickshell 0.3.2) on Hyprland's Lua config.
Physical panel: Dell S2725DC, `HDMI-A-1`, 2560x1440@144. Headless output: `STREAM`,
1920x1200@60, created with `hyprctl output create headless`.

## 1. Hyprland aborts when an output that is a mirror source is disabled

Status: **proven by core dump and symbolized stack**, reproduced once deliberately and
once as a side effect.

What happened: `HDMI-A-1` was the source of a mirror (`STREAM` had
`mirrorOf: "0"`). Disabling it with

```
hyprctl eval 'hl.monitor({ output = "HDMI-A-1", disabled = true })'
```

aborted the compositor within about a second, while the layer surfaces (the Omarchy
bar) on that output were being unmapped. The same command did **not** crash when
`HDMI-A-1` was a *mirror target* (`HDMI-A-1` had `mirrorOf: "1"`, workspaces on
`STREAM`), which is the layout Ostreamy ships: `ostreamy-verify --simulate-off`
passes there, including a screenshot of `STREAM` while the panel is disabled.

Evidence:

```
PID 982 (Hyprland), Signal 6 (ABRT) si_code SI_TKILL
Command Line: Hyprland --watchdog-fd 4
#2  abort                                              libc
#6  CInputManager::refocusLastWindow(CSharedPointer<Monitor::CMonitor>)
#7  Desktop::View::CLayerSurface::onUnmap()
#8  Desktop::View::CLayerSurface::onDestroy()
#9  Hyprutils::Signal::CSignalListener::emitInternal(void*)
#11 (anonymous)                                        Hyprland + 0x85ec5b
#12 (anonymous)                                        Hyprland + 0xaacea6
#16 wl_closure_invoke                                 libwayland-server
#18 wl_event_loop_dispatch                            libwayland-server
#19 wl_display_run
```

Repro:

1. Two enabled outputs, the permanent one headless: `STREAM` 1920x1200@60,
   `HDMI-A-1` 2560x1440@144.
2. Make the headless output mirror the panel:
   `hyprctl eval 'hl.monitor({ output = "STREAM", mode = "1920x1200@60", position = "-1920x0", scale = 1, mirror = "HDMI-A-1" })'`
3. `hyprctl eval 'hl.monitor({ output = "HDMI-A-1", disabled = true })'`
   -> SIGABRT in `CInputManager::refocusLastWindow` during layer-surface unmap.

Expected: disabling a monitor removes it and its mirror, leaving the mirroring output
unmirrored (it stays enabled and keeps its mode).

Likely mechanism (inference, not proven): the mirror relationship is not torn down
before the removed monitor's layer surfaces are destroyed, so `refocusLastWindow`
walks a stale monitor/mirror reference. The abort itself comes from a `raise()` in a
Hyprland trap path, `refocusLastWindow` is the frame that trips it.

Also observed at the same time: `xdg-desktop-portal-hyprland` SIGSEGV (PID 1564).
That process is restarted by its unit; no further evidence collected.

## 2. Quickshell 0.3.2 crash loop while that layout was active

Status: **correlated, not proven.** 9 SIGSEGV cores within ~90 s, then "Omarchy shell
gave up after 6 relaunches in under a minute". After removing the mirror layout and
restarting the shell, Quickshell has been stable across layout switches, workspace
moves and a full `ostreamy-verify --simulate-off` run.

Observed context in the Quickshell log (`/run/user/1000/quickshell/by-id/*/log.qslog`)
right before the crashes was heavy monitor/workspace churn, including a monitor that is
a mirror:

```
Received event: "focusedmon>>STREAM,2"
Received event: "createworkspace>>2"
Received event: "workspace>>11"  / "destroyworkspace>>11"
Received event: "moveworkspacev2>>11,11,HDMI-A-1"
qml: .../h1st0ry3d.odisplay/Panel.qml[988:26]: Unable to assign [undefined] to QColor
ERROR: Quickshell has crashed under pid 63466
```

Cores: `coredumpctl info 63466` (and 51626, 52654, 54525, 56079, 58194, 59829, 61578).
Crashes were SIGSEGV with an unsymbolized `libc`/`quickshell` stack; no QML stack was
printed, so the trigger is not identified. Both the local `llm.workspaces` widget and
the `h1st0ry3d.odisplay` warning are plausible contributors and worth ruling out with
that layout reproduced in isolation.

## What Ostreamy does instead

The panel is the output that can disappear, so it must never be a mirror source.
`STREAM` stays the only mirror source (and only while streaming), and the idle layout
parks it **beyond a gap** so the pointer cannot reach it. Hyprland clamps the pointer
to the nearest monitor, which makes a wide gap equivalent to "not in the layout" for
input purposes. See `DESIGN.md` section 14.
