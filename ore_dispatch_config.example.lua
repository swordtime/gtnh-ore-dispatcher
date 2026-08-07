return {
    -- =========================
    -- 硬件地址
    -- =========================
    -- GTNH 2.9 下你的二合一 ME 接口表现为 fluid_interface。
    -- 当 OC 同时连接主网与原矿缓存网时，两者类型相同，因此建议固定 UUID。
    mainMeAddress = nil,   -- 主网：读取目标矿粉/宝石库存
    cacheMeAddress = nil,  -- 原矿缓存网：扫描可供处理的原矿

    -- 若只有一个 me_storagebus，可以留 nil 自动识别。
    storageBusAddress = nil,

    -- 已实测你的当前存储总线位于 side=2；留 nil 时程序会自动扫描 0~5。
    storageSide = nil,

    -- =========================
    -- 调度参数
    -- =========================
    controlInterval = 3,   -- 秒；每轮重新读取库存、计算并刷新白名单

    -- 滞回：未在处理时，低于目标的 95% 才重新开启；一旦开启，达到 100% 才关闭。
    -- 若想“只要不足 100% 就立即处理”，把 reopenRatio 改成 1.0。
    reopenRatio = 0.95,
    stopRatio = 1.00,

    -- 同时开放给集成矿处的最大矿种数量。
    -- 你的存储总线加容量卡后可达 63 槽，但不建议一开始就全部开放。
    maxActive = 12,

    -- 本程序只管理存储总线前 N 个过滤槽；其余槽不会碰。
    -- 设成 nil 表示使用当前存储总线全部可用槽位。
    managedSlots = 16,

    -- =========================
    -- 安全 / UI
    -- =========================
    -- 第一次试运行建议 true：只计算，不写 Storage Bus。
    -- 完成实机检查后改 false。
    dryRun = true,

    enableUI = true,
    progressBarWidth = 18,
    uiSort = "ratio", -- ratio = 最缺的放最上面；name = 按名称

    -- 请求器：扫描所有连接到本 OC 的 level_maintainer，每个读 1~5 槽。
    requesterSlots = 5,

    -- 例外映射文件。主程序不需要因为奇葩矿物而修改。
    overrideFile = "/home/ore_dispatch_overrides.lua",
}
