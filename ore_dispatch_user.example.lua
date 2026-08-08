-- GTNH Ore Dispatch Controller v0.7.0-rc1
-- 用户策略文件。实际文件：/home/ore_dispatch_user.lua
-- updater 永远不覆盖实际用户文件。

return {
    -- ============================================================
    -- 后台加工 AUTO
    -- ============================================================
    autoSurplusEnabled = false,

    -- 未被 TARGET 覆盖、且没有单矿设置时：
    -- AUTO   = 超量时送矿处
    -- IGNORE = 不做后台加工
    defaultPolicy = "AUTO",

    -- 默认 AUTO：100M 开始加工，持续到 10M。
    surplusHigh = 100000000,
    surplusLow = 10000000,
    maxSurplusActive = 4,

    -- ============================================================
    -- OVERFLOW 溢流保护
    -- ============================================================
    -- 总开关默认 OFF。
    -- OVERFLOW 不是主动清库：
    -- 达到上限后，OC 把该矿写入专用高优先级垃圾 Storage Bus，
    -- 后续新进入 AE 的该矿会直接销毁。
    overflowEnabled = false,

    -- 默认 100M 开始拦截；库存因正常消耗降到 80M 后解除拦截。
    overflowHigh = 100000000,
    overflowLow = 80000000,
    maxOverflowActive = 16,

    names = {
        items = {
            -- ["gregtech:gt.metaitem.01:2500"] = "钡粉",
        },

        materials = {
            -- barium = "钡矿",
            -- lead = "铅矿",
        },
    },

    materials = {
        -- 例 1：铅有用，优先 AUTO 加工；
        -- 如果矿处长期跟不上、库存极端膨胀到 500M，
        -- 同时允许 OVERFLOW 拦截后续新增。
        --
        -- lead = {
        --     policy = "AUTO",
        --     high = 100000000,
        --     low = 10000000,
        --
        --     overflow = true,
        --     overflowHigh = 500000000,
        --     overflowLow = 450000000,
        -- },

        -- 例 2：锂云母暂时不想加工，但也不想无限增长。
        --
        -- lepidolite = {
        --     policy = "IGNORE",
        --
        --     overflow = true,
        --     overflowHigh = 100000000,
        --     overflowLow = 80000000,
        -- },
    },
}
