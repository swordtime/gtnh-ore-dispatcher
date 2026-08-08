# GTNH Ore Dispatcher

Current release: **v0.5.0**

## v0.4.0 UI Refresh

This release intentionally keeps the v0.3.3 dispatch architecture and focuses on presentation.

### New dashboard

- GPU-rendered full-screen dashboard.
- Dark industrial / sci-fi visual language.
- **Solid green progress bars using GPU background fills** rather than `#`.
- LIVE / DRY RUN status badge.
- Summary cards: targets, active jobs, raw ore types, bus slots, pending changes.
- Color-coded states:
  - green: completed
  - cyan: processing
  - amber: waiting for ore
  - red: mapping failure
  - blue: queued
- Large-screen auto layout.
- Automatic compact fallback on low-resolution or monochrome screens.

### Existing local config remains valid

`ore-update` still does not overwrite:

```text
/home/ore_dispatch_config.lua
/home/ore_dispatch_overrides.lua
```

You do **not** need to re-enter your UUIDs.

Optional v0.4 setting:

```lua
uiUseMaxResolution = true
```

If the field is absent, v0.4 defaults to using the GPU's maximum resolution.

### Upgrade

Upload this release to the repository root, then on the OC:

```sh
ore-update
```

Run:

```sh
lua /home/ore_dispatcher.lua
```


## v0.4.1 Short launch command

The updater now installs:

```text
/bin/ore.lua
```

After installation or update, start the controller simply with:

```sh
ore
```

The old command still works:

```sh
lua /home/ore_dispatcher.lua
```

Updating remains:

```sh
ore-update
```


## v0.5.0 Interactive UI foundation

The dashboard now reserves three fixed touch-button slots in the upper-right corner:

```text
[ 命名 ] [ 扩展 ] [ 退出 ] [ LIVE ]
```

Current behavior:

- `命名`: reserved, disabled for now.
- `扩展`: reserved, disabled for now.
- `退出`: active. Touching it exits the dashboard cleanly and returns to the OpenOS shell.

The program now uses `event.pull()` between control cycles instead of a blind `os.sleep()`, so screen touches can be handled without stopping the dispatcher refresh loop.

On exit the program restores the terminal resolution/colors it had before the dashboard started.

This button registry is intentionally reusable. Future rename/settings/maintenance functions can attach to the existing slots without redesigning the dashboard geometry.
