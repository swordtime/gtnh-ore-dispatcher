# Changelog

## 0.6.1-stable

- Stabilized TARGET > AUTO surplus dispatch.
- Kept default 100M -> 10M hysteresis with persistent drain state.
- Added mandatory-by-default Storage Bus sentinel fail-safe.
- Blocking rename/policy prompts now pause ore input safely before `io.read()`.
- Added mouse-wheel scrolling to target and full-cache pages.
- Forbidden global/default VOID; destruction must be explicit per material.
- VOID remains non-destructive until `me_exportbus` is empirically verified in GTNH 2.9.x.
- Added read-only `ore-probe-export`.
- Added updater-safe `ore_dispatch_user.example.lua`.
