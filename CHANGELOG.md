# Changelog

## 0.3.3

### 原矿自动映射修复
- 修复 `oreEndstoneBarium` 等带宿主岩石前缀的 GTNH OreDictionary 名称导致 `Barium Dust` 无法匹配 `Barium Ore`。
- 对已确认的矿石 ItemStack 同时建立 OreDictionary key 与 `"<Material> Ore"` label key。
- 实机案例现在可建立：
  - `oreEndstoneBarium -> endstonebarium`
  - `Barium Ore -> barium`
  - `Barium Dust -> barium`
- Dashboard 增加原矿别名数量诊断。
- 不需要修改现有 UUID、本地配置或请求器。

## 0.3.2

### GTNH 2.9 indirect component method 兼容修复
- 修复 `me_storagebus` 被误判为“不提供 getStorageSlotSize()`”。
- Storage Bus 的 `getStorageSlotSize` / `getStorageConfiguration` / `setStorageConfiguration` 统一改用 `component.invoke()`。
- `level_maintainer.getSlot()` 同步改用 `component.invoke()`，避免同类兼容问题。
- 本地配置与已填写 UUID 无需修改。

## 0.3.1

### GTNH 2.9 / OpenComputers 兼容修复
- 修复 `fluid_interface` 间接方法被误判为不存在的问题。
- 实机验证：`component.methods(address).getItemsInNetwork == false` 时，`component.invoke(address, "getItemsInNetwork", {})` 仍正常返回 table。
- 成品网与原矿缓存网读取统一通过 `component.invoke()`。
- 已填写的两个 UUID 无需修改。

## 0.3.0

### 架构
- 正式引入独立“矿处成品网”。
- `productMeAddress` 取代 `mainMeAddress`。
- 保留 `mainMeAddress` 向后兼容，旧 v0.2 本地配置可直接升级。

### 诊断 / UI
- 启动时显示成品网、缓存网、Storage Bus 地址。
- Dashboard 显示请求器数量、目标数量、缓存扫描量、active 数量与白名单变化数。
- 旧字段兼容时明确显示提示。

### 多请求器
- 自动扫描所有 `level_maintainer`。
- 相同目标、相同目标值自动去重。
- 相同目标、不同目标值直接报冲突并停止调度。

### 更新器
- `manifest.lua` 升级至 0.3.0。
- 更新器同时维护最新版 example 文件。
- 永不覆盖本地 `ore_dispatch_config.lua` 与 `ore_dispatch_overrides.lua`。

### 安全
- 增加配置合法性检查。
- 检查成品网/缓存网是否支持 `getItemsInNetwork()`。
- 检查 Storage Bus 所需读写 API。
- 默认继续保持 `dryRun=true`。
