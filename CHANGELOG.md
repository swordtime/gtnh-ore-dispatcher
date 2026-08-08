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


## 0.7.0-rc2

- 余矿管理 UI 只显示非 TARGET 材料。
- TARGET 材料仍保留在后台完整扫描数据中，用于调度和安全保护。
- 余矿矿种与余矿总量不再计入 TARGET 库存。
- 已选中的余矿如果变成 TARGET，会自动取消选择并从页面消失。
- TARGET 期间保留原 AUTO / IGNORE / OVERFLOW 用户配置。
- 取消 TARGET 后材料自动重新出现并恢复原配置。
