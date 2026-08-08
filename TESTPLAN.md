# v0.6.1-stable 实机测试顺序

这份测试计划的目标不是“一次把所有功能打开”，而是按不可逆风险从低到高验证。

## 0. 准备

保持：

```lua
dryRun = true
```

用户策略保持：

```lua
autoSurplusEnabled = false
voidEnabled = false
```

Storage Bus 最后一格（63 格总线即 GUI 第 63 格）放永久占位物。
这个占位物必须不会出现在原矿缓存网。

---

## 1. TARGET 回归测试

启动：

```sh
ore
```

确认原有请求器目标仍正确：

- Barium Dust 等目标能显示；
- 当前/目标库存正确；
- 原矿缓存正确；
- 状态从 `等待原矿 / 待处理 / 处理中 / 已完成` 正常变化；
- DRY RUN 下 Storage Bus 不被写。

通过后再考虑 LIVE。

---

## 2. Sentinel 安全测试

仍保持 DRY RUN，观察启动警告。

然后临时把第 63 格占位符取出：
- DRY RUN 应显示安全警告；
- LIVE 模式下应拒绝启动。

把占位符放回。

这个测试通过，才允许长期 LIVE。

---

## 3. 缓存页 / 滚动

进入 `[缓存]`：

- 应显示全部识别出的 oreXxx 材料；
- 材料超过一屏时，鼠标滚轮可以上下浏览；
- footer 应显示类似 `矿物 17-32 / 84`；
- 点击任意可见矿物后 `[命名] / [策略]` 可用。

---

## 4. 命名 / 策略维护锁

先在 LIVE 前做一次 DRY RUN 交互。

然后 LIVE 小规模测试：
- 当前有 TARGET 在处理时点击 `[命名]`；
- 程序应先清空 managedSlots；
- 第 63 格 Sentinel 保留；
- 因此矿处应暂停获取原矿；
- 输入完成后程序重新扫描并恢复应有白名单。

这项验证的是：阻塞 `io.read()` 不会导致后台继续无限加工。

---

## 5. AUTO 小阈值测试

不要直接用 100M / 10M。

选一个伴生矿，例如 Lead Ore，临时设置：

```text
AUTO
高阈值 1000
低阈值 200
```

开启 `余矿自动 ON`。

验证：
1. 库存 <1000 时不启动；
2. 库存 >=1000 时加入 Storage Bus；
3. 降到 999 后不能立刻退出；
4. 一直处理到 <=200 才退出；
5. TARGET 同时出现时，TARGET 优先占槽；
6. AUTO 只使用剩余 `maxActive` 槽。

---

## 6. AUTO 重启持久化

让测试矿处于：

```text
draining = true
库存位于 200~1000 之间
```

例如已经从 1200 排到 600。

退出/重启 OC，再启动 `ore`。

预期：
- 600 虽然低于高阈值 1000；
- 但程序读取 `/home/ore_dispatch_state.lua`；
- 应继续排到 <=200。

通过后再把真实阈值改成 100M / 10M。

---

## 7. IGNORE

把某伴生矿设为 IGNORE。

无论库存多高：
- 不得进入 AUTO；
- 不得占 Storage Bus managedSlots。

如果后来这个材料成为请求器 TARGET：
- TARGET 必须覆盖 IGNORE；
- 仍应正常进入矿处。

---

## 8. VOID 当前只验证“不会销毁”

设置某矿策略为 VOID。

当前 v0.6.1-stable 预期：
- UI 显示 `VOID总闸关闭` 或 `VOID待硬件`；
- 不会配置任何 Export Bus；
- 不会删除任何物品。

即使：

```lua
voidEnabled = true
```

本版仍然不会真实销毁。

---

## 9. Export Bus 只读探测

未来接真实 VOID 前，搭一根独立 `me_exportbus`，然后：

```sh
ore-probe-export
```

它只打印 UUID 和 methods，不写配置、不导出物品。

把输出截图交回继续做实机 API 验证。

---

## 通过标准

真正称为可长期 LIVE 的 v0.6，至少需要：

- TARGET 回归通过；
- Sentinel 拒绝零过滤通过；
- AUTO 高低阈值通过；
- TARGET > AUTO 抢占通过；
- AUTO 重启续排通过；
- 维护锁暂停进料通过；
- 长列表滚动通过。

VOID 不属于 v0.6.1-stable 的上线条件，因为真实销毁明确尚未实现。
