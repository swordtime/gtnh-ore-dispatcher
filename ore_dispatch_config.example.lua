return {
    -- ============================================================
    -- GTNH Ore Dispatcher v0.7.0-rc2
    -- ============================================================

    -- 【必须填写】
    productMeAddress = nil,
    cacheMeAddress = nil,

    -- ============================================================
    -- PROCESS Storage Bus
    -- ============================================================
    -- 兼容旧配置：
    -- storageBusAddress / storageSide / managedSlots 仍然有效。
    --
    -- 一旦你接入第二根 OVERFLOW Storage Bus，建议明确填 UUID。
    processStorageBusAddress = nil,
    processStorageSide = nil,
    processManagedSlots = 16,

    -- ============================================================
    -- OVERFLOW Storage Bus
    -- ============================================================
    -- 专门贴在垃圾桶/无限吞吐销毁库存上。
    -- 必须把这根 Storage Bus 的 AE 优先级手工设得高于正常原矿存储。
    --
    -- nil = 不启用硬件，只保留 UI/策略。
    overflowStorageBusAddress = nil,
    overflowStorageSide = nil,
    overflowManagedSlots = 16,

    -- ============================================================
    -- 最后一格硬件约定
    -- ============================================================
    -- 对所有由 OC 控制的 Storage Bus：
    --
    -- GUI 最后一格永远由你手工放一个占位符。
    -- OC 永远不会写、清空或把最后一格当任务槽使用。
    --
    -- 63 格总线：
    -- GUI 1~62 = 最多可由 OC 使用
    -- GUI 63   = 永久保留，占位符

    -- 调度
    controlInterval = 3,
    reopenRatio = 0.95,
    stopRatio = 1.00,
    maxActive = 12,

    -- 旧字段兼容。新配置优先使用 processManagedSlots。
    managedSlots = 16,

    -- 安全测试时保持 true。
    dryRun = true,

    -- UI
    enableUI = true,
    uiUseMaxResolution = true,
    uiSort = "ratio",
    progressBarWidth = 24,

    -- 请求器
    requesterSlots = 5,

    -- 特殊矿物映射
    overrideFile = "/home/ore_dispatch_overrides.lua",
}
