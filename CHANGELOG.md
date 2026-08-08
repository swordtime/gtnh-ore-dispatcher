# Changelog

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
