GTNH Ore Dispatch Controller v0.7.0-rc2
=================================================

定位
----
本版把 v0.6 的“后台余矿加工”扩展成双 Storage Bus 架构：

1. PROCESS Bus
   TARGET / AUTO 使用，送矿处。

2. OVERFLOW Bus
   专门贴垃圾桶/无限销毁库存。
   达到上限后，只拦截后续新进入 AE 的匹配原矿。
   不主动清理已经存下来的旧库存。

为什么不再把“销毁”做成单一 VOID
-------------------------------
主动从 AE 中把几亿旧库存抽出来再丢弃，需要 Export Bus 长时间搬运，
吞吐、能耗和控制复杂度都更高。

OVERFLOW 更像真正的“溢流口”：
- 正常库存保留；
- 达到上限后，后续新增直接丢弃；
- 如果正常消耗让库存降到恢复线，自动停止丢弃。

策略现在是“两层”而不是单一枚举
-------------------------------
第一层：后台加工
- TARGET：请求器需求，绝对最高优先级。
- AUTO：达到高阈值后送矿处，一直加工到低阈值。
- IGNORE：不做后台加工。

第二层：OVERFLOW
- 可独立于 AUTO / IGNORE 开启。
- TARGET 永远覆盖 OVERFLOW，任何 TARGET 原矿绝不进入垃圾总线。
- AUTO + OVERFLOW 可以同时配置：
  AUTO 负责正常消化，OVERFLOW 只作为极端爆仓保险。

示例
----
Lead:
  AUTO 100M -> 10M
  OVERFLOW 500M / 450M

含义：
- 100M 以上优先利用空闲矿处加工；
- 如果矿处长期跟不上，缓存甚至涨到 500M，
  后续新铅矿直接走垃圾总线；
- 已有 500M 不会被主动清空；
- 正常消耗让库存降到 450M 后，垃圾总线解除铅矿过滤。

Lepidolite:
  IGNORE
  OVERFLOW 100M / 80M

含义：
- 不浪费矿处吞吐；
- 前约 100M 正常保留；
- 之后新增直接丢弃；
- 如果未来真正消耗到 80M，重新允许储存。

硬件
----
原矿缓存 AE
  |
  +-- PROCESS Storage Bus -> 矿处
  |
  +-- OVERFLOW Storage Bus -> 垃圾桶 / 无限销毁库存

OVERFLOW Storage Bus 必须：
- AE 优先级高于正常原矿存储；
- 通过 OC Adapter/网络让当前电脑能看到 `me_storagebus`；
- 最后一格手工放永久占位符。

最后一格规则
------------
对所有 OC 管理的 Storage Bus：

- GUI 最后一格永久保留；
- OC 永不写、永不清、永不把它算作任务槽；
- 你手工放占位符即可。

63 格 Storage Bus：
- GUI 1~62：最多可动态使用；
- GUI 63：永久占位符。

兼容旧配置
----------
PROCESS 总线仍兼容旧字段：

storageBusAddress
storageSide
managedSlots

新字段优先：

processStorageBusAddress
processStorageSide
processManagedSlots

OVERFLOW 必须明确配置：

overflowStorageBusAddress
overflowStorageSide
overflowManagedSlots

旧 v0.6 的 VOID
---------------
v0.6 的 VOID 从未真正销毁物品。

v0.7 不会把旧 VOID 自动变成活跃销毁。
旧 VOID 会安全迁移为：
- 后台加工 IGNORE
- OVERFLOW OFF

必须由用户在 UI 中重新明确开启 OVERFLOW。

命令
----
启动：
  ore

更新：
  ore-update

只读列出所有 Storage Bus：
  ore-probe-buses

当前 RC 限制
-------------
1. OVERFLOW Storage Bus -> 垃圾桶 的实际“新物品优先流入并销毁”行为
   仍需要在你的 GTNH 2.9.x 实机做一次小量测试。
2. OC 突然断电时，已经写在 OVERFLOW Bus 上的动态过滤不会被软件主动清掉。
   正常点击退出、程序捕获到错误时会尽力清空动态过滤。
3. 本版没有主动 PURGE 旧库存功能。


RC2：TARGET 从余矿页隐藏
-----------------------
底层仍扫描全部原矿，因为 TARGET 保护、OreDictionary 映射与 OVERFLOW 清理都需要完整数据。

但“余矿策略管理”页面只显示非 TARGET：

- 成为 TARGET：立即从余矿页面隐藏；
- TARGET 期间：OVERFLOW 强制关闭；
- 原有 AUTO / IGNORE / OVERFLOW 配置继续保留；
- 请求器取消 TARGET：材料自动重新出现在余矿页面；
- “余矿矿种 / 余矿总量”只统计非 TARGET 原矿。
