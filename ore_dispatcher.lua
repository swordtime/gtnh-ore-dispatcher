-- GTNH 2.9 / OpenComputers
-- GTNH Ore Dispatch Controller
-- Release v0.7.0-rc2 - Dual Bus Overflow
--
-- v0.7.0-rc2:
--   - 双 Storage Bus：PROCESS + OVERFLOW
--   - TARGET / AUTO 继续使用 PROCESS Bus
--   - OVERFLOW 使用独立高优先级垃圾 Storage Bus 拦截后续新增
--   - AUTO 与 OVERFLOW 改为两层独立策略，可同时启用
--   - TARGET 永远覆盖并关闭同材料 OVERFLOW
--   - OVERFLOW 采用独立高/低阈值滞回，默认 100M / 80M
--   - v0.6 旧 VOID 安全迁移为 IGNORE + OVERFLOW OFF
--   - 每根受控 Storage Bus 的 GUI 最后一格永久保留，OC 永不触碰
--   - 正常退出/捕获错误时尽力清空两根总线的动态过滤
--   - 新增 ore-probe-buses 只读硬件识别工具
--
-- Existing /home/ore_dispatch_config.lua remains compatible for PROCESS.

local component = require("component")
local os = require("os")
local term = require("term")
local event = require("event")
local computer = require("computer")
local serialization = require("serialization")
local filesystem = require("filesystem")

local VERSION = "0.7.0-rc2"

local CONFIG_PATH = "/home/ore_dispatch_config.lua"
local FALLBACK_CONFIG_PATH = "ore_dispatch_config.lua"
local USER_PATH = "/home/ore_dispatch_user.lua"
local FALLBACK_USER_PATH = "ore_dispatch_user.lua"
local STATE_PATH = "/home/ore_dispatch_state.lua"

-- ============================================================
-- Generic table / file helpers
-- ============================================================

local function loadLuaTable(path)
    local fn, err = loadfile(path)
    if not fn then return nil, err end

    local ok, data = pcall(fn)
    if not ok then return nil, data end

    if type(data) ~= "table" then
        return nil, "配置文件必须 return table"
    end

    return data
end

local function fileExists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function writeLuaTable(path, data, makeBackup)
    local tmp = path .. ".tmp"
    local bak = path .. ".bak"

    local f, err = io.open(tmp, "w")
    if not f then
        return nil, "无法写入临时文件: " .. tostring(err)
    end

    local okSerialize, serialized = pcall(serialization.serialize, data)
    if not okSerialize then
        f:close()
        pcall(filesystem.remove, tmp)
        return nil, "序列化失败: " .. tostring(serialized)
    end

    f:write("return ", serialized, "\n")
    f:close()

    local hadOriginal = filesystem.exists(path)

    if makeBackup and hadOriginal then
        pcall(filesystem.remove, bak)
        local okBak, bakErr = filesystem.rename(path, bak)
        if not okBak then
            pcall(filesystem.remove, tmp)
            return nil, "创建备份失败: " .. tostring(bakErr)
        end
    elseif hadOriginal then
        local okRemove, removeErr = filesystem.remove(path)
        if not okRemove then
            pcall(filesystem.remove, tmp)
            return nil, "替换旧文件失败: " .. tostring(removeErr)
        end
    end

    local okRename, renameErr = filesystem.rename(tmp, path)
    if not okRename then
        pcall(filesystem.remove, tmp)

        if makeBackup and filesystem.exists(bak) and not filesystem.exists(path) then
            pcall(filesystem.rename, bak, path)
        end

        return nil, "提交配置失败: " .. tostring(renameErr)
    end

    return true
end

-- ============================================================
-- Main config
-- ============================================================

local CFG = nil
local loadedConfigPath = nil

for _, path in ipairs({CONFIG_PATH, FALLBACK_CONFIG_PATH}) do
    local data = loadLuaTable(path)
    if data then
        CFG = data
        loadedConfigPath = path
        break
    end
end

if not CFG then
    error("无法读取 ore_dispatch_config.lua；请放在 /home 或当前目录")
end

local DEFAULT_USER = {
    -- Background processing layer.
    autoSurplusEnabled = false,
    defaultPolicy = "AUTO",
    surplusHigh = 100000000,
    surplusLow = 10000000,
    maxSurplusActive = 4,

    -- Independent overflow guard.
    -- This does NOT purge old stock. It only opens the dedicated
    -- high-priority trash Storage Bus so NEW matching items are discarded.
    overflowEnabled = false,
    overflowHigh = 100000000,
    overflowLow = 80000000,
    maxOverflowActive = 16,

    names = {
        items = {},
        materials = {},
    },

    -- Per-material:
    -- policy = AUTO / IGNORE
    -- high / low = AUTO thresholds
    -- overflow = true / false
    -- overflowHigh / overflowLow = overflow guard thresholds
    materials = {},
}

local function normalizePolicy(policy)
    policy = tostring(policy or "AUTO"):upper()

    if policy == "AUTO" or policy == "IGNORE" then
        return policy
    end

    -- v0.6 compatibility:
    -- old VOID was never destructive. We migrate it to IGNORE rather than
    -- silently enabling any kind of destruction in a new release.
    if policy == "VOID" or policy == "OVERFLOW" then
        return "IGNORE"
    end

    return "AUTO"
end

local function normalizeUserConfig(data)
    data = type(data) == "table" and data or {}

    if data.autoSurplusEnabled == nil then
        data.autoSurplusEnabled = DEFAULT_USER.autoSurplusEnabled
    else
        data.autoSurplusEnabled = data.autoSurplusEnabled == true
    end

    if data.overflowEnabled == nil then
        data.overflowEnabled = DEFAULT_USER.overflowEnabled
    else
        data.overflowEnabled = data.overflowEnabled == true
    end

    data.defaultPolicy = normalizePolicy(
        data.defaultPolicy or DEFAULT_USER.defaultPolicy
    )

    data.surplusHigh =
        tonumber(data.surplusHigh) or DEFAULT_USER.surplusHigh
    data.surplusLow =
        tonumber(data.surplusLow) or DEFAULT_USER.surplusLow
    data.maxSurplusActive = math.floor(
        tonumber(data.maxSurplusActive)
        or DEFAULT_USER.maxSurplusActive
    )

    data.overflowHigh =
        tonumber(data.overflowHigh) or DEFAULT_USER.overflowHigh
    data.overflowLow =
        tonumber(data.overflowLow) or DEFAULT_USER.overflowLow
    data.maxOverflowActive = math.floor(
        tonumber(data.maxOverflowActive)
        or DEFAULT_USER.maxOverflowActive
    )

    if type(data.names) ~= "table" then data.names = {} end
    if type(data.names.items) ~= "table" then data.names.items = {} end
    if type(data.names.materials) ~= "table" then
        data.names.materials = {}
    end
    if type(data.materials) ~= "table" then data.materials = {} end

    for key, entry in pairs(data.materials) do
        if type(entry) ~= "table" then
            entry = {policy = entry}
            data.materials[key] = entry
        end

        local oldPolicy = tostring(
            entry.policy or data.defaultPolicy or "AUTO"
        ):upper()

        if oldPolicy == "VOID" then
            -- Preserve safety: do not turn legacy VOID into live overflow.
            entry.legacyVoid = true
        end

        entry.policy = normalizePolicy(oldPolicy)

        if entry.high ~= nil then entry.high = tonumber(entry.high) end
        if entry.low ~= nil then entry.low = tonumber(entry.low) end

        if entry.overflow == nil then
            entry.overflow = false
        else
            entry.overflow = entry.overflow == true
        end

        if entry.overflowHigh ~= nil then
            entry.overflowHigh = tonumber(entry.overflowHigh)
        end

        if entry.overflowLow ~= nil then
            entry.overflowLow = tonumber(entry.overflowLow)
        end
    end

    if data.surplusHigh <= 0 then
        error("ore_dispatch_user.lua: surplusHigh 必须 > 0")
    end

    if data.surplusLow < 0
       or data.surplusLow >= data.surplusHigh
    then
        error(
            "ore_dispatch_user.lua: "
            .. "必须满足 0 <= surplusLow < surplusHigh"
        )
    end

    if data.overflowHigh <= 0 then
        error("ore_dispatch_user.lua: overflowHigh 必须 > 0")
    end

    if data.overflowLow < 0
       or data.overflowLow >= data.overflowHigh
    then
        error(
            "ore_dispatch_user.lua: "
            .. "必须满足 0 <= overflowLow < overflowHigh"
        )
    end

    if data.maxSurplusActive < 0 then
        error(
            "ore_dispatch_user.lua: maxSurplusActive 必须 >= 0"
        )
    end

    if data.maxOverflowActive < 0 then
        error(
            "ore_dispatch_user.lua: maxOverflowActive 必须 >= 0"
        )
    end

    return data
end

local USER = nil
local loadedUserPath = nil

for _, path in ipairs({USER_PATH, FALLBACK_USER_PATH}) do
    local data = loadLuaTable(path)
    if data then
        USER = normalizeUserConfig(data)
        loadedUserPath = path
        break
    end
end

if not USER then
    USER = normalizeUserConfig({})
    local ok, err = writeLuaTable(USER_PATH, USER, false)
    if not ok then
        error("无法创建默认 ore_dispatch_user.lua: " .. tostring(err))
    end
    loadedUserPath = USER_PATH
end

local function saveUserConfig()
    local ok, err = writeLuaTable(USER_PATH, USER, true)
    if not ok then
        error("保存 ore_dispatch_user.lua 失败: " .. tostring(err))
    end
    loadedUserPath = USER_PATH
end

local RUNSTATE = {surplus = {}, overflow = {}}
local stateData, stateErr = loadLuaTable(STATE_PATH)
local startupWarning = nil

if stateData then
    RUNSTATE = stateData
    if type(RUNSTATE.surplus) ~= "table" then
        RUNSTATE.surplus = {}
    end
    if type(RUNSTATE.overflow) ~= "table" then
        RUNSTATE.overflow = {}
    end
elseif fileExists(STATE_PATH) then
    startupWarning = "状态文件损坏，已安全重置: " .. tostring(stateErr)
end

local function saveRunState()
    local ok, err = writeLuaTable(STATE_PATH, RUNSTATE, false)
    if not ok then
        error("保存运行状态失败: " .. tostring(err))
    end
end

-- ============================================================
-- Basic utilities
-- ============================================================

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function startsWith(s, prefix)
    return type(s) == "string" and s:sub(1, #prefix) == prefix
end

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeMaterial(s)
    if type(s) ~= "string" then return nil end
    s = s:lower()
    s = s:gsub("[%s%p_]", "")
    return s
end

local function itemId(item)
    if not item then return nil end
    return tostring(item.name) .. ":" .. tostring(item.damage or 0)
end

local function sameItem(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end

    return a.name == b.name
       and (a.damage or 0) == (b.damage or 0)
end

local function fmtAmount(n)
    n = tonumber(n) or 0
    local abs = math.abs(n)

    if abs >= 1000000000 then
        return string.format("%.2fG", n / 1000000000)
    elseif abs >= 1000000 then
        return string.format("%.2fM", n / 1000000)
    elseif abs >= 1000 then
        return string.format("%.1fk", n / 1000)
    end

    return tostring(math.floor(n))
end

local function parseAmount(text, fallback)
    text = trim(text)
    if text == "" then return fallback end

    local number, suffix = text:match("^([%+%-]?[%d%.]+)%s*([kKmMgGtT]?)$")
    if not number then return nil end

    local value = tonumber(number)
    if not value then return nil end

    suffix = suffix:upper()
    local multiplier = 1
    if suffix == "K" then multiplier = 1000
    elseif suffix == "M" then multiplier = 1000000
    elseif suffix == "G" then multiplier = 1000000000
    elseif suffix == "T" then multiplier = 1000000000000
    end

    return math.floor(value * multiplier + 0.5)
end

local function shortAddress(address)
    address = tostring(address or "?")
    if #address <= 13 then return address end
    return address:sub(1, 8) .. "..." .. address:sub(-4)
end

local function utf8Units(s)
    local units = {}
    local i = 1

    while i <= #s do
        local b = string.byte(s, i)
        local n = 1

        if b and b >= 240 then
            n = 4
        elseif b and b >= 224 then
            n = 3
        elseif b and b >= 192 then
            n = 2
        end

        local ch = s:sub(i, math.min(#s, i + n - 1))
        local w = (b and b >= 192) and 2 or 1

        table.insert(units, {ch = ch, width = w})
        i = i + n
    end

    return units
end

local function displayWidth(s)
    local width = 0
    for _, u in ipairs(utf8Units(tostring(s or ""))) do
        width = width + u.width
    end
    return width
end

local function fitText(s, width)
    s = tostring(s or "")
    local units = utf8Units(s)
    local total = 0

    for _, u in ipairs(units) do total = total + u.width end

    if total <= width then
        return s .. string.rep(" ", width - total)
    end

    local limit = math.max(0, width - 3)
    local out = {}
    local used = 0

    for _, u in ipairs(units) do
        if used + u.width > limit then break end
        table.insert(out, u.ch)
        used = used + u.width
    end

    return table.concat(out)
        .. "..."
        .. string.rep(" ", math.max(0, width - used - 3))
end

local function progressText(ratio, width)
    width = width or 18
    local shown = clamp(ratio or 0, 0, 1)
    local full = math.floor(shown * width + 0.5)
    return "[" .. string.rep("=", full) .. string.rep(" ", width - full) .. "]"
end

local function collectAddresses(typeName)
    local result = {}
    for address in component.list(typeName) do
        table.insert(result, address)
    end
    return result
end

local function allMeAddresses()
    local result = {}
    local seen = {}

    for _, componentType in ipairs({"me_interface", "fluid_interface"}) do
        for _, address in ipairs(collectAddresses(componentType)) do
            if not seen[address] then
                seen[address] = true
                table.insert(result, address)
            end
        end
    end

    return result
end

local function makeMeAdapter(address, role)
    local methods = component.methods(address)

    -- GTNH OC: false means indirect, nil means missing.
    if not methods or methods.getItemsInNetwork == nil then
        error(role .. " 不提供 getItemsInNetwork()")
    end

    return {
        address = address,
        getItemsInNetwork = function(...)
            return component.invoke(address, "getItemsInNetwork", ...)
        end,
    }
end

local function validateConfig()
    local reopen = tonumber(CFG.reopenRatio) or 0.95
    local stop = tonumber(CFG.stopRatio) or 1.00

    if reopen <= 0 then error("reopenRatio 必须 > 0") end
    if stop <= 0 then error("stopRatio 必须 > 0") end
    if reopen > stop then error("reopenRatio 不能大于 stopRatio") end

    local interval = tonumber(CFG.controlInterval) or 3
    if interval < 1 then error("controlInterval 建议至少为 1 秒") end

    local maxActive = tonumber(CFG.maxActive) or 12
    if maxActive < 1 then error("maxActive 必须 >= 1") end

    local requesterSlots = tonumber(CFG.requesterSlots) or 5
    if requesterSlots < 1 then error("requesterSlots 必须 >= 1") end
end

-- ============================================================
-- Network / Storage Buses
-- ============================================================

local function buildStorageBus(address, role, configuredSide)
    local methods = component.methods(address)

    if not methods then
        error(role .. "：无法读取方法表 " .. tostring(address))
    end

    for _, methodName in ipairs({
        "getStorageSlotSize",
        "getStorageConfiguration",
        "setStorageConfiguration",
    }) do
        if methods[methodName] == nil then
            error(role .. " 不提供 " .. methodName .. "()")
        end
    end

    local bus = {
        address = address,

        getStorageSlotSize = function(side)
            return component.invoke(
                address,
                "getStorageSlotSize",
                side
            )
        end,

        getStorageConfiguration = function(side, slot)
            return component.invoke(
                address,
                "getStorageConfiguration",
                side,
                slot
            )
        end,

        setStorageConfiguration = function(side, slot, detail)
            if detail ~= nil then
                return component.invoke(
                    address,
                    "setStorageConfiguration",
                    side,
                    slot,
                    detail
                )
            end

            return component.invoke(
                address,
                "setStorageConfiguration",
                side,
                slot
            )
        end,
    }

    local side = configuredSide

    if side == nil then
        for testSide = 0, 5 do
            local ok, count = pcall(
                bus.getStorageSlotSize,
                testSide
            )

            if ok
               and type(count) == "number"
               and count > 0
            then
                side = testSide
                break
            end
        end
    end

    if side == nil then
        error(role .. "：无法自动识别 side")
    end

    local ok, slotCount = pcall(
        bus.getStorageSlotSize,
        side
    )

    if not ok then
        error(
            role
            .. " side 无效: "
            .. tostring(side)
        )
    end

    if type(slotCount) ~= "number"
       or slotCount < 2
    then
        error(
            role
            .. " 槽位数异常: "
            .. tostring(slotCount)
            .. "；至少需要 2 格，因为最后一格永久保留"
        )
    end

    return bus, side, slotCount, address
end

local function storageBusAddressList()
    local buses = collectAddresses("me_storagebus")
    table.sort(buses)
    return buses
end

local function resolveProcessStorageBus()
    local address =
        CFG.processStorageBusAddress
        or CFG.storageBusAddress

    if not address then
        local buses = storageBusAddressList()

        if #buses == 0 then
            error("未检测到 me_storagebus")
        end

        if #buses > 1 then
            error(
                "检测到多个 me_storagebus。"
                .. "新增 OVERFLOW 总线后必须明确填写 "
                .. "processStorageBusAddress / "
                .. "overflowStorageBusAddress。"
            )
        end

        address = buses[1]
    end

    local side = CFG.processStorageSide

    if side == nil then
        side = CFG.storageSide
    end

    return buildStorageBus(
        address,
        "PROCESS Storage Bus",
        side
    )
end

local function resolveOverflowStorageBus()
    local address = CFG.overflowStorageBusAddress

    if not address or tostring(address) == "" then
        return nil, nil, nil, nil
    end

    return buildStorageBus(
        address,
        "OVERFLOW Storage Bus",
        CFG.overflowStorageSide
    )
end

local function managedSlotCount(slotCount, requested, role)
    -- Hard invariant:
    -- API slot slotCount-1 == GUI last slot is RESERVED.
    -- OC never reads it as a task slot, never writes it, never clears it.
    local maximum = slotCount - 1
    local count = tonumber(requested)

    if count == nil then
        count = maximum
    end

    count = math.floor(count)

    if count < 1 then
        error(role .. " managedSlots 必须 >= 1")
    end

    return math.min(count, maximum)
end

local function resolveMeNetworks()
    local productAddress = CFG.productMeAddress
    local legacyConfig = false

    if not productAddress and CFG.mainMeAddress then
        productAddress = CFG.mainMeAddress
        legacyConfig = true
    end

    local cacheAddress = CFG.cacheMeAddress

    if not productAddress or not cacheAddress then
        local addresses = allMeAddresses()
        local lines = {
            "需要在 ore_dispatch_config.lua 指定：",
            "  productMeAddress = 成品网二合一接口 UUID",
            "  cacheMeAddress   = 原矿缓存网二合一接口 UUID",
            "",
            "当前可见 ME 接口：",
        }

        for _, address in ipairs(addresses) do
            table.insert(lines, "  " .. address)
        end
        error(table.concat(lines, "\n"))
    end

    if productAddress == cacheAddress then
        error("productMeAddress 与 cacheMeAddress 不能相同")
    end

    local productMe = makeMeAdapter(productAddress, "成品网 ME")
    local cacheMe = makeMeAdapter(cacheAddress, "缓存网 ME")

    return productMe, cacheMe, {
        productAddress = productAddress,
        cacheAddress = cacheAddress,
        legacyConfig = legacyConfig,
    }
end

-- ============================================================
-- Requesters / product stock
-- ============================================================

local function parseTargetItem(slotData)
    local target = {
        label = slotData.label or slotData.name or "?",
        goal = tonumber(slotData.quantity) or 0,
        oreNames = slotData.oreNames,
    }

    local rawName = slotData.name
    local damage = tonumber(slotData.damage) or 0
    if type(rawName) ~= "string" then return nil end

    local nameFromId, damageFromId = rawName:match("^(.+):(%d+)$")
    if nameFromId and damageFromId then
        target.name = nameFromId
        target.damage = tonumber(damageFromId)
    else
        target.name = rawName
        target.damage = damage
    end

    if slotData.damage and tonumber(slotData.damage) and tonumber(slotData.damage) > 0 then
        target.damage = tonumber(slotData.damage)
    end

    target.key = target.name .. ":" .. tostring(target.damage or 0)
    return target
end

local function readTargets()
    local targets = {}
    local byKey = {}
    local conflicts = {}
    local requesterCount = 0
    local enabledSlotCount = 0
    local duplicateCount = 0
    local slotsPerRequester = tonumber(CFG.requesterSlots) or 5

    for address in component.list("level_maintainer") do
        requesterCount = requesterCount + 1
        local methods = component.methods(address)
        if not methods or methods.getSlot == nil then
            error("ME 请求器 " .. tostring(address) .. " 不提供 getSlot()")
        end

        for slot = 1, slotsPerRequester do
            local ok, data = pcall(component.invoke, address, "getSlot", slot)

            if ok and data and data.isEnable and not data.isFluid then
                enabledSlotCount = enabledSlotCount + 1
                local target = parseTargetItem(data)

                if target and target.goal > 0 then
                    target.requesterAddress = address
                    target.requesterSlot = slot
                    local previous = byKey[target.key]

                    if not previous then
                        byKey[target.key] = target
                        table.insert(targets, target)
                    elseif previous.goal ~= target.goal then
                        table.insert(conflicts, string.format(
                            "%s: %s[%d]=%s, %s[%d]=%s",
                            target.label,
                            tostring(previous.requesterAddress), previous.requesterSlot or -1, fmtAmount(previous.goal),
                            tostring(address), slot, fmtAmount(target.goal)
                        ))
                    else
                        duplicateCount = duplicateCount + 1
                    end
                end
            end
        end
    end

    if requesterCount == 0 then
        error("未检测到 level_maintainer；本程序使用 ME 请求器保存最终产物目标")
    end

    if #conflicts > 0 then
        error("检测到重复目标且目标值冲突：\n  " .. table.concat(conflicts, "\n  "))
    end

    return targets, {
        requesterCount = requesterCount,
        enabledSlotCount = enabledSlotCount,
        targetCount = #targets,
        duplicateCount = duplicateCount,
    }
end

local function getExactAmount(me, target)
    local filter = {name = target.name}
    if target.damage and target.damage > 0 then filter.damage = target.damage end

    local ok, items = pcall(me.getItemsInNetwork, filter)
    if not ok then return nil, nil, items end

    local amount = 0
    local exemplar = nil

    for _, stack in ipairs(items or {}) do
        if stack and stack.name == target.name and (stack.damage or 0) == (target.damage or 0) then
            amount = amount + (stack.size or 0)
            exemplar = exemplar or stack
        end
    end

    return amount, exemplar, nil
end

-- ============================================================
-- OreDictionary / material mapping
-- ============================================================

local TARGET_OREDICT_PREFIXES = {
    "gemExquisite", "gemFlawless", "gemFlawed", "gemChipped",
    "dustTiny", "dustSmall", "dust", "gem", "ingot", "plate", "crystal", "block",
}

local LABEL_SUFFIXES = {
    " Crystal Powder", " Dust", " Powder", " Gem", " Ingot", " Plate", " Crystal",
}

local LABEL_PREFIXES = {
    "Tiny Pile of ", "Small Pile of ", "Impure Pile of ", "Purified Pile of ",
}

local function materialFromOreNames(oreNames)
    for _, oreName in ipairs(oreNames or {}) do
        for _, prefix in ipairs(TARGET_OREDICT_PREFIXES) do
            if startsWith(oreName, prefix) and #oreName > #prefix then
                local material = oreName:sub(#prefix + 1)
                return normalizeMaterial(material), material, oreName
            end
        end
    end
    return nil
end

local function materialFromLabel(label)
    if type(label) ~= "string" then return nil end
    local material = label

    for _, prefix in ipairs(LABEL_PREFIXES) do
        if startsWith(material, prefix) then
            material = material:sub(#prefix + 1)
            break
        end
    end

    for _, suffix in ipairs(LABEL_SUFFIXES) do
        if #material > #suffix and material:sub(-#suffix) == suffix then
            material = material:sub(1, #material - #suffix)
            break
        end
    end

    return normalizeMaterial(material), material, "label-fallback"
end

local function materialFromRawOreLabel(label)
    if type(label) ~= "string" then return nil end
    local material = label:match("^(.-) Ore$")
    if not material or material == "" then return nil end
    return normalizeMaterial(material), material, "raw-label-fallback"
end

-- ============================================================
-- Raw cache catalog + unique material rows
-- ============================================================

local function getAllNetworkItems(me)
    local ok, items = pcall(me.getItemsInNetwork, {})
    if ok and type(items) == "table" then return items end

    ok, items = pcall(me.getItemsInNetwork)
    if ok and type(items) == "table" then return items end

    error("无法扫描原矿缓存网全部物品: " .. tostring(items))
end

local function scanRawOreCatalog(cacheMe)
    local catalog = {}
    local rawRows = {}
    local stackCount = 0
    local oreStackCount = 0
    local aliasCount = 0
    local totalRawAmount = 0

    local function addAlias(key, material, stack, oreName)
        if not key or key == "" then return end
        local row = catalog[key]

        if not row then
            row = {
                material = material,
                amount = 0,
                best = nil,
                bestAmount = -1,
                oreName = oreName,
            }
            catalog[key] = row
        end

        row.amount = row.amount + (stack.size or 0)
        if (stack.size or 0) > row.bestAmount then
            row.bestAmount = stack.size or 0
            row.best = stack
            row.oreName = oreName
        end
        aliasCount = aliasCount + 1
    end

    for _, stack in ipairs(getAllNetworkItems(cacheMe)) do
        if stack and (stack.size or 0) > 0 then
            stackCount = stackCount + 1

            local aliases = {}
            local aliasOrder = {}
            local aliasMaterial = {}
            local matchedAsOre = false

            for _, oreName in ipairs(stack.oreNames or {}) do
                local material = oreName:match("^ore(.+)$")
                if material then
                    matchedAsOre = true
                    local key = normalizeMaterial(material)
                    if key and not aliases[key] then
                        aliases[key] = true
                        aliasMaterial[key] = material
                        table.insert(aliasOrder, key)
                        addAlias(key, material, stack, oreName)
                    end
                end
            end

            if matchedAsOre then
                oreStackCount = oreStackCount + 1
                totalRawAmount = totalRawAmount + (stack.size or 0)

                local labelKey, labelMaterial = materialFromRawOreLabel(stack.label)
                if labelKey and not aliases[labelKey] then
                    aliases[labelKey] = true
                    aliasMaterial[labelKey] = labelMaterial
                    table.insert(aliasOrder, labelKey)
                    addAlias(labelKey, labelMaterial, stack, "label:" .. tostring(stack.label))
                end

                -- Stable canonical key: prefer normalized "X Ore" label when available.
                local canonicalKey = labelKey or aliasOrder[1]
                local canonicalMaterial = labelMaterial or (canonicalKey and aliasMaterial[canonicalKey]) or stack.label or "?"

                if canonicalKey then
                    local row = rawRows[canonicalKey]
                    if not row then
                        row = {
                            key = canonicalKey,
                            material = canonicalMaterial,
                            amount = 0,
                            best = nil,
                            bestAmount = -1,
                            aliases = {},
                            variantCount = 0,
                            label = stack.label,
                        }
                        rawRows[canonicalKey] = row
                    end

                    row.amount = row.amount + (stack.size or 0)
                    row.variantCount = row.variantCount + 1
                    for aliasKey in pairs(aliases) do row.aliases[aliasKey] = true end

                    if (stack.size or 0) > row.bestAmount then
                        row.bestAmount = stack.size or 0
                        row.best = stack
                        row.label = stack.label
                    end
                end
            end
        end
    end

    return catalog, rawRows, {
        networkStackCount = stackCount,
        oreStackCount = oreStackCount,
        rawAliasCount = aliasCount,
        rawMaterialCount = (function()
            local n = 0
            for _ in pairs(rawRows) do n = n + 1 end
            return n
        end)(),
        totalRawAmount = totalRawAmount,
    }
end

-- ============================================================
-- Overrides
-- ============================================================

local function loadOverrides()
    local path = CFG.overrideFile
    if not path then return {} end

    local f = io.open(path, "r")
    if not f then return {} end
    f:close()

    local data, err = loadLuaTable(path)
    if not data then error("例外映射文件读取失败: " .. tostring(err)) end
    return data
end

-- ============================================================
-- TARGET state
-- ============================================================

local demandMemory = {}

local function displayTargetLabel(target)
    return USER.names.items[target.key] or target.label
end

local function evaluateTargets(productMe, rawCatalog, overrides, targets)
    local states = {}

    for _, target in ipairs(targets) do
        local current, exemplar, err = getExactAmount(productMe, target)
        if current == nil then
            error("读取成品网目标失败 " .. target.label .. ": " .. tostring(err))
        end

        local ratio = target.goal > 0 and current / target.goal or 0
        local materialKey, materialName, materialSource = nil, nil, nil

        if exemplar then
            materialKey, materialName, materialSource = materialFromOreNames(exemplar.oreNames)
        end
        if not materialKey and target.oreNames then
            materialKey, materialName, materialSource = materialFromOreNames(target.oreNames)
        end
        if not materialKey then
            materialKey, materialName, materialSource = materialFromLabel(target.label)
        end

        local raw = materialKey and rawCatalog[materialKey] or nil
        if materialKey and overrides[materialKey] then
            raw = {
                material = materialName or materialKey,
                amount = raw and raw.amount or 0,
                best = overrides[materialKey],
                bestAmount = raw and raw.amount or 0,
                oreName = "override",
            }
        end

        local wasDemanding = demandMemory[target.key] == true
        local demanding
        if ratio >= (CFG.stopRatio or 1.0) then
            demanding = false
        elseif wasDemanding then
            demanding = true
        else
            demanding = ratio < (CFG.reopenRatio or 1.0)
        end
        demandMemory[target.key] = demanding

        table.insert(states, {
            target = target,
            current = current,
            ratio = ratio,
            materialKey = materialKey,
            materialName = materialName,
            materialSource = materialSource,
            raw = raw,
            demanding = demanding,
            selected = false,
            status = "",
        })
    end

    return states
end

local function chooseTargetActive(states, slotLimit)
    local candidates = {}

    for _, state in ipairs(states) do
        if state.ratio >= (CFG.stopRatio or 1.0) then
            state.status = "已完成"
        elseif not state.materialKey then
            state.status = "映射失败"
        elseif not state.demanding then
            state.status = "待低于启动线"
        elseif not state.raw or not state.raw.best then
            state.status = "等待原矿"
        elseif (state.raw.amount or 0) <= 0 then
            state.status = "等待原矿"
        else
            state.status = "待处理"
            table.insert(candidates, state)
        end
    end

    table.sort(candidates, function(a, b)
        if a.ratio == b.ratio then
            return tostring(displayTargetLabel(a.target)) < tostring(displayTargetLabel(b.target))
        end
        return a.ratio < b.ratio
    end)

    local limit = math.min(tonumber(CFG.maxActive) or slotLimit, slotLimit)
    local selected = {}
    local seenRawItem = {}

    for _, state in ipairs(candidates) do
        if #selected >= limit then break end
        local id = itemId(state.raw.best)
        if id and not seenRawItem[id] then
            seenRawItem[id] = true
            state.selected = true
            state.status = "处理中"
            state.kind = "TARGET"
            table.insert(selected, state)
        end
    end

    return selected, seenRawItem, limit
end

-- ============================================================
-- Cache policy (AUTO / IGNORE + independent OVERFLOW guard)
-- ============================================================

local function materialSetting(key)
    local entry = USER.materials[key]
    if type(entry) ~= "table" then entry = {} end

    local policy = normalizePolicy(
        entry.policy or USER.defaultPolicy
    )

    local high =
        tonumber(entry.high)
        or tonumber(USER.surplusHigh)
        or 100000000

    local low =
        tonumber(entry.low)
        or tonumber(USER.surplusLow)
        or 10000000

    if high <= 0 then high = 100000000 end
    if low < 0 then low = 0 end
    if low >= high then
        low = math.max(0, math.floor(high * 0.1))
    end

    local overflowConfigured = entry.overflow == true

    local overflowHigh =
        tonumber(entry.overflowHigh)
        or tonumber(USER.overflowHigh)
        or 100000000

    local overflowLow =
        tonumber(entry.overflowLow)
        or tonumber(USER.overflowLow)
        or 80000000

    if overflowHigh <= 0 then
        overflowHigh = 100000000
    end

    if overflowLow < 0 then overflowLow = 0 end

    if overflowLow >= overflowHigh then
        overflowLow = math.max(
            0,
            math.floor(overflowHigh * 0.8)
        )
    end

    return entry,
           policy,
           high,
           low,
           overflowConfigured,
           overflowHigh,
           overflowLow
end

local function displayMaterialLabel(row)
    local alias = USER.names.materials[row.key]

    if alias and alias ~= "" then
        return alias
    end

    if row.label and row.label ~= "" then
        return row.label
    end

    return tostring(
        row.material or row.key or "?"
    ) .. " Ore"
end

local function buildTargetCoverage(targetStates)
    local aliasSet = {}
    local rawItemSet = {}

    for _, state in ipairs(targetStates) do
        if state.materialKey then
            aliasSet[state.materialKey] = true
        end

        if state.raw and state.raw.best then
            rawItemSet[itemId(state.raw.best)] = true
        end
    end

    return aliasSet, rawItemSet
end

local function rowIsTarget(
    row,
    targetAliases,
    targetRawItems
)
    if row.best
       and targetRawItems[itemId(row.best)]
    then
        return true
    end

    for aliasKey in pairs(row.aliases or {}) do
        if targetAliases[aliasKey] then
            return true
        end
    end

    return false
end

local function evaluateSurplus(rawRows, targetStates)
    local targetAliases,
          targetRawItems =
        buildTargetCoverage(targetStates)

    local states = {}
    local stateChanged = false

    for key, row in pairs(rawRows) do
        local entry,
              policy,
              high,
              low,
              overflowConfigured,
              overflowHigh,
              overflowLow =
            materialSetting(key)

        local isTarget =
            rowIsTarget(
                row,
                targetAliases,
                targetRawItems
            )

        -- ---------- AUTO processing state ----------
        local autoMemory = RUNSTATE.surplus[key]

        if type(autoMemory) ~= "table" then
            autoMemory = {draining = false}
            RUNSTATE.surplus[key] = autoMemory
        end

        local wasDraining =
            autoMemory.draining == true

        local draining = wasDraining
        local status = ""
        local effectivePolicy = policy

        if isTarget then
            effectivePolicy = "TARGET"
            draining = false
            status = "目标优先"

        elseif policy == "IGNORE" then
            draining = false
            status = "忽略"

        elseif not USER.autoSurplusEnabled then
            status =
                wasDraining
                and "AUTO暂停·待续"
                or "AUTO暂停"

        else
            if row.amount <= low then
                draining = false

            elseif wasDraining then
                draining = true

            elseif row.amount >= high then
                draining = true

            else
                draining = false
            end

            status =
                draining
                and "待余矿槽"
                or "等待阈值"
        end

        if isTarget or policy == "IGNORE" then
            if autoMemory.draining then
                autoMemory.draining = false
                stateChanged = true
            end

        elseif USER.autoSurplusEnabled
           and draining ~= wasDraining
        then
            autoMemory.draining = draining
            stateChanged = true
        end

        -- ---------- OVERFLOW guard state ----------
        local overflowMemory =
            RUNSTATE.overflow[key]

        if type(overflowMemory) ~= "table" then
            overflowMemory = {active = false}
            RUNSTATE.overflow[key] = overflowMemory
        end

        local wasOverflowActive =
            overflowMemory.active == true

        local overflowActive =
            wasOverflowActive

        local overflowStatus = "溢流关闭"

        if isTarget then
            -- TARGET is an absolute no-trash override.
            overflowActive = false
            overflowStatus = "TARGET保护"

        elseif not overflowConfigured then
            overflowActive = false
            overflowStatus = "溢流未配置"

        elseif not USER.overflowEnabled then
            overflowStatus =
                wasOverflowActive
                and "溢流暂停·待续"
                or "溢流暂停"

        else
            if row.amount <= overflowLow then
                overflowActive = false

            elseif wasOverflowActive then
                overflowActive = true

            elseif row.amount >= overflowHigh then
                overflowActive = true

            else
                overflowActive = false
            end

            overflowStatus =
                overflowActive
                and "待溢流槽"
                or "溢流待阈值"
        end

        if isTarget or not overflowConfigured then
            if overflowMemory.active then
                overflowMemory.active = false
                stateChanged = true
            end

        elseif USER.overflowEnabled
           and overflowActive ~= wasOverflowActive
        then
            overflowMemory.active = overflowActive
            stateChanged = true
        end

        table.insert(states, {
            kind = "SURPLUS",
            key = key,
            raw = row,
            amount = row.amount,

            policy = policy,
            effectivePolicy = effectivePolicy,
            high = high,
            low = low,
            target = isTarget,
            draining = draining,
            selected = false,
            status = status,
            overflowRatio =
                high > 0
                and row.amount / high
                or 0,

            overflowConfigured =
                overflowConfigured,
            overflowHigh = overflowHigh,
            overflowLow = overflowLow,
            overflowActive = overflowActive,
            overflowSelected = false,
            overflowStatus = overflowStatus,
            overflowGuardRatio =
                overflowHigh > 0
                and row.amount / overflowHigh
                or 0,

            legacyVoid = entry.legacyVoid == true,
        })
    end

    if stateChanged then
        saveRunState()
    end

    return states
end

local function chooseSurplusActive(
    surplusStates,
    seenRawItem,
    remainingSlots
)
    local candidates = {}

    if USER.autoSurplusEnabled
       and remainingSlots > 0
    then
        for _, state in ipairs(surplusStates) do
            if not state.target
               and state.policy == "AUTO"
               and state.draining
               and state.raw
               and state.raw.best
               and (state.amount or 0) > state.low
            then
                table.insert(candidates, state)
            end
        end
    end

    table.sort(
        candidates,
        function(a, b)
            if a.overflowRatio == b.overflowRatio then
                return tostring(
                    displayMaterialLabel(a.raw)
                ) < tostring(
                    displayMaterialLabel(b.raw)
                )
            end

            return a.overflowRatio > b.overflowRatio
        end
    )

    local limit = math.min(
        math.max(
            0,
            tonumber(USER.maxSurplusActive) or 0
        ),
        math.max(0, remainingSlots)
    )

    local selected = {}

    for _, state in ipairs(candidates) do
        if #selected >= limit then break end

        local id = itemId(state.raw.best)

        if id and not seenRawItem[id] then
            seenRawItem[id] = true
            state.selected = true
            state.status = "余矿处理中"
            table.insert(selected, state)

        elseif id and seenRawItem[id] then
            state.status = "目标占用"
        end
    end

    return selected
end

local function chooseOverflowActive(
    surplusStates,
    overflowBusAvailable,
    slotLimit
)
    local candidates = {}

    if USER.overflowEnabled
       and overflowBusAvailable
       and slotLimit > 0
    then
        for _, state in ipairs(surplusStates) do
            if not state.target
               and state.overflowConfigured
               and state.overflowActive
               and state.raw
               and state.raw.best
               and (state.amount or 0)
                   > state.overflowLow
            then
                table.insert(candidates, state)
            end
        end
    end

    table.sort(
        candidates,
        function(a, b)
            if a.overflowGuardRatio
               == b.overflowGuardRatio
            then
                return tostring(
                    displayMaterialLabel(a.raw)
                ) < tostring(
                    displayMaterialLabel(b.raw)
                )
            end

            return a.overflowGuardRatio
                > b.overflowGuardRatio
        end
    )

    local limit = math.min(
        math.max(
            0,
            tonumber(USER.maxOverflowActive) or 0
        ),
        math.max(0, slotLimit)
    )

    local selected = {}
    local seen = {}

    for _, state in ipairs(candidates) do
        if #selected >= limit then break end

        local id = itemId(state.raw.best)

        if id and not seen[id] then
            seen[id] = true
            state.overflowSelected = true
            state.overflowStatus = "溢流拦截中"
            table.insert(selected, state)
        end
    end

    return selected
end

local function combineDispatch(
    targetSelected,
    surplusSelected
)
    local selected = {}

    for _, state in ipairs(targetSelected) do
        table.insert(selected, state)
    end

    for _, state in ipairs(surplusSelected) do
        table.insert(selected, state)
    end

    return selected
end

-- ============================================================
-- Storage Bus whitelist
-- ============================================================

local function applyStorageWhitelist(bus, side, managedSlots, selected)
    local desired = {}
    for _, state in ipairs(selected) do
        table.insert(desired, state.raw.best)
    end

    local changes = 0

    for slot = 0, managedSlots - 1 do
        local want = desired[slot + 1]
        local ok, current = pcall(bus.getStorageConfiguration, side, slot)

        if not ok then
            error("读取 Storage Bus 槽 " .. tostring(slot) .. " 失败: " .. tostring(current))
        end

        if want then
            if not sameItem(current, want) then
                changes = changes + 1
                if not CFG.dryRun then
                    local writeOk, result = pcall(bus.setStorageConfiguration, side, slot, want)
                    if not writeOk or result ~= true then
                        error("写 Storage Bus 槽 " .. tostring(slot) .. " 失败: " .. tostring(result))
                    end
                end
            end
        elseif current ~= nil then
            changes = changes + 1
            if not CFG.dryRun then
                local clearOk, result = pcall(bus.setStorageConfiguration, side, slot)
                if not clearOk or result ~= true then
                    error("清空 Storage Bus 槽 " .. tostring(slot) .. " 失败: " .. tostring(result))
                end
            end
        end
    end

    return changes
end

-- ============================================================
-- Bus control / maintenance lock
-- ============================================================
--
-- The GUI last slot of EVERY OC-managed Storage Bus is a reserved
-- manual placeholder slot. This program never touches it.
--
-- Blocking io.read() is still used for text entry in this release.
-- Before entering a blocking prompt, dynamic slots on BOTH buses are
-- cleared, so processing/overflow pauses safely while the user types.
--
local CONTROL = {
    processBus = nil,
    processSide = nil,
    processManagedSlots = 0,

    overflowBus = nil,
    overflowSide = nil,
    overflowManagedSlots = 0,
}

local function clearControlledBus(
    bus,
    side,
    managedSlots
)
    if not bus
       or not side
       or not managedSlots
       or managedSlots <= 0
    then
        return true
    end

    if CFG.dryRun then
        return true
    end

    local ok, result = pcall(
        applyStorageWhitelist,
        bus,
        side,
        managedSlots,
        {}
    )

    if not ok then
        return nil, tostring(result)
    end

    return true
end

local function enterMaintenanceMode()
    local ok, err = clearControlledBus(
        CONTROL.processBus,
        CONTROL.processSide,
        CONTROL.processManagedSlots
    )

    if not ok then
        return nil,
            "暂停 PROCESS 总线失败: "
            .. tostring(err)
    end

    ok, err = clearControlledBus(
        CONTROL.overflowBus,
        CONTROL.overflowSide,
        CONTROL.overflowManagedSlots
    )

    if not ok then
        return nil,
            "暂停 OVERFLOW 总线失败: "
            .. tostring(err)
    end

    return true
end

local function safeStopBuses()
    -- Best-effort cleanup. Never touches the reserved last slot.
    pcall(
        clearControlledBus,
        CONTROL.processBus,
        CONTROL.processSide,
        CONTROL.processManagedSlots
    )

    pcall(
        clearControlledBus,
        CONTROL.overflowBus,
        CONTROL.overflowSide,
        CONTROL.overflowManagedSlots
    )
end

-- ============================================================
-- Dashboard / interaction
-- ============================================================

local UI = {
    initialized = false,
    color = false,
    w = 0,
    h = 0,
    originalW = nil,
    originalH = nil,
    originalFg = nil,
    originalBg = nil,
    buttonRegions = {},
    page = "targets",
    selectedTargetKey = nil,
    selectedMaterialKey = nil,

    -- 长列表滚动位置；支持 OpenComputers scroll 事件。
    targetOffset = 0,
    cacheOffset = 0,
    targetPageSize = 1,
    cachePageSize = 1,
}

local COLORS = {
    bg          = 0x080B0D,
    panel       = 0x10161A,
    panel2      = 0x151D22,
    selected    = 0x20313A,
    border      = 0x263138,
    text        = 0xDCE7EC,
    muted       = 0x6F818A,
    green       = 0x39D98A,
    greenDark   = 0x173C2A,
    cyan        = 0x55C7F3,
    amber       = 0xFFB84D,
    red         = 0xFF5C68,
    blue        = 0x6B8CFF,
    purple      = 0xC58BFF,
    track       = 0x253039,
    black       = 0x000000,
    white       = 0xFFFFFF,
    button      = 0x1C272D,
    buttonOff   = 0x151A1D,
    exitBg      = 0x5C1F27,
    exitFg      = 0xFF9AA3,
}

local RUNNING = true
local LAST_CONTEXT = {
    targetByKey = {},
    surplusByKey = {},
}

local function sortTargetsForUI(states)
    table.sort(states, function(a, b)
        if CFG.uiSort == "name" then
            return tostring(displayTargetLabel(a.target)) < tostring(displayTargetLabel(b.target))
        end
        if a.ratio == b.ratio then
            return tostring(displayTargetLabel(a.target)) < tostring(displayTargetLabel(b.target))
        end
        return a.ratio < b.ratio
    end)
end

local function cachePolicyRank(state)
    if state.effectivePolicy == "TARGET" then return 1 end
    if state.selected then return 2 end
    if state.overflowSelected then return 3 end
    if state.policy == "AUTO" and state.draining then return 4 end
    if state.overflowConfigured and state.overflowActive then return 5 end
    if state.policy == "AUTO" and state.amount >= state.high then return 6 end
    if state.policy == "IGNORE" then return 7 end
    return 8
end

local function sortCacheForUI(states)
    table.sort(states, function(a, b)
        local ra, rb = cachePolicyRank(a), cachePolicyRank(b)
        if ra ~= rb then return ra < rb end
        if a.amount ~= b.amount then return a.amount > b.amount end
        return tostring(displayMaterialLabel(a.raw)) < tostring(displayMaterialLabel(b.raw))
    end)
end

local function nonTargetSurplusView(states)
    local visible = {}
    local totalAmount = 0

    for _, state in ipairs(states or {}) do
        if not state.target then
            table.insert(visible, state)
            totalAmount = totalAmount + (tonumber(state.amount) or 0)
        end
    end

    return visible, totalAmount
end

local function uiInit()
    if UI.initialized then return end
    if not component.isAvailable("gpu") then
        UI.initialized = true
        return
    end

    local gpu = component.gpu
    UI.originalW, UI.originalH = gpu.getResolution()

    local okFg, fg = pcall(gpu.getForeground)
    if okFg then UI.originalFg = fg end
    local okBg, bg = pcall(gpu.getBackground)
    if okBg then UI.originalBg = bg end

    if CFG.uiUseMaxResolution ~= false then
        local ok, mw, mh = pcall(gpu.maxResolution)
        if ok and type(mw) == "number" and type(mh) == "number" then
            pcall(gpu.setResolution, mw, mh)
        end
    end

    UI.w, UI.h = gpu.getResolution()
    local okDepth, depth = pcall(gpu.getDepth)
    UI.color = okDepth and type(depth) == "number" and depth > 1
    UI.initialized = true
end

local function gpuColors(fg, bg)
    if not component.isAvailable("gpu") then return end
    if UI.color then
        if fg then pcall(component.gpu.setForeground, fg) end
        if bg then pcall(component.gpu.setBackground, bg) end
    end
end

local function gpuText(x, y, text, fg, bg)
    if x < 1 or y < 1 or x > UI.w or y > UI.h then return end
    gpuColors(fg, bg)
    pcall(component.gpu.set, x, y, tostring(text or ""))
end

local function gpuFill(x, y, w, h, bg)
    if w <= 0 or h <= 0 then return end

    if x < 1 then w = w - (1 - x); x = 1 end
    if y < 1 then h = h - (1 - y); y = 1 end

    w = math.min(w, UI.w - x + 1)
    h = math.min(h, UI.h - y + 1)
    if w <= 0 or h <= 0 then return end

    gpuColors(COLORS.text, bg)
    pcall(component.gpu.fill, x, y, w, h, " ")
end

local function cleanupUI()
    if not component.isAvailable("gpu") then
        pcall(term.clear)
        pcall(term.setCursor, 1, 1)
        return
    end

    local gpu = component.gpu
    if UI.originalW and UI.originalH then pcall(gpu.setResolution, UI.originalW, UI.originalH) end
    if UI.originalBg then pcall(gpu.setBackground, UI.originalBg) else pcall(gpu.setBackground, COLORS.black) end
    if UI.originalFg then pcall(gpu.setForeground, UI.originalFg) else pcall(gpu.setForeground, COLORS.white) end
    pcall(term.clear)
    pcall(term.setCursor, 1, 1)
end

local function resetUIAfterPrompt()
    UI.initialized = false
    UI.buttonRegions = {}
end

local function statusColor(status)
    if status == "已完成" then return COLORS.green end
    if status == "处理中" or status == "余矿处理中" then return COLORS.cyan end
    if status == "等待原矿" or status == "销毁未启用" then return COLORS.amber end
    if status == "映射失败" then return COLORS.red end
    if status == "待处理" or status == "待余矿槽" then return COLORS.blue end
    if status == "目标优先" or status == "目标占用" then return COLORS.purple end
    return COLORS.muted
end

local function policyColor(policy)
    if policy == "TARGET" then return COLORS.purple end
    if policy == "AUTO" then return COLORS.cyan end
    if policy == "IGNORE" then return COLORS.muted end
    return COLORS.text
end

local function drawBadge(x, y, text, fg, bg)
    local width = displayWidth(text) + 2
    gpuFill(x, y, width, 1, bg)
    gpuText(x + 1, y, text, fg, bg)
    return width
end

local function drawCard(x, y, w, label, value, accent)
    gpuFill(x, y, w, 3, COLORS.panel)
    gpuFill(x, y, 1, 3, accent)
    gpuText(x + 3, y, label, COLORS.muted, COLORS.panel)
    gpuText(x + 3, y + 1, tostring(value), COLORS.text, COLORS.panel)
end

local function drawSolidBar(x, y, width, ratio)
    ratio = clamp(ratio or 0, 0, 1)
    width = math.max(1, width)
    gpuFill(x, y, width, 1, COLORS.track)
    local full = math.floor(width * ratio + 0.5)
    if full > 0 then gpuFill(x, y, full, 1, COLORS.green) end
end

local function registerRegion(spec, x, y, w, h)
    table.insert(UI.buttonRegions, {
        id = spec.id,
        label = spec.label,
        enabled = spec.enabled ~= false,
        data = spec.data,
        x = x, y = y, w = w, h = h,
    })
end

local function drawButton(spec, x, y, w)
    local enabled = spec.enabled ~= false
    local bg = enabled and (spec.kind == "exit" and COLORS.exitBg or COLORS.button) or COLORS.buttonOff
    local fg = enabled and (spec.kind == "exit" and COLORS.exitFg or COLORS.text) or COLORS.muted

    gpuFill(x, y, w, 1, bg)
    local labelW = displayWidth(spec.label)
    local tx = x + math.max(0, math.floor((w - labelW) / 2))
    gpuText(tx, y, spec.label, fg, bg)
    registerRegion(spec, x, y, w, 1)
end

local function hitRegion(x, y)
    for i = #UI.buttonRegions, 1, -1 do
        local region = UI.buttonRegions[i]
        if x >= region.x and x < region.x + region.w and y >= region.y and y < region.y + region.h then
            return region
        end
    end
    return nil
end

local function topButtonSpecs()
    if UI.page == "cache" then
        return {
            {id = "rename_material", label = "命名", enabled = UI.selectedMaterialKey ~= nil},
            {id = "edit_policy", label = "策略", enabled = UI.selectedMaterialKey ~= nil},
            {id = "back", label = "返回", enabled = true},
        }
    end

    return {
        {id = "rename_target", label = "命名", enabled = UI.selectedTargetKey ~= nil},
        {id = "cache", label = "缓存", enabled = true},
        {id = "exit", label = "退出", enabled = true, kind = "exit"},
    }
end

local function drawHeader(title, subtitle)
    local w = UI.w
    gpuFill(1, 1, w, 3, COLORS.panel)
    gpuFill(1, 4, w, 1, COLORS.greenDark)
    gpuText(3, 1, title, COLORS.white, COLORS.panel)
    gpuText(3, 2, subtitle, COLORS.muted, COLORS.panel)

    UI.buttonRegions = {}

    local modeText = CFG.dryRun and "DRY RUN" or "LIVE"
    local modeBg = CFG.dryRun and 0x7A541A or 0x17633E
    local modeFg = CFG.dryRun and COLORS.amber or COLORS.green
    local modeW = displayWidth(modeText) + 2
    local modeX = w - modeW - 2
    drawBadge(modeX, 2, modeText, modeFg, modeBg)

    local specs = topButtonSpecs()
    local buttonW = 8
    local buttonGap = 1
    local totalButtonW = buttonW * #specs + buttonGap * (#specs - 1)
    local buttonX = modeX - totalButtonW - 2

    for i, spec in ipairs(specs) do
        drawButton(spec, buttonX + (i - 1) * (buttonW + buttonGap), 2, buttonW)
    end
end

local function renderTextFallback(targetStates, surplusStates, info)
    pcall(term.clear)
    pcall(term.setCursor, 1, 1)

    print("矿石处理控制中心 / ORE PROCESSING CONTROL CENTER v" .. VERSION)
    print(string.format(
        "%s | TARGET %d/%d | AUTO %d | OVERFLOW %d | raw=%d",
        CFG.dryRun and "[DRY RUN]" or "[LIVE]",
        info.targetActiveCount, info.targetCount,
        info.surplusActiveCount,
        info.overflowActiveCount or 0,
        info.rawMaterialCount or 0
    ))
    print(string.rep("-", 96))

    if UI.page == "cache" then
        local visibleStates = nonTargetSurplusView(surplusStates)
        sortCacheForUI(visibleStates)

        if #visibleStates == 0 then
            print("当前无余矿：已识别原矿全部属于 TARGET，或缓存中没有可管理余矿。")
        else
            for _, s in ipairs(visibleStates) do
                print(string.format(
                    "%s %10s  %-8s AUTO %s/%s  OVF %s  %s",
                    fitText(displayMaterialLabel(s.raw), 24),
                    fmtAmount(s.amount),
                    s.effectivePolicy,
                    fmtAmount(s.high), fmtAmount(s.low),
                    s.overflowConfigured and "ON" or "OFF",
                    s.overflowSelected and "溢流拦截" or s.status
                ))
            end
        end
    else
        sortTargetsForUI(targetStates)
        for _, s in ipairs(targetStates) do
            local rawAmount = s.raw and s.raw.amount or 0
            print(string.format(
                "%s %8s / %-8s %s %6.1f%% raw=%8s %s",
                fitText(displayTargetLabel(s.target), 22),
                fmtAmount(s.current), fmtAmount(s.target.goal),
                progressText(s.ratio, CFG.progressBarWidth or 24),
                s.ratio * 100, fmtAmount(rawAmount), s.status
            ))
        end
    end
end

local function renderTargetPage(states, info)
    local w, h = UI.w, UI.h
    gpuFill(1, 1, w, h, COLORS.bg)
    drawHeader("矿石处理控制中心", "ORE PROCESSING CONTROL CENTER  ·  GTNH  ·  v" .. VERSION)

    local gap = 2
    local cards = 5
    local cardW = math.max(12, math.floor((w - 4 - gap * (cards - 1)) / cards))
    local cy, x = 6, 3

    drawCard(x, cy, cardW, "目标", info.targetCount, COLORS.green); x = x + cardW + gap
    drawCard(x, cy, cardW, "TARGET运行", info.targetActiveCount, COLORS.cyan); x = x + cardW + gap
    drawCard(x, cy, cardW, "AUTO运行", info.surplusActiveCount, COLORS.blue); x = x + cardW + gap
    drawCard(x, cy, cardW, "溢流拦截", info.overflowActiveCount or 0, COLORS.amber); x = x + cardW + gap
    drawCard(x, cy, math.max(12, w - x - 2), "待同步", info.changes, info.changes > 0 and COLORS.amber or COLORS.green)

    local stripY = 10
    gpuFill(3, stripY, w - 4, 2, COLORS.panel2)
    gpuText(5, stripY, "成品网 " .. shortAddress(info.productAddress), COLORS.muted, COLORS.panel2)
    gpuText(math.floor(w * 0.36), stripY, "缓存网 " .. shortAddress(info.cacheAddress), COLORS.muted, COLORS.panel2)
    gpuText(math.floor(w * 0.68), stripY, "存储总线 " .. shortAddress(info.busAddress) .. "  S" .. tostring(info.side), COLORS.muted, COLORS.panel2)
    gpuText(5, stripY + 1, string.format(
        "scan %d stacks · %d ores · %d materials · AUTO %s · OVERFLOW %s",
        info.networkStackCount or 0,
        info.oreStackCount or 0,
        info.rawMaterialCount or 0,
        USER.autoSurplusEnabled and "ON" or "OFF",
        USER.overflowEnabled and "ON" or "OFF"
    ), COLORS.muted, COLORS.panel2)

    local headerY = 13
    gpuText(4, headerY, "目标产物（点击可选中）", COLORS.muted, COLORS.bg)
    gpuText(math.floor(w * 0.57), headerY, "库存", COLORS.muted, COLORS.bg)
    gpuText(math.floor(w * 0.77), headerY, "原矿缓存", COLORS.muted, COLORS.bg)
    gpuText(w - 12, headerY, "状态", COLORS.muted, COLORS.bg)
    gpuFill(3, headerY + 1, w - 4, 1, COLORS.border)

    sortTargetsForUI(states)
    LAST_CONTEXT.targetByKey = {}

    local rowY = headerY + 2
    local rowH = 3
    local maxRows = math.max(1, math.floor((h - rowY - 2 + 1) / rowH))
    UI.targetPageSize = maxRows

    local maxOffset = math.max(0, #states - maxRows)
    UI.targetOffset = math.max(0, math.min(UI.targetOffset or 0, maxOffset))

    local materialW = math.max(18, math.floor(w * 0.31))
    local stockX = math.floor(w * 0.57)
    local rawX = math.floor(w * 0.77)
    local stateX = w - 12

    local selectedStillExists = false

    for _, state in ipairs(states) do
        LAST_CONTEXT.targetByKey[state.target.key] = state
        if state.target.key == UI.selectedTargetKey then selectedStillExists = true end
    end

    local firstIndex = UI.targetOffset + 1
    local lastIndex = math.min(#states, UI.targetOffset + maxRows)

    for i = firstIndex, lastIndex do
        local state = states[i]

        local y = rowY + (i - firstIndex) * rowH
        local rawAmount = state.raw and state.raw.amount or 0
        local statusFg = statusColor(state.status)
        local selected = state.target.key == UI.selectedTargetKey
        local rowBg = selected and COLORS.selected or ((i % 2 == 1) and COLORS.panel or COLORS.panel2)

        gpuFill(3, y, w - 4, 2, rowBg)
        gpuFill(3, y, 1, 2, selected and COLORS.blue or statusFg)
        registerRegion({id = "select_target", data = state.target.key}, 3, y, w - 4, 2)

        gpuText(5, y, fitText(displayTargetLabel(state.target), materialW), COLORS.text, rowBg)
        gpuText(stockX, y, fmtAmount(state.current) .. " / " .. fmtAmount(state.target.goal), state.ratio >= 1 and COLORS.green or COLORS.text, rowBg)
        gpuText(rawX, y, fmtAmount(rawAmount), rawAmount > 0 and COLORS.text or COLORS.amber, rowBg)
        gpuText(stateX, y, state.status, statusFg, rowBg)

        local barX = 5
        local percentText = string.format("%5.1f%%", state.ratio * 100)
        local percentW = displayWidth(percentText)
        local barRight = stockX - 3
        local barW = math.max(12, barRight - barX - percentW - 2)
        drawSolidBar(barX, y + 1, barW, state.ratio)
        gpuText(barX + barW + 2, y + 1, percentText, state.ratio >= 1 and COLORS.green or COLORS.muted, rowBg)
        gpuText(stockX, y + 1, "原矿 " .. fmtAmount(rawAmount) .. "  ·  TARGET优先", COLORS.muted, rowBg)
    end

    if UI.selectedTargetKey and not selectedStillExists then UI.selectedTargetKey = nil end

    local footerY = h
    local leftFooter
    if #states > maxRows then
        leftFooter = string.format(
            "目标 %d-%d / %d · 鼠标滚轮上下浏览",
            firstIndex,
            lastIndex,
            #states
        )
    else
        leftFooter = "自动刷新 "
            .. tostring(CFG.controlInterval or 3)
            .. "s · 点击[缓存]查看全部原矿"
    end
    gpuText(3, footerY, leftFooter, #states > maxRows and COLORS.amber or COLORS.muted, COLORS.bg)

    local rightFooter = USER.autoSurplusEnabled
        and ("AUTO余矿已启用 · 默认 " .. fmtAmount(USER.surplusHigh) .. "→" .. fmtAmount(USER.surplusLow))
        or "AUTO余矿已暂停"
    local rfW = displayWidth(rightFooter)
    gpuText(math.max(3, w - rfW - 2), footerY, rightFooter, USER.autoSurplusEnabled and COLORS.green or COLORS.amber, COLORS.bg)
    gpuColors(COLORS.text, COLORS.bg)
end

local function renderCachePage(states, info)
    local w, h = UI.w, UI.h
    local visibleStates, visibleTotalAmount =
        nonTargetSurplusView(states)

    if UI.selectedMaterialKey then
        local stillVisible = false

        for _, state in ipairs(visibleStates) do
            if state.key == UI.selectedMaterialKey then
                stillVisible = true
                break
            end
        end

        if not stillVisible then
            UI.selectedMaterialKey = nil
        end
    end

    gpuFill(1, 1, w, h, COLORS.bg)

    drawHeader(
        "余矿策略管理",
        "SURPLUS POLICY  ·  NON-TARGET ONLY  ·  AUTO / IGNORE + OVERFLOW GUARD  ·  v"
        .. VERSION
    )

    local autoSpec = {
        id = "toggle_auto",
        label =
            USER.autoSurplusEnabled
            and "AUTO ON"
            or "AUTO OFF",
        enabled = true,
    }

    local overflowSpec = {
        id = "toggle_overflow",
        label =
            USER.overflowEnabled
            and "溢流 ON"
            or "溢流 OFF",
        enabled = true,
    }

    drawButton(autoSpec, 3, 6, 14)
    drawButton(overflowSpec, 18, 6, 14)

    local gap = 2
    local cardW = math.max(
        13,
        math.floor((w - 37 - gap * 3) / 4)
    )

    local x = 35

    drawCard(
        x, 6, cardW,
        "余矿矿种",
        #visibleStates,
        COLORS.amber
    )
    x = x + cardW + gap

    drawCard(
        x, 6, cardW,
        "余矿总量",
        fmtAmount(visibleTotalAmount),
        COLORS.green
    )
    x = x + cardW + gap

    drawCard(
        x, 6, cardW,
        "AUTO运行",
        info.surplusActiveCount,
        COLORS.cyan
    )
    x = x + cardW + gap

    drawCard(
        x, 6,
        math.max(13, w - x - 2),
        "溢流拦截",
        info.overflowActiveCount or 0,
        COLORS.amber
    )

    local stripY = 10
    gpuFill(3, stripY, w - 4, 2, COLORS.panel2)

    gpuText(
        5,
        stripY,
        "AUTO "
        .. fmtAmount(USER.surplusHigh)
        .. " → "
        .. fmtAmount(USER.surplusLow),
        COLORS.muted,
        COLORS.panel2
    )

    gpuText(
        math.floor(w * 0.35),
        stripY,
        "默认溢流 "
        .. fmtAmount(USER.overflowHigh)
        .. " / 恢复 "
        .. fmtAmount(USER.overflowLow),
        COLORS.muted,
        COLORS.panel2
    )

    local overflowBusText

    if info.overflowConnected then
        overflowBusText =
            "OVERFLOW BUS "
            .. shortAddress(info.overflowBusAddress)
    else
        overflowBusText =
            "OVERFLOW BUS 未连接"
    end

    gpuText(
        math.floor(w * 0.70),
        stripY,
        overflowBusText,
        info.overflowConnected
            and COLORS.green
            or COLORS.amber,
        COLORS.panel2
    )

    gpuText(
        5,
        stripY + 1,
        "这里只管理未被请求器标记的余矿；成为 TARGET 后立即隐藏并禁止溢流，取消 TARGET 后原配置仍保留",
        COLORS.muted,
        COLORS.panel2
    )

    local headerY = 13
    local nameX = 4
    local amountX = math.floor(w * 0.46)
    local policyX = math.floor(w * 0.58)
    local thresholdX = math.floor(w * 0.68)
    local statusX = w - 18

    gpuText(nameX, headerY, "余矿（点击选择）", COLORS.muted, COLORS.bg)
    gpuText(amountX, headerY, "缓存量", COLORS.muted, COLORS.bg)
    gpuText(policyX, headerY, "加工", COLORS.muted, COLORS.bg)
    gpuText(thresholdX, headerY, "AUTO 启动/停止", COLORS.muted, COLORS.bg)
    gpuText(statusX, headerY, "状态", COLORS.muted, COLORS.bg)
    gpuFill(3, headerY + 1, w - 4, 1, COLORS.border)

    sortCacheForUI(visibleStates)
    LAST_CONTEXT.surplusByKey = {}

    local rowY = headerY + 2
    local rowH = 3
    local maxRows = math.max(
        1,
        math.floor((h - rowY - 2 + 1) / rowH)
    )

    UI.cachePageSize = maxRows

    local maxOffset = math.max(0, #visibleStates - maxRows)
    UI.cacheOffset = math.max(
        0,
        math.min(UI.cacheOffset or 0, maxOffset)
    )

    local nameW = math.max(16, amountX - nameX - 2)

    for _, s in ipairs(visibleStates) do
        LAST_CONTEXT.surplusByKey[s.key] = s
    end

    local firstIndex = UI.cacheOffset + 1
    local lastIndex = math.min(
        #visibleStates,
        UI.cacheOffset + maxRows
    )

    if #visibleStates == 0 then
        local emptyY = rowY + 2

        gpuText(
            5,
            emptyY,
            "当前没有需要管理的余矿",
            COLORS.text,
            COLORS.bg
        )

        gpuText(
            5,
            emptyY + 2,
            "已识别原矿全部属于 TARGET，或缓存网当前没有非 TARGET 原矿。",
            COLORS.muted,
            COLORS.bg
        )

        gpuText(
            5,
            emptyY + 3,
            "当请求器取消某材料目标，或出现新的伴生矿后，它会自动出现在这里。",
            COLORS.muted,
            COLORS.bg
        )
    else
        for i = firstIndex, lastIndex do
            local s = visibleStates[i]
            local y = rowY + (i - firstIndex) * rowH

            local selected =
                s.key == UI.selectedMaterialKey

            local rowBg =
                selected
                and COLORS.selected
                or (
                    (i % 2 == 1)
                    and COLORS.panel
                    or COLORS.panel2
                )

            local pColor = policyColor(s.effectivePolicy)
            local mainStatus = s.status
            local mainColor = statusColor(s.status)

            if s.overflowSelected then
                mainStatus = "溢流拦截中"
                mainColor = COLORS.amber
            end

            gpuFill(3, y, w - 4, 2, rowBg)

            gpuFill(
                3,
                y,
                1,
                2,
                selected
                    and COLORS.blue
                    or (
                        s.overflowSelected
                        and COLORS.amber
                        or pColor
                    )
            )

            registerRegion(
                {
                    id = "select_material",
                    data = s.key
                },
                3,
                y,
                w - 4,
                2
            )

            gpuText(
                nameX + 1,
                y,
                fitText(displayMaterialLabel(s.raw), nameW),
                COLORS.text,
                rowBg
            )

            gpuText(
                amountX,
                y,
                fmtAmount(s.amount),
                (
                    s.overflowConfigured
                    and s.amount >= s.overflowHigh
                )
                    and COLORS.amber
                    or COLORS.text,
                rowBg
            )

            gpuText(
                policyX,
                y,
                s.effectivePolicy,
                pColor,
                rowBg
            )

            gpuText(
                thresholdX,
                y,
                fmtAmount(s.high)
                .. " / "
                .. fmtAmount(s.low),
                COLORS.text,
                rowBg
            )

            gpuText(
                statusX,
                y,
                fitText(mainStatus, 17),
                mainColor,
                rowBg
            )

            local barRatio = 0

            if s.policy == "AUTO"
               and s.high > s.low
            then
                barRatio =
                    (s.amount - s.low)
                    / (s.high - s.low)

            elseif s.overflowConfigured
               and s.overflowHigh > s.overflowLow
            then
                barRatio =
                    (s.amount - s.overflowLow)
                    / (s.overflowHigh - s.overflowLow)
            end

            drawSolidBar(
                nameX + 1,
                y + 1,
                math.max(10, nameW - 10),
                barRatio
            )

            local overflowDetail

            if s.overflowConfigured then
                overflowDetail =
                    "溢流 "
                    .. fmtAmount(s.overflowHigh)
                    .. " / "
                    .. fmtAmount(s.overflowLow)
                    .. " · "
                    .. s.overflowStatus
            else
                overflowDetail = "溢流 OFF"
            end

            local detail =
                overflowDetail
                .. " · variants "
                .. tostring(s.raw.variantCount or 1)
                .. (
                    s.legacyVoid
                    and " · 旧VOID已安全迁移为IGNORE"
                    or ""
                )

            gpuText(
                amountX,
                y + 1,
                fitText(
                    detail,
                    math.max(10, statusX - amountX - 2)
                ),
                COLORS.muted,
                rowBg
            )
        end
    end

    local footerY = h
    local leftFooter

    if #visibleStates > maxRows then
        leftFooter = string.format(
            "余矿 %d-%d / %d · 鼠标滚轮上下浏览",
            firstIndex,
            lastIndex,
            #visibleStates
        )
    else
        leftFooter =
            "TARGET 不进入本页 · OVERFLOW 只拦截后续新增，不主动清理已有库存"
    end

    gpuText(
        3,
        footerY,
        leftFooter,
        #visibleStates > maxRows
            and COLORS.amber
            or COLORS.muted,
        COLORS.bg
    )

    local rightFooter

    if not info.overflowConnected then
        rightFooter = "溢流总线未连接"
    elseif USER.overflowEnabled then
        rightFooter =
            "溢流保护 ACTIVE · "
            .. tostring(info.overflowActiveCount or 0)
            .. "/"
            .. tostring(USER.maxOverflowActive)
    else
        rightFooter = "溢流保护 PAUSED"
    end

    local rfW = displayWidth(rightFooter)

    gpuText(
        math.max(3, w - rfW - 2),
        footerY,
        rightFooter,
        (
            info.overflowConnected
            and USER.overflowEnabled
        )
            and COLORS.green
            or COLORS.amber,
        COLORS.bg
    )

    gpuColors(COLORS.text, COLORS.bg)
end

local function renderUI(targetStates, surplusStates, info)
    if CFG.enableUI == false then return end
    uiInit()

    if not component.isAvailable("gpu") then
        renderTextFallback(targetStates, surplusStates, info)
        return
    end

    UI.w, UI.h = component.gpu.getResolution()
    if not UI.color or UI.w < 90 or UI.h < 20 then
        renderTextFallback(targetStates, surplusStates, info)
        return
    end

    if UI.page == "cache" then
        renderCachePage(surplusStates, info)
    else
        renderTargetPage(targetStates, info)
    end
end

-- ============================================================
-- Interactive actions
-- ============================================================

local function promptLine(title, promptText, currentValue)
    local safe, safeErr = enterMaintenanceMode()
    if not safe then
        cleanupUI()
        print("无法进入安全维护模式：")
        print(tostring(safeErr))
        print("按回车返回。")
        io.read()
        return nil
    end

    cleanupUI()
    resetUIAfterPrompt()

    print("GTNH Ore Dispatch Controller v" .. VERSION)
    print(string.rep("=", 72))
    print(title)
    print("回车 = 保持/取消；输入 - = 清除名称（仅命名时）")
    if currentValue ~= nil then print("当前: " .. tostring(currentValue)) end
    io.write(promptText .. ": ")

    local value = io.read()
    if value == nil then return nil end
    return trim(value)
end

local function renameTarget()
    local key = UI.selectedTargetKey
    local state = key and LAST_CONTEXT.targetByKey[key]
    if not state then return end

    local current = USER.names.items[key] or ""
    local value = promptLine("命名目标产物: " .. tostring(state.target.label), "新显示名", current)
    if not value or value == "" then return end

    if value == "-" then USER.names.items[key] = nil else USER.names.items[key] = value end
    saveUserConfig()
end

local function renameMaterial()
    local key = UI.selectedMaterialKey
    local state = key and LAST_CONTEXT.surplusByKey[key]
    if not state then return end

    local current = USER.names.materials[key] or ""
    local value = promptLine("命名缓存矿物: " .. tostring(state.raw.label or key), "新显示名", current)
    if not value or value == "" then return end

    if value == "-" then USER.names.materials[key] = nil else USER.names.materials[key] = value end
    saveUserConfig()
end

local function editMaterialPolicy()
    local key = UI.selectedMaterialKey
    local state =
        key and LAST_CONTEXT.surplusByKey[key]

    if not state then return end

    local safe, safeErr =
        enterMaintenanceMode()

    if not safe then
        cleanupUI()
        print("无法进入安全维护模式：")
        print(tostring(safeErr))
        print("按回车返回。")
        io.read()
        return
    end

    local entry,
          policy,
          high,
          low,
          overflowConfigured,
          overflowHigh,
          overflowLow =
        materialSetting(key)

    cleanupUI()
    resetUIAfterPrompt()

    print(
        "GTNH Ore Dispatch Controller v"
        .. VERSION
    )
    print(string.rep("=", 72))

    print(
        "矿物策略: "
        .. displayMaterialLabel(state.raw)
        .. "  ["
        .. key
        .. "]"
    )

    if state.target then
        print(
            "注意：当前属于 TARGET；"
            .. "TARGET 会覆盖后台加工并强制关闭溢流。"
        )
    end

    print("")
    print("一、后台加工")
    print("A = AUTO  超量时送矿处加工")
    print("I = IGNORE 不进行后台加工")
    print("当前: " .. policy)

    io.write(
        "加工策略 [A/I，回车保持]: "
    )

    local p =
        trim(io.read() or "")

    if p ~= "" then
        p = p:upper()

        if p == "A" or p == "AUTO" then
            policy = "AUTO"

        elseif p == "I"
           or p == "IGNORE"
        then
            policy = "IGNORE"

        else
            print(
                "无效加工策略，未保存。"
                .. "按回车返回。"
            )
            io.read()
            return
        end
    end

    if policy == "AUTO" then
        io.write(
            "AUTO 启动阈值 [当前 "
            .. fmtAmount(high)
            .. "]: "
        )

        local highText =
            trim(io.read() or "")

        local newHigh =
            parseAmount(highText, high)

        if not newHigh or newHigh <= 0 then
            print(
                "AUTO 启动阈值无效，未保存。"
                .. "按回车返回。"
            )
            io.read()
            return
        end

        io.write(
            "AUTO 停止阈值 [当前 "
            .. fmtAmount(low)
            .. "]: "
        )

        local lowText =
            trim(io.read() or "")

        local newLow =
            parseAmount(lowText, low)

        if not newLow
           or newLow < 0
           or newLow >= newHigh
        then
            print(
                "必须满足 0 <= AUTO停止 < AUTO启动。"
                .. "未保存。按回车返回。"
            )
            io.read()
            return
        end

        high, low = newHigh, newLow
    end

    print("")
    print("二、溢流保护")
    print(
        "作用：超过上限后，把后续新进入 AE 的该矿"
        .. "导向高优先级垃圾 Storage Bus。"
    )
    print(
        "不会主动把已经存下来的库存抽出来销毁。"
    )

    print(
        "当前: "
        .. (
            overflowConfigured
            and "ON"
            or "OFF"
        )
    )

    io.write(
        "溢流保护 [Y/N，回车保持]: "
    )

    local o =
        trim(io.read() or "")

    if o ~= "" then
        o = o:upper()

        if o == "Y"
           or o == "YES"
           or o == "ON"
        then
            overflowConfigured = true

        elseif o == "N"
           or o == "NO"
           or o == "OFF"
        then
            overflowConfigured = false

        else
            print(
                "无效溢流设置，未保存。"
                .. "按回车返回。"
            )
            io.read()
            return
        end
    end

    if overflowConfigured then
        io.write(
            "溢流启动上限 [当前 "
            .. fmtAmount(overflowHigh)
            .. "]: "
        )

        local overflowHighText =
            trim(io.read() or "")

        local newOverflowHigh =
            parseAmount(
                overflowHighText,
                overflowHigh
            )

        if not newOverflowHigh
           or newOverflowHigh <= 0
        then
            print(
                "溢流上限无效，未保存。"
                .. "按回车返回。"
            )
            io.read()
            return
        end

        io.write(
            "溢流恢复线 [当前 "
            .. fmtAmount(overflowLow)
            .. "]: "
        )

        local overflowLowText =
            trim(io.read() or "")

        local newOverflowLow =
            parseAmount(
                overflowLowText,
                overflowLow
            )

        if not newOverflowLow
           or newOverflowLow < 0
           or newOverflowLow
               >= newOverflowHigh
        then
            print(
                "必须满足 0 <= 溢流恢复线 < 溢流上限。"
                .. "未保存。按回车返回。"
            )
            io.read()
            return
        end

        overflowHigh =
            newOverflowHigh

        overflowLow =
            newOverflowLow
    end

    entry.policy = policy
    entry.high = high
    entry.low = low
    entry.overflow = overflowConfigured
    entry.overflowHigh = overflowHigh
    entry.overflowLow = overflowLow
    entry.legacyVoid = nil

    USER.materials[key] = entry

    -- Explicit edits reset both hysteresis memories.
    if RUNSTATE.surplus[key]
       and RUNSTATE.surplus[key].draining
    then
        RUNSTATE.surplus[key].draining = false
    end

    if RUNSTATE.overflow[key]
       and RUNSTATE.overflow[key].active
    then
        RUNSTATE.overflow[key].active = false
    end

    saveRunState()
    saveUserConfig()
end

local function toggleAutoSurplus()
    USER.autoSurplusEnabled =
        not USER.autoSurplusEnabled
    saveUserConfig()
end

local function toggleOverflow()
    USER.overflowEnabled =
        not USER.overflowEnabled
    saveUserConfig()
end

local function handleRegion(region)
    if not region or not region.enabled then return nil end

    if region.id == "exit" then
        RUNNING = false
        return "exit"
    elseif region.id == "cache" then
        UI.page = "cache"
        return "refresh"
    elseif region.id == "back" then
        UI.page = "targets"
        return "refresh"
    elseif region.id == "select_target" then
        UI.selectedTargetKey = region.data
        return "refresh"
    elseif region.id == "select_material" then
        UI.selectedMaterialKey = region.data
        return "refresh"
    elseif region.id == "rename_target" then
        renameTarget()
        return "refresh"
    elseif region.id == "rename_material" then
        renameMaterial()
        return "refresh"
    elseif region.id == "edit_policy" then
        editMaterialPolicy()
        return "refresh"
    elseif region.id == "toggle_auto" then
        toggleAutoSurplus()
        return "refresh"
    elseif region.id == "toggle_overflow" then
        toggleOverflow()
        return "refresh"
    end

    return nil
end

local function handleUIEvent(name, ...)
    if name == "interrupted" then
        RUNNING = false
        return "exit"
    end

    if name == "scroll" then
        local _, x, y, direction = ...
        direction = tonumber(direction) or 0

        if UI.page == "cache" then
            local step = direction > 0 and -1 or 1
            UI.cacheOffset = math.max(0, (UI.cacheOffset or 0) + step)
        else
            local step = direction > 0 and -1 or 1
            UI.targetOffset = math.max(0, (UI.targetOffset or 0) + step)
        end

        return "refresh"
    end

    if name ~= "touch" then return nil end

    local _, x, y = ...
    local region = hitRegion(tonumber(x) or -1, tonumber(y) or -1)
    return handleRegion(region)
end

local function waitForNextCycle(seconds)
    local deadline = computer.uptime() + math.max(0, tonumber(seconds) or 0)

    while RUNNING do
        local remaining = deadline - computer.uptime()
        if remaining <= 0 then return "cycle" end

        local pulled = {event.pull(remaining)}
        if #pulled > 0 and pulled[1] ~= nil then
            local name = table.remove(pulled, 1)
            local action = handleUIEvent(name, table.unpack(pulled))
            if action then return action end
        end
    end

    return "exit"
end

-- ============================================================
-- Main loop
-- ============================================================

local function main()
    validateConfig()

    local productMe,
          cacheMe,
          meInfo =
        resolveMeNetworks()

    local processBus,
          processSide,
          processSlotCount,
          processBusAddress =
        resolveProcessStorageBus()

    local overflowBus,
          overflowSide,
          overflowSlotCount,
          overflowBusAddress =
        resolveOverflowStorageBus()

    if overflowBusAddress
       and overflowBusAddress
           == processBusAddress
    then
        error(
            "PROCESS 与 OVERFLOW "
            .. "不能使用同一根 Storage Bus"
        )
    end

    local processManagedSlots =
        managedSlotCount(
            processSlotCount,
            CFG.processManagedSlots
                or CFG.managedSlots,
            "PROCESS"
        )

    local overflowManagedSlots = 0

    if overflowBus then
        overflowManagedSlots =
            managedSlotCount(
                overflowSlotCount,
                CFG.overflowManagedSlots or 16,
                "OVERFLOW"
            )
    end

    CONTROL.processBus = processBus
    CONTROL.processSide = processSide
    CONTROL.processManagedSlots =
        processManagedSlots

    CONTROL.overflowBus = overflowBus
    CONTROL.overflowSide = overflowSide
    CONTROL.overflowManagedSlots =
        overflowManagedSlots

    print(
        "GTNH Ore Dispatch Controller v"
        .. VERSION
    )
    print(
        "配置: "
        .. tostring(loadedConfigPath)
    )
    print(
        "用户策略: "
        .. tostring(loadedUserPath)
    )

    print(
        "PROCESS Bus: "
        .. tostring(processBusAddress)
        .. " side="
        .. tostring(processSide)
        .. " controlled="
        .. tostring(processManagedSlots)
        .. " / "
        .. tostring(processSlotCount - 1)
        .. " + 最后一格保留"
    )

    if overflowBus then
        print(
            "OVERFLOW Bus: "
            .. tostring(overflowBusAddress)
            .. " side="
            .. tostring(overflowSide)
            .. " controlled="
            .. tostring(overflowManagedSlots)
            .. " / "
            .. tostring(overflowSlotCount - 1)
            .. " + 最后一格保留"
        )
    else
        print(
            "OVERFLOW Bus: 未配置；"
            .. "溢流保护只显示策略，不执行"
        )
    end

    if startupWarning then
        print(
            "警告: "
            .. startupWarning
        )
    end

    print("启动完成，进入 Dashboard...")
    os.sleep(1)

    RUNNING = true

    while RUNNING do
        local targets,
              requestInfo =
            readTargets()

        local rawCatalog,
              rawRows,
              cacheScanInfo =
            scanRawOreCatalog(cacheMe)

        local overrides =
            loadOverrides()

        local targetStates =
            evaluateTargets(
                productMe,
                rawCatalog,
                overrides,
                targets
            )

        local targetSelected,
              seenRawItem,
              activeLimit =
            chooseTargetActive(
                targetStates,
                processManagedSlots
            )

        local surplusStates =
            evaluateSurplus(
                rawRows,
                targetStates
            )

        local nonTargetMaterialCount = 0
        local nonTargetRawAmount = 0

        for _, state in ipairs(surplusStates) do
            if not state.target then
                nonTargetMaterialCount =
                    nonTargetMaterialCount + 1
                nonTargetRawAmount =
                    nonTargetRawAmount
                    + (tonumber(state.amount) or 0)
            end
        end

        local remaining =
            math.max(
                0,
                activeLimit
                - #targetSelected
            )

        local surplusSelected =
            chooseSurplusActive(
                surplusStates,
                seenRawItem,
                remaining
            )

        local processSelected =
            combineDispatch(
                targetSelected,
                surplusSelected
            )

        local overflowSelected =
            chooseOverflowActive(
                surplusStates,
                overflowBus ~= nil,
                overflowManagedSlots
            )

        local processChanges =
            applyStorageWhitelist(
                processBus,
                processSide,
                processManagedSlots,
                processSelected
            )

        local overflowChanges = 0

        if overflowBus then
            -- Even when the global overflow switch is OFF,
            -- selected is empty, so stale dynamic trash filters are cleared.
            overflowChanges =
                applyStorageWhitelist(
                    overflowBus,
                    overflowSide,
                    overflowManagedSlots,
                    overflowSelected
                )
        end

        local changes =
            processChanges + overflowChanges

        renderUI(
            targetStates,
            surplusStates,
            {
                productAddress =
                    meInfo.productAddress,
                cacheAddress =
                    meInfo.cacheAddress,
                legacyConfig =
                    meInfo.legacyConfig,

                busAddress =
                    processBusAddress,
                side =
                    processSide,
                slotCount =
                    processSlotCount,
                managedSlots =
                    processManagedSlots,

                overflowConnected =
                    overflowBus ~= nil,
                overflowBusAddress =
                    overflowBusAddress,
                overflowSide =
                    overflowSide,
                overflowSlotCount =
                    overflowSlotCount,
                overflowManagedSlots =
                    overflowManagedSlots,

                requesterCount =
                    requestInfo.requesterCount,
                targetCount =
                    requestInfo.targetCount,
                duplicateCount =
                    requestInfo.duplicateCount,

                networkStackCount =
                    cacheScanInfo.networkStackCount,
                oreStackCount =
                    cacheScanInfo.oreStackCount,
                rawAliasCount =
                    cacheScanInfo.rawAliasCount,
                rawMaterialCount =
                    cacheScanInfo.rawMaterialCount,
                totalRawAmount =
                    cacheScanInfo.totalRawAmount,
                nonTargetMaterialCount =
                    nonTargetMaterialCount,
                nonTargetRawAmount =
                    nonTargetRawAmount,

                targetActiveCount =
                    #targetSelected,
                surplusActiveCount =
                    #surplusSelected,
                overflowActiveCount =
                    #overflowSelected,
                activeCount =
                    #processSelected,
                changes =
                    changes,
            }
        )

        local action =
            waitForNextCycle(
                tonumber(CFG.controlInterval)
                or 3
            )

        if action == "exit" then
            break
        end
    end

    safeStopBuses()
    cleanupUI()
    return true
end

local ok, err = xpcall(main, function(e)
    if debug and debug.traceback then return debug.traceback(e, 2) end
    return tostring(e)
end)

if not ok then
    safeStopBuses()
    cleanupUI()
    print("GTNH Ore Dispatch Controller 已停止")
    print(err)
end
