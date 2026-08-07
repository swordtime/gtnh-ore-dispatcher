-- GTNH Ore Dispatcher manifest
-- Repository: https://github.com/swordtime/gtnh-ore-dispatcher
return {
    version = "0.3.1",
    rawBase = "https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/",
    files = {
        -- 程序文件：允许自动升级
        { remote = "ore_dispatcher.lua", localPath = "/home/ore_dispatcher.lua" },
        { remote = "ore_update.lua",     localPath = "/bin/ore-update.lua" },

        -- 示例配置：会随版本更新，但绝不覆盖真正的本地配置
        { remote = "ore_dispatch_config.example.lua",    localPath = "/home/ore_dispatch_config.example.lua" },
        { remote = "ore_dispatch_overrides.example.lua", localPath = "/home/ore_dispatch_overrides.example.lua" },
    },
}
