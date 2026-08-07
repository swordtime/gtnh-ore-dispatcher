-- GTNH Ore Dispatcher installer v0.3.2
-- Repository: https://github.com/swordtime/gtnh-ore-dispatcher

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

    local result = os.execute(string.format('wget -f "%s" "%s"', url, path))
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

    print("创建本地配置: " .. localPath)
    return download(RAW_BASE .. remote, localPath)
end

if not component.isAvailable("internet") then
    error("未检测到 Internet Card，无法联网安装")
end

print("==============================================")
print("GTNH Ore Dispatcher Installer v0.3.2")
print("Repository: swordtime/gtnh-ore-dispatcher")
print("==============================================")

-- 先安装更新器
local ok, err = download(RAW_BASE .. "ore_update.lua", "/bin/ore-update.lua")
if not ok then
    error("无法安装 /bin/ore-update.lua: " .. tostring(err))
end

-- 本地用户配置只在不存在时创建
ok, err = installIfMissing(
    "ore_dispatch_config.example.lua",
    "/home/ore_dispatch_config.lua"
)
if not ok then error("无法创建 ore_dispatch_config.lua: " .. tostring(err)) end

ok, err = installIfMissing(
    "ore_dispatch_overrides.example.lua",
    "/home/ore_dispatch_overrides.lua"
)
if not ok then error("无法创建 ore_dispatch_overrides.lua: " .. tostring(err)) end

-- 调用更新器安装程序文件与最新版 example
local updater, loadErr = loadfile("/bin/ore-update.lua")
if not updater then error(loadErr) end

local runOk, runResult = pcall(updater, "--force")
if not runOk then
    error(runResult)
end

print("")
print("安装完成。")
print("下一步：")
print("  edit /home/ore_dispatch_config.lua")
print("")
print("必须填写：")
print("  productMeAddress = 成品网二合一接口 UUID")
print("  cacheMeAddress   = 原矿缓存网二合一接口 UUID")
print("")
print("首次测试请保持 dryRun = true")
print("以后升级只需运行: ore-update")
return true
