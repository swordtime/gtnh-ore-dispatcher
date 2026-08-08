# v0.7.0-rc1 实机测试计划

## 0. 不接 OVERFLOW 也能先启动

先保持：

```lua
dryRun = true
overflowStorageBusAddress = nil
```

确认原 TARGET / AUTO 与 v0.6.1 一致。

## 1. 搭 OVERFLOW 硬件

```text
原矿缓存 AE
  -> 高优先级 OVERFLOW Storage Bus
  -> 垃圾桶 / 无限销毁库存
```

最后一格手工放占位符。

不要在动态槽里手工放真实矿。

## 2. 找 UUID

运行：

```sh
ore-probe-buses
```

区分：
- PROCESS Storage Bus
- OVERFLOW Storage Bus

然后填写：

```lua
processStorageBusAddress = "..."
overflowStorageBusAddress = "..."
```

如果 side 无法自动识别，再填对应 side。

## 3. 先做 DRY RUN

保持：

```lua
dryRun = true
overflowEnabled = false
```

进入缓存页，确认：
- OVERFLOW Bus 显示已连接；
- 每种矿可以单独设置加工 AUTO/IGNORE；
- 每种矿可以独立设置溢流 ON/OFF 与阈值；
- 旧 VOID 不会自动开启溢流。

## 4. 验证最后一格绝不被程序碰

PROCESS 与 OVERFLOW 两根总线：
- 在最后一格手工放占位符；
- 多次刷新、切换策略、退出程序；
- 最后一格必须始终不变。

## 5. 小阈值 OVERFLOW 实测

选一个安全测试矿，设置：

```text
加工：IGNORE
溢流：ON
上限：1000
恢复：800
```

全局开启“溢流 ON”。

预期：
- 库存 <1000：OVERFLOW Bus 动态槽没有该矿；
- 库存 >=1000：该矿被写入 OVERFLOW Bus；
- 已经存着的旧库存不会主动下降；
- 后续新进入 AE 的该矿应优先进入垃圾桶；
- 当正常消耗把库存降到 <=800：过滤被移除。

## 6. TARGET 绝对保护

让同一种原矿对应的最终产物成为请求器 TARGET。

无论缓存多高：
- OVERFLOW 必须立即移除该矿；
- UI 显示 TARGET 保护；
- 该矿只能走 TARGET / PROCESS 逻辑。

## 7. AUTO + OVERFLOW 同时测试

例如：

```text
AUTO 1000 -> 200
OVERFLOW 3000 / 2500
```

预期：
- >=1000 后可进矿处；
- 如果流入太快仍涨到 >=3000，后续新增同时被 OVERFLOW 拦截；
- TARGET 出现时 OVERFLOW 立即取消。

## 8. 正常退出清理

在 OVERFLOW 正在拦截时点击 `[退出]`。

预期：
- PROCESS 动态槽被清空；
- OVERFLOW 动态槽被清空；
- 两根 Storage Bus 的最后一格占位符仍保留。

## 通过标准

RC 升为稳定版前至少需要：
- 原 TARGET 回归通过；
- 原 AUTO 回归通过；
- 双 Bus UUID/side 正确；
- 最后一格永不被触碰；
- OVERFLOW 只拦截后续新增；
- 高/低阈值滞回正确；
- TARGET 强制关闭 OVERFLOW；
- 正常退出会清动态过滤。
