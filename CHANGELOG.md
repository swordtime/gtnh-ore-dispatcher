# Changelog

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
