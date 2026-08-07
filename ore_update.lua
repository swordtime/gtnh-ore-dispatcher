-- GTNH Ore Dispatcher updater
-- Repository: https://github.com/swordtime/gtnh-ore-dispatcher

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
    if a == "--force" or a == "-f" then force = true end
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
        if not ok and not filesystem.exists(parent) then return nil, err end
    end
    return true
end

local function download(url, path)
    ensureParent(path)
    if filesystem.exists(path) then filesystem.remove(path) end
    local cmd = string.format('wget -f "%s" "%s"', url, path)
    local ok = os.execute(cmd)
    if not ok or not filesystem.exists(path) then
        return nil, "wget 失败: " .. url
    end
    return true
end

local function loadTable(path)
    local fn, err = loadfile(path)
    if not fn then return nil, err end
    local ok, data = pcall(fn)
    if not ok then return nil, data end
    if type(data) ~= "table" then return nil, "manifest 没有 return table" end
    return data
end

if not component.isAvailable("internet") then
    io.stderr:write("未检测到 Internet Card，无法联网更新。\n")
    return false
end

print("GTNH Ore Dispatcher Updater")
print("正在读取远端 manifest...")
local ok, err = download(MANIFEST_URL, TMP_MANIFEST)
if not ok then error(err) end

local manifest, mErr = loadTable(TMP_MANIFEST)
if not manifest then error("manifest 读取失败: " .. tostring(mErr)) end
if type(manifest.version) ~= "string" or type(manifest.files) ~= "table" then
    error("manifest 格式错误")
end

local localVersion = readFirstLine(VERSION_FILE) or "未安装"
print("本地版本: " .. localVersion)
print("远端版本: " .. manifest.version)

if not force and localVersion == manifest.version then
    print("已经是最新版本。")
    return true
end

local base = manifest.rawBase or RAW_BASE
local staged = {}

print("正在下载更新文件...")
for _, entry in ipairs(manifest.files) do
    if type(entry.remote) ~= "string" or type(entry.localPath) ~= "string" then
        error("manifest.files 项格式错误")
    end
    local stage = entry.localPath .. ".new"
    local dOk, dErr = download(base .. entry.remote, stage)
    if not dOk then
        for _, s in ipairs(staged) do if filesystem.exists(s.stage) then filesystem.remove(s.stage) end end
        error(dErr)
    end
    table.insert(staged, {target=entry.localPath, stage=stage, backup=entry.localPath .. ".bak"})
    print("  OK  " .. entry.remote)
end

print("正在安装...")
local committed = {}
local function rollback()
    for i = #committed, 1, -1 do
        local e = committed[i]
        if filesystem.exists(e.target) then filesystem.remove(e.target) end
        if filesystem.exists(e.backup) then filesystem.rename(e.backup, e.target) end
    end
    for _, e in ipairs(staged) do if filesystem.exists(e.stage) then filesystem.remove(e.stage) end end
end

for _, e in ipairs(staged) do
    ensureParent(e.target)
    if filesystem.exists(e.backup) then filesystem.remove(e.backup) end
    if filesystem.exists(e.target) then
        local bOk, bErr = filesystem.rename(e.target, e.backup)
        if not bOk then rollback(); error("备份失败 " .. e.target .. ": " .. tostring(bErr)) end
    end
    local rOk, rErr = filesystem.rename(e.stage, e.target)
    if not rOk then
        if filesystem.exists(e.backup) then filesystem.rename(e.backup, e.target) end
        rollback()
        error("安装失败 " .. e.target .. ": " .. tostring(rErr))
    end
    table.insert(committed, e)
end

local vOk, vErr = writeText(VERSION_FILE, manifest.version .. "\n")
if not vOk then
    rollback()
    error("写版本文件失败: " .. tostring(vErr))
end

print("更新完成: " .. localVersion .. " -> " .. manifest.version)
print("本地配置与 overrides 未被覆盖。")
return true
