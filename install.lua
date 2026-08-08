-- GTNH Ore Dispatcher installer v0.6.1-stable
local component = require("component")
local filesystem = require("filesystem")
local os = require("os")

local RAW_BASE = "https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/"

local function ensureParent(path)
    local parent = filesystem.path(path)

    if parent and parent ~= "" and not filesystem.exists(parent) then
        local ok, err = filesystem.makeDirectory(parent)

        if not ok and not filesystem.exists(parent) then
            return nil, err
        end
    end

    return true
end

local function download(url, path)
    local ok, err = ensureParent(path)
    if not ok then return nil, err end

    if filesystem.exists(path) then
        filesystem.remove(path)
    end

    local result = os.execute(
        string.format('wget -f "%s" "%s"', url, path)
    )

    if not result or not filesystem.exists(path) then
        return nil, "wget 失败: " .. url
    end

    return true
end

local function installIfMissing(remote, localPath)
    if filesystem.exists(localPath) then
        print("保留已有本地配置: " .. localPath)
        return true
    end

    return download(RAW_BASE .. remote, localPath)
end

if not component.isAvailable("internet") then
    error("未检测到 Internet Card，无法联网安装")
end

print("GTNH Ore Dispatcher Installer v0.6.1-stable")

local ok, err =
    download(RAW_BASE .. "ore_update.lua", "/bin/ore-update.lua")

if not ok then error(err) end

ok, err = installIfMissing(
    "ore_dispatch_config.example.lua",
    "/home/ore_dispatch_config.lua"
)

if not ok then error(err) end

ok, err = installIfMissing(
    "ore_dispatch_overrides.example.lua",
    "/home/ore_dispatch_overrides.lua"
)

if not ok then error(err) end

ok, err = installIfMissing(
    "ore_dispatch_user.example.lua",
    "/home/ore_dispatch_user.lua"
)

if not ok then error(err) end

local updater, loadErr = loadfile("/bin/ore-update.lua")
if not updater then error(loadErr) end

local runOk, runResult = pcall(updater, "--force")
if not runOk then error(runResult) end

print("安装完成。")
print("编辑: /home/ore_dispatch_config.lua")
print("启动程序: ore")
print("以后升级: ore-update")
print("Export Bus 只读探测: ore-probe-export")

return true
