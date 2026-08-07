# GTNH Ore Dispatcher

OpenComputers ore processing dispatcher for **GTNH 2.9**.

当前版本：**0.3.0**

仓库：

`https://github.com/swordtime/gtnh-ore-dispatcher`

---

## v0.3.0 核心架构

v0.3 正式改为“专用矿处成品网”：

```text
太空采矿
   |
   v
[原矿缓存网]
   |
   |  OC 动态 Storage Bus 白名单
   v
[矿处处理网]
   |
   v
集成矿石处理厂
   |
   v
[矿处成品网]
   |
   |  主网 Storage Bus / Interface 桥接
   v
主网消费
```

矿处 OC 只直接读取：

1. **成品网**：Barium Dust / Ruby / Diamond 等最终库存。
2. **原矿缓存网**：Barium Ore / Ruby Ore 等原料库存。
3. **ME 请求器**：目标库存。
4. **me_storagebus**：动态控制当前允许矿处访问哪些原矿。

主网不再作为矿处 OC 的库存扫描对象。

---

## 自动映射

程序优先使用 OreDictionary 的共同材料键：

```text
dustBarium -> Barium <- oreBarium
gemRuby    -> Ruby    <- oreRuby
```

因此正常金属和宝石不需要逐个写死映射。

自动映射失败的极少数特殊矿物，可以写进：

`/home/ore_dispatch_overrides.lua`

无需修改主程序。

---

## 多请求器

程序自动扫描所有：

`level_maintainer`

默认每个请求器读取 5 个槽。

例如：

```text
请求器 #1
- Barium Dust      10M
- Neodymium Dust   10M
- Tungsten Dust    10M

请求器 #2
- Ruby              5M
- Diamond           5M
- Emerald           5M
```

同一目标：

- 重复且目标值一致：自动去重。
- 重复但目标值不同：直接报错，拒绝调度。

---

## 第一次安装

OC 需要 **Internet Card**。

```sh
wget -f https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/install.lua /tmp/ore-install.lua
```

然后：

```sh
/tmp/ore-install.lua
```

如果直接执行不方便，也可以：

```sh
lua /tmp/ore-install.lua
```

安装后编辑：

```sh
edit /home/ore_dispatch_config.lua
```

至少填写：

```lua
productMeAddress = "矿处成品网二合一 ME Interface UUID",
cacheMeAddress   = "原矿缓存网二合一 ME Interface UUID",
```

首次保持：

```lua
dryRun = true,
```

---

## 从 v0.2 升级

GitHub 上传 v0.3 文件后，旧 OC 直接执行：

```sh
ore-update
```

v0.3 主程序兼容旧配置字段：

```lua
mainMeAddress = "..."
```

会自动把它当作：

```lua
productMeAddress = "..."
```

因此 **升级本身不要求立即修改旧本地配置**。

但建议之后手工把字段名改成：

```lua
productMeAddress = "..."
```

避免以后混淆。

---

## 一键更新

日后只需：

```sh
ore-update
```

强制重新安装当前版本：

```sh
ore-update --force
```

更新器不会覆盖：

```text
/home/ore_dispatch_config.lua
/home/ore_dispatch_overrides.lua
```

最新版示例会单独更新到：

```text
/home/ore_dispatch_config.example.lua
/home/ore_dispatch_overrides.example.lua
```

---

## 推荐硬件连接

矿处 OC 至少应能看到：

```text
fluid_interface / me_interface
  -> 成品网二合一接口

fluid_interface / me_interface
  -> 原矿缓存网二合一接口

me_storagebus
  -> 原矿缓存网与矿处处理网之间的受控 Storage Bus

level_maintainer x N
  -> 所有最终产物目标请求器
```

Database 当前不是必需组件。

---

## Dashboard

v0.3 启动后会显示：

```text
GTNH Ore Dispatch Controller v0.3.0

成品网 12345678...abcd | 缓存网 87654321...dcba | [DRY RUN]
StorageBus abcdef12...3456 side=2 slots=63 managed=16 | 请求器=6 目标=27 | active=8 changes=3
缓存扫描: 网络物品栈=84 原矿匹配=31 | 重复目标=0

目标产物                  当前 / 目标          进度                  原矿缓存      状态
------------------------------------------------------------------------------------------------
Neodymium Dust           1.02M / 10.00M   [##................]  10.2%          0   等待原矿
Barium Dust              2.31M / 10.00M   [####..............]  23.1%      1.84M   处理中
Ruby                     4.10M / 5.00M    [###############...]  82.0%     725.4k   处理中
Diamond                  5.36M / 5.00M    [##################] 107.2%      1.31M   已完成
```

---

## 状态说明

- `处理中`：最终产物不足、有对应原矿，并已进入当前动态白名单。
- `已完成`：达到停止线。
- `等待原矿`：最终产物不足，但缓存没有对应原矿。
- `待处理`：满足处理条件，但受 `maxActive` 限制暂未开放。
- `待低于启动线`：位于滞回区间，暂不重新启动。
- `映射失败`：未能建立最终产物与原矿之间的材料关系。

---

## 滞回

默认：

```lua
reopenRatio = 0.95
stopRatio   = 1.00
```

目标 10M 时：

```text
低于 9.5M -> 开始补
开始后     -> 一直补到 10M
10M        -> 停止
```

避免在目标附近频繁开关。

---

## 上线前安全检查

首次部署建议始终：

```lua
dryRun = true
```

确认：

1. 成品网能正确读取请求器中的目标物。
2. 缓存网能通过 `getItemsInNetwork({})` 扫描全部原矿。
3. OreDictionary 自动映射正确。
4. Storage Bus side / 槽位数量正确。
5. `setStorageConfiguration(side, slot)` 清空过滤槽的实机行为已确认。

全部确认后再：

```lua
dryRun = false
```

进入 LIVE。
