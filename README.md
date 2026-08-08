# GTNH Ore Dispatcher

Current release: **v0.4.1**

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
