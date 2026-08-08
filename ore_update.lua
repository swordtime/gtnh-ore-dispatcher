-- GTNH Ore Dispatcher updater v0.5.0
local component = require("component")
local filesystem = require("filesystem")
local os = require("os")

local RAW_BASE = "https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/"
local MANIFEST_URL = RAW_BASE .. "manifest.lua"
local VERSION_FILE = "/home/.ore_dispatcher_version"
local TMP_MANIFEST = "/tmp/ore_dispatch_manifest.lua"

local args = {...}
local force = false

for _, a in ipairs(args) do
    if a == "--force" or a == "-f" then
        force = true
    end
end

local function readFirstLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function writeText(path, text)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(text)
    f:close()
    return true
end

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

local function loadTable(path)
    local fn, err = loadfile(path)
    if not fn then return nil, err end

    local ok, data = pcall(fn)
    if not ok then return nil, data end

    if type(data) ~= "table" then
        return nil, "manifest 没有 return table"
    end

    return data
end

local function removeIfExists(path)
    if filesystem.exists(path) then
        filesystem.remove(path)
    end
end

if not component.isAvailable("internet") then
    io.stderr:write("未检测到 Internet Card，无法联网更新。\n")
    return false
end

print("GTNH Ore Dispatcher Updater")

local ok, err = download(MANIFEST_URL, TMP_MANIFEST)
if not ok then error(err) end

local manifestData, manifestErr = loadTable(TMP_MANIFEST)
if not manifestData then
    error("manifest 读取失败: " .. tostring(manifestErr))
end

local localVersion = readFirstLine(VERSION_FILE) or "未安装"

print("本地版本: " .. localVersion)
print("远端版本: " .. tostring(manifestData.version))

if not force and localVersion == manifestData.version then
    print("已经是最新版本。")
    return true
end

local base = manifestData.rawBase or RAW_BASE
local staged = {}

for _, entry in ipairs(manifestData.files or {}) do
    local stage = entry.localPath .. ".new"

    local downloadOk, downloadErr =
        download(base .. entry.remote, stage)

    if not downloadOk then
        for _, s in ipairs(staged) do
            removeIfExists(s.stage)
        end
        error(downloadErr)
    end

    table.insert(staged, {
        target = entry.localPath,
        stage = stage,
        backup = entry.localPath .. ".bak",
    })

    print("  OK  " .. entry.remote)
end

local committed = {}

local function rollback()
    for i = #committed, 1, -1 do
        local e = committed[i]

        removeIfExists(e.target)

        if filesystem.exists(e.backup) then
            filesystem.rename(e.backup, e.target)
        end
    end

    for _, e in ipairs(staged) do
        removeIfExists(e.stage)
    end
end

for _, e in ipairs(staged) do
    local parentOk, parentErr = ensureParent(e.target)

    if not parentOk then
        rollback()
        error("创建目录失败: " .. tostring(parentErr))
    end

    removeIfExists(e.backup)

    if filesystem.exists(e.target) then
        local backupOk, backupErr =
            filesystem.rename(e.target, e.backup)

        if not backupOk then
            rollback()
            error("备份失败 " .. e.target .. ": " .. tostring(backupErr))
        end
    end

    local installOk, installErr =
        filesystem.rename(e.stage, e.target)

    if not installOk then
        if filesystem.exists(e.backup) then
            filesystem.rename(e.backup, e.target)
        end

        rollback()
        error("安装失败 " .. e.target .. ": " .. tostring(installErr))
    end

    table.insert(committed, e)
end

local versionOk, versionErr =
    writeText(VERSION_FILE, tostring(manifestData.version) .. "\n")

if not versionOk then
    rollback()
    error("写版本文件失败: " .. tostring(versionErr))
end

print("更新完成: " .. localVersion .. " -> " .. tostring(manifestData.version))
print("本地 ore_dispatch_config.lua / overrides 不会被覆盖。")

return true
