return {
    version = "0.6.1-stable",
    rawBase = "https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/",
    files = {
        { remote = "ore_dispatcher.lua", localPath = "/home/ore_dispatcher.lua" },
        { remote = "ore_update.lua", localPath = "/bin/ore-update.lua" },
        { remote = "ore.lua", localPath = "/bin/ore.lua" },
        { remote = "ore-probe-export.lua", localPath = "/bin/ore-probe-export.lua" },
        { remote = "ore_dispatch_config.example.lua", localPath = "/home/ore_dispatch_config.example.lua" },
        { remote = "ore_dispatch_overrides.example.lua", localPath = "/home/ore_dispatch_overrides.example.lua" },
        { remote = "ore_dispatch_user.example.lua", localPath = "/home/ore_dispatch_user.example.lua" },
    },
}
