-- GTNH Ore Dispatcher installer
-- Repository: https://github.com/swordtime/gtnh-ore-dispatcher

local component = require("component")
local filesystem = require("filesystem")
local os = require("os")

local RAW_BASE = "https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/"

local function ensureParent(path)
    local parent = filesystem.path(path)
    if parent and parent ~= "" and not filesystem.exists(parent) then
        filesystem.makeDirectory(parent)
    end
end

local function download(url, path)
    ensureParent(path)
    if filesystem.exists(path) then filesystem.remove(path) end
    local ok = os.execute(string.format('wget -f "%s" "%s"', url, path))
    return ok and filesystem.exists(path)
end

local function installIfMissing(remote, localPath)
    if filesystem.exists(localPath) then
        print("保留已有配置: " .. localPath)
        return true
    end
    print("创建: " .. localPath)
    return download(RAW_BASE .. remote, localPath)
end

if not component.isAvailable("internet") then
    error("未检测到 Internet Card")
end

print("GTNH Ore Dispatcher Installer")
print("仓库: swordtime/gtnh-ore-dispatcher")

if not download(RAW_BASE .. "ore_update.lua", "/bin/ore-update.lua") then
    error("无法安装 /bin/ore-update.lua")
end

if not installIfMissing("ore_dispatch_config.example.lua", "/home/ore_dispatch_config.lua") then
    error("无法创建 ore_dispatch_config.lua")
end
if not installIfMissing("ore_dispatch_overrides.example.lua", "/home/ore_dispatch_overrides.lua") then
    error("无法创建 ore_dispatch_overrides.lua")
end

local updater, err = loadfile("/bin/ore-update.lua")
if not updater then error(err) end
local ok, result = pcall(updater, "--force")
if not ok then error(result) end

print("\n安装完成。")
print("下一步编辑: /home/ore_dispatch_config.lua")
print("以后升级只需运行: ore-update")
return true
