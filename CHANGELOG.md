# Changelog

## 0.7.0-rc1

### Dual Storage Bus architecture
- Split PROCESS and OVERFLOW into two independently controlled Storage Buses.
- Added explicit `processStorageBusAddress` and `overflowStorageBusAddress`.
- Preserved legacy PROCESS fields for backward compatibility.
- The GUI last slot of every controlled Storage Bus is now a hard reserved slot and is never touched by OC.

### Overflow Guard
- Replaced the old non-functional VOID concept with an independent OVERFLOW guard.
- OVERFLOW does not purge existing stock.
- When a material reaches its overflow high threshold, it is added to the dedicated high-priority trash Storage Bus.
- It remains active until cached stock falls to the overflow low threshold.
- TARGET always disables OVERFLOW for the same material.
- AUTO and OVERFLOW may be enabled simultaneously.

### Safety
- Global OVERFLOW switch defaults OFF.
- Per-material OVERFLOW defaults OFF.
- Legacy v0.6 VOID migrates to IGNORE + OVERFLOW OFF.
- Clean exit and caught errors best-effort clear dynamic PROCESS and OVERFLOW filters while leaving the reserved last slot untouched.

### UI / tools
- Cache page now shows AUTO and OVERFLOW as separate layers.
- Added global AUTO and OVERFLOW switches.
- Added `ore-probe-buses`, a read-only Storage Bus discovery command.
