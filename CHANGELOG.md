# Changelog

## 0.5.0

### Interactive dashboard
- Added a reusable touch-button framework based on OpenComputers `touch` events.
- Reserved three permanent header button slots.
- Added a working `退出` button that returns to the OpenOS shell.
- Replaced main-loop `os.sleep()` with event-aware timed waiting so UI interaction does not suspend control-cycle scheduling.
- Restores original GPU resolution/foreground/background on clean exit.
- Added initial fixed-label Chinese localization throughout the dashboard.
- `命名` and `扩展` button slots are intentionally present but disabled until their functions are implemented.

## 0.4.1

### Launcher
- Added `/bin/ore.lua`.
- The controller can now be started with the single command `ore`.
- `ore-update` automatically installs and updates the launcher.
- The legacy `lua /home/ore_dispatcher.lua` start method remains valid.

## 0.4.0

### UI
- Rebuilt Dashboard around direct GPU rendering.
- Replaced ASCII `#` progress bars with solid green GPU background bars.
- Added dark dashboard theme and green accent system.
- Added LIVE / DRY RUN badge.
- Added summary statistic cards.
- Added colored status indicators and alternating resource rows.
- Added adaptive large-screen layout and low-resolution fallback.
- Added optional `uiUseMaxResolution`.

### Compatibility
- Keeps v0.3.3 indirect `component.invoke()` compatibility.
- Keeps `oreEndstoneBarium` / `Barium Ore` alias fix.
- Existing local UUID/config file remains compatible and is not overwritten.
