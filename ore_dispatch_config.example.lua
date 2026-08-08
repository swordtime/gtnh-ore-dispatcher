return {
    -- ============================================================
    -- GTNH Ore Dispatcher v0.4.1
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
