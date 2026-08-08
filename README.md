GTNH Ore Dispatch Controller v0.6.1-stable
=================================================

定位
----
对 v0.6.0 Cache Policy 原型做稳定化，不继续堆新功能。

策略
----
TARGET > AUTO > IGNORE / VOID

TARGET：请求器明确需要的最终产物，最高优先级。

AUTO：未设置 TARGET 的伴生矿统一余矿处理。
默认 100M -> 10M：
- >=100M 启动；
- 10M~100M 保持上一状态；
- <=10M 停止。
draining 状态写入 /home/ore_dispatch_state.lua，重启后继续排到低阈值。

IGNORE：不自动处理。

VOID：必须逐矿显式设置；本版仍不会真实销毁。

为什么 AUTO 用 OC
-----------------
AE 的 Level Emitter + Export Bus 很适合“一个确定物品”的阈值控制，
但每一种矿都要手工配置物品和阈值。

OC 可以：
- 扫描缓存网全部 oreXxx；
- 自动识别 TARGET / 非 TARGET；
- 对未标记材料统一应用 AUTO；
- TARGET 先抢槽，AUTO 只吃剩余槽；
- 单矿随时切换 AUTO / IGNORE / VOID。

v0.6.1-stable 修复
------------------
1. Storage Bus 安全哨兵
   默认：
     requireSentinel = true
     sentinelSlot = -1

   -1 = 最后一格。
   63 格总线即 GUI 第63格 / API slot 62。

   最后一格放一个绝不会进入原矿缓存网的占位物。
   LIVE 启动和每轮写白名单前都检查。
   占位物被误删时程序直接停机，避免零过滤导致全矿放行。

2. 阻塞编辑改为“安全维护锁”
   v0.6.0 的 io.read() 会冻结控制循环。
   现在打开命名/策略输入前，会先安全清空受控过滤槽，
   但哨兵仍保留，因此矿处暂停进料。
   输入完成后立即重扫并恢复正确白名单。

3. 长列表支持鼠标滚轮
   主目标页和缓存页都可滚动。
   footer 显示当前范围，例如：
     矿物 17-32 / 84

4. 禁止默认 VOID
   defaultPolicy 即使被写成 VOID，也会安全归一为 AUTO。
   VOID 必须逐矿显式选择。

过量销毁（VOID）最终方案
------------------------
建议单独硬件通道：

原矿缓存 AE
  -> 独立 ME Export Bus
  -> Trash Can / 明确会 void 的库存

未来真实 VOID 必须满足：
- 全局销毁总开关默认 OFF；
- 只能逐矿显式 VOID；
- TARGET 永远覆盖 VOID；
- 高阈值开始销毁，低阈值硬保留；
- 默认最多同时销毁 1 种；
- 未识别材料永不销毁；
- 先实测 GTNH 2.9.x me_exportbus API。

本版新增只读命令：
  ore-probe-export

它只打印 me_exportbus UUID 和 methods，不写配置、不导出物品。

启动
----
ore

更新
----
ore-update

只读探测 Export Bus
-------------------
ore-probe-export

用户文件不会被 updater 覆盖：
- /home/ore_dispatch_config.lua
- /home/ore_dispatch_overrides.lua
- /home/ore_dispatch_user.lua
- /home/ore_dispatch_state.lua


VOID 预留硬门
-------------
用户策略中预留：

```lua
voidEnabled = false
maxVoidActive = 1
```

`voidEnabled` 是未来真实销毁的全局硬开关。
v0.6.1-stable 尚未接入 Export Bus，因此即使手动改成 true，本版仍不会销毁任何物品。
