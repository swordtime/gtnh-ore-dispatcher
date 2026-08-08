GTNH Ore Dispatch Controller v0.6.0 — Cache Policy
====================================================

本版目标
--------
把 v0.5.0 的“只处理请求器目标”升级为完整的原矿缓存策略层。

策略模型
--------
TARGET  请求器明确需要的材料。最高优先级。
AUTO    未标记伴生矿达到高阈值后自动送矿处，开始后持续排到低阈值。
IGNORE  不自动处理。
VOID    v0.6.0 只预留配置和 UI；不会执行销毁。

默认 AUTO 滞回
---------------
100M -> 10M

库存 >= 100M：开始 AUTO 排空。
10M < 库存 < 100M：保持之前状态。
库存 <= 10M：停止 AUTO 排空。

AUTO 状态保存在：
/home/ore_dispatch_state.lua

因此例如 Lead Ore 已从 130M 排到 60M 时 OC 重启，重启后会继续排到 10M，
而不会因为 60M < 100M 就中途停止。

优先级
------
TARGET > AUTO

现有 ore_dispatch_config.lua 中 maxActive 仍然是总活动上限。
TARGET 先占槽；AUTO 只使用剩余活动槽，并额外受到 maxSurplusActive 限制。

安装 / 升级
-----------
1. 保留现有：
   /home/ore_dispatch_config.lua
   /home/ore_dispatch_overrides.lua

2. 将新版 ore_dispatcher.lua 放到：
   /home/ore_dispatcher.lua

3. 第一次使用 v0.6 时，将 ore_dispatch_user.lua 放到：
   /home/ore_dispatch_user.lua

   如果没有放，程序也会自动生成一个安全默认文件：
   autoSurplusEnabled = false

4. 启动：
   ore
   或
   lua /home/ore_dispatcher.lua

界面
----
主页面：
- 点击目标产物行即可选中。
- 选中后 [命名] 启用。
- [缓存] 打开全矿物缓存页。
- [退出] 返回 OpenOS。

缓存页：
- 展示缓存网全部识别到的 oreXxx 原矿材料。
- 点击矿物行选中。
- [命名]：修改此材料的 UI 显示名。
- [策略]：AUTO / IGNORE / VOID(预留)，以及单矿高低阈值。
- [返回]：回主页面。
- 左上“余矿自动 ON/OFF”是全局 AUTO 开关。

命名
----
命名只影响 UI，不修改真实物品 ID、damage、OreDictionary 或 Storage Bus 识别。
输入 “-” 可清除自定义名称。

安全边界
--------
1. v0.6.0 没有任何真实销毁代码。
2. VOID 即使被设置，也只显示“销毁未启用”，等 v0.6.1 实测 me_exportbus 后再接。
3. TARGET 永远覆盖 AUTO / IGNORE / VOID，避免需求矿被后台策略抢占。
4. AUTO 默认总开关为 OFF，升级不会突然处理过去未标记的矿。
5. 用户策略与运行状态独立于主程序，后续 updater 不应覆盖它们。

已知待实机验证点
----------------
1. OpenOS 的 io.read() 对你当前中文输入法是否能直接输入中文。
   如果中文输入不方便，可直接编辑 /home/ore_dispatch_user.lua 的 names 表。
2. 同一材料如果存在多个不同 item/damage 原矿变体，本程序每轮优先开放库存量最大的变体；
   该变体消耗后下一轮会自动切换到新的最大变体。需要观察实机吞吐是否符合预期。
3. v0.6.1 自动销毁前，必须实测 GTNH 2.9.x 中 me_exportbus 的实际方法表和 export 行为。

建议第一轮测试
--------------
A. 先保持 autoSurplusEnabled=false 启动，确认现有 TARGET 行为与 v0.5 一致。
B. 进入缓存页，确认 Barium / Lead / Arsenic 等伴生矿都能显示。
C. 点击 Lead，策略设 AUTO，阈值先用较小测试值验证滞回。
D. 打开“余矿自动 ON”，确认 TARGET 先占槽，AUTO 只占剩余槽。
E. 关闭并重启程序，确认正在 AUTO 排空的材料继续运行到低阈值。
F. 最后再把真实阈值改为 100M / 10M。
