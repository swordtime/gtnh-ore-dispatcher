-- GTNH Ore Dispatch Controller v0.6.1-stable
-- 用户策略文件。复制到 /home/ore_dispatch_user.lua
-- updater 应当永远保留此文件，不覆盖用户设置。

return {
    -- 总开关：false 时 AUTO 任务全部暂停；已在排空的滞回状态会保留，重新开启后继续。
    autoSurplusEnabled = false,

    -- 未被请求器 TARGET 覆盖、且没有单矿设置时的默认策略。
    -- 安全规则：这里只允许 AUTO / IGNORE；VOID 必须在单矿 materials 表中显式设置。
    -- AUTO   = 达到高阈值后送矿处，直到低阈值
    -- IGNORE = 不自动处理
    -- VOID   = 只能逐矿显式设置；当前仍不执行真实销毁
    defaultPolicy = "AUTO",

    -- 默认 AUTO 滞回：100M 开始，10M 停止。
    surplusHigh = 100000000,
    surplusLow = 10000000,

    -- AUTO 最多占用多少个剩余活动槽。
    -- TARGET 永远优先，并且总活动数量仍受 ore_dispatch_config.lua 的 maxActive 限制。
    maxSurplusActive = 4,

    -- 真实销毁的全局硬开关。
    -- v0.6.1-stable 尚未接入 Export Bus，因此即使改 true 也不会销毁物品；
    -- 先保留这个字段，未来接入 VOID 时必须同时满足“单矿显式 VOID + 此开关 ON”。
    voidEnabled = false,

    -- 未来 VOID 最多允许同时销毁的矿种数。先锁死为保守值 1。
    maxVoidActive = 1,

    names = {
        -- 主目标页面显示名。key 是内部 item name:damage。
        items = {
            -- ["gregtech:gt.metaitem.01:2500"] = "钡粉",
        },

        -- 缓存页面显示名。key 是规范化材料名，例如 barium / lead / arsenic。
        materials = {
            -- barium = "钡矿",
            -- lead = "铅矿",
        },
    },

    -- 单矿策略覆盖。没有写的矿继承上面的默认值。
    materials = {
        -- lead = {
        --     policy = "AUTO",
        --     high = 100000000,
        --     low = 10000000,
        -- },
        --
        -- lepidolite = {
        --     policy = "IGNORE",
        -- },
        --
        -- 某矿以后若设为 VOID，v0.6 只会显示“销毁未启用”，不会真的丢物品。
    },
}
