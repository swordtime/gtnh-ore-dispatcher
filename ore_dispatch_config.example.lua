return {
    -- ============================================================
    -- GTNH Ore Dispatcher v0.6.1-stable
    -- ============================================================

    -- 【必须填写】
    productMeAddress = nil,
    cacheMeAddress = nil,

    -- 留 nil 自动识别
    storageBusAddress = nil,
    storageSide = nil,

    -- 调度
    controlInterval = 3,
    reopenRatio = 0.95,
    stopRatio = 1.00,
    maxActive = 12,
    managedSlots = 16,

    -- Storage Bus 安全哨兵：默认最后一格。
    -- 63 格总线 => API slot 62 / GUI 第63格。
    -- 这一格必须永久放一个不会出现在原矿缓存网中的占位物。
    requireSentinel = true,
    sentinelSlot = -1,

    -- 安全
    dryRun = true,

    -- UI
    enableUI = true,

    -- v0.4 默认尽可能使用 GPU/屏幕最大分辨率。
    -- 如果你以后发现超大屏刷新开销明显，可改 false。
    uiUseMaxResolution = true,

    -- ratio = 最缺的排最上面
    -- name  = 按名称排序
    uiSort = "ratio",

    -- 仅供低配/黑白屏 fallback 使用；高级 UI 的绿色条会自动吃满可用宽度。
    progressBarWidth = 24,

    -- 请求器
    requesterSlots = 5,

    -- 特殊矿物映射
    overrideFile = "/home/ore_dispatch_overrides.lua",
}
