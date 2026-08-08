-- GTNH 2.9 / OpenComputers
-- GTNH Ore Dispatch Controller
-- Release v0.4.1
--
-- v0.4.1:
--   UI-only major refresh. Core dispatch semantics remain v0.3.3-compatible.
--   - GPU-rendered dashboard
--   - green solid progress bars (real background fill, not #)
--   - status colors / LIVE badge / summary cards
--   - dynamic large-screen layout + compact fallback
--
-- Existing /home/ore_dispatch_config.lua remains compatible.

local component = require("component")
local os = require("os")
local term = require("term")

local VERSION = "0.4.1"

local CONFIG_PATH = "/home/ore_dispatch_config.lua"
local FALLBACK_CONFIG_PATH = "ore_dispatch_config.lua"

-- ============================================================
-- Config / basic utilities
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

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function startsWith(s, prefix)
    return type(s) == "string" and s:sub(1, #prefix) == prefix
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

    for _, u in ipairs(units) do
        total = total + u.width
    end

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
    return "["
        .. string.rep("=", full)
        .. string.rep(" ", width - full)
        .. "]"
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

    -- In GTNH OC, false means "indirect", not "missing".
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
-- Network / Storage Bus
-- ============================================================

local function resolveStorageBus()
    local address = CFG.storageBusAddress

    if not address then
        local buses = collectAddresses("me_storagebus")

        if #buses == 0 then
            error("未检测到 me_storagebus")
        end

        if #buses > 1 then
            error("检测到多个 me_storagebus，请在配置文件填写 storageBusAddress")
        end

        address = buses[1]
    end

    local methods = component.methods(address)

    if not methods then
        error("无法读取 Storage Bus 方法表: " .. tostring(address))
    end

    for _, methodName in ipairs({
        "getStorageSlotSize",
        "getStorageConfiguration",
        "setStorageConfiguration",
    }) do
        if methods[methodName] == nil then
            error("Storage Bus 不提供 " .. methodName .. "()")
        end
    end

    local bus = {
        address = address,

        getStorageSlotSize = function(side)
            return component.invoke(address, "getStorageSlotSize", side)
        end,

        getStorageConfiguration = function(side, slot)
            return component.invoke(address, "getStorageConfiguration", side, slot)
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

    local side = CFG.storageSide

    if side == nil then
        for testSide = 0, 5 do
            local ok, count = pcall(bus.getStorageSlotSize, testSide)

            if ok and type(count) == "number" and count > 0 then
                side = testSide
                break
            end
        end
    end

    if side == nil then
        error("无法自动识别 Storage Bus side")
    end

    local ok, slotCount = pcall(bus.getStorageSlotSize, side)

    if not ok then
        error("Storage Bus side 无效: " .. tostring(side))
    end

    if type(slotCount) ~= "number" or slotCount < 1 then
        error("Storage Bus 返回的槽位数量异常: " .. tostring(slotCount))
    end

    return bus, side, slotCount, address
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
-- Requesters
-- ============================================================

local function parseTargetItem(slotData)
    local target = {
        label = slotData.label or slotData.name or "?",
        goal = tonumber(slotData.quantity) or 0,
        oreNames = slotData.oreNames,
    }

    local rawName = slotData.name
    local damage = tonumber(slotData.damage) or 0

    if type(rawName) ~= "string" then
        return nil
    end

    local nameFromId, damageFromId = rawName:match("^(.+):(%d+)$")

    if nameFromId and damageFromId then
        target.name = nameFromId
        target.damage = tonumber(damageFromId)
    else
        target.name = rawName
        target.damage = damage
    end

    if slotData.damage
       and tonumber(slotData.damage)
       and tonumber(slotData.damage) > 0
    then
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
            local ok, data = pcall(
                component.invoke,
                address,
                "getSlot",
                slot
            )

            if ok
               and data
               and data.isEnable
               and not data.isFluid
            then
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
                        table.insert(
                            conflicts,
                            string.format(
                                "%s: %s[%d]=%s, %s[%d]=%s",
                                target.label,
                                tostring(previous.requesterAddress),
                                previous.requesterSlot or -1,
                                fmtAmount(previous.goal),
                                tostring(address),
                                slot,
                                fmtAmount(target.goal)
                            )
                        )
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
        error(
            "检测到重复目标且目标值冲突：\n  "
            .. table.concat(conflicts, "\n  ")
        )
    end

    return targets, {
        requesterCount = requesterCount,
        enabledSlotCount = enabledSlotCount,
        targetCount = #targets,
        duplicateCount = duplicateCount,
    }
end

-- ============================================================
-- Product stock
-- ============================================================

local function getExactAmount(me, target)
    local filter = {name = target.name}

    if target.damage and target.damage > 0 then
        filter.damage = target.damage
    end

    local ok, items = pcall(me.getItemsInNetwork, filter)

    if not ok then
        return nil, nil, items
    end

    local amount = 0
    local exemplar = nil

    for _, stack in ipairs(items or {}) do
        if stack
           and stack.name == target.name
           and (stack.damage or 0) == (target.damage or 0)
        then
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
    "gemExquisite",
    "gemFlawless",
    "gemFlawed",
    "gemChipped",
    "dustTiny",
    "dustSmall",
    "dust",
    "gem",
    "ingot",
    "plate",
    "crystal",
    "block",
}

local LABEL_SUFFIXES = {
    " Crystal Powder",
    " Dust",
    " Powder",
    " Gem",
    " Ingot",
    " Plate",
    " Crystal",
}

local LABEL_PREFIXES = {
    "Tiny Pile of ",
    "Small Pile of ",
    "Impure Pile of ",
    "Purified Pile of ",
}

local function materialFromOreNames(oreNames)
    for _, oreName in ipairs(oreNames or {}) do
        for _, prefix in ipairs(TARGET_OREDICT_PREFIXES) do
            if startsWith(oreName, prefix)
               and #oreName > #prefix
            then
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
        if #material > #suffix
           and material:sub(-#suffix) == suffix
        then
            material = material:sub(1, #material - #suffix)
            break
        end
    end

    return normalizeMaterial(material), material, "label-fallback"
end

local function materialFromRawOreLabel(label)
    if type(label) ~= "string" then return nil end

    local material = label:match("^(.-) Ore$")

    if not material or material == "" then
        return nil
    end

    return normalizeMaterial(material), material, "raw-label-fallback"
end

-- ============================================================
-- Raw cache
-- ============================================================

local function getAllNetworkItems(me)
    local ok, items = pcall(me.getItemsInNetwork, {})

    if ok and type(items) == "table" then
        return items
    end

    ok, items = pcall(me.getItemsInNetwork)

    if ok and type(items) == "table" then
        return items
    end

    error("无法扫描原矿缓存网全部物品: " .. tostring(items))
end

local function scanRawOreCatalog(cacheMe)
    local catalog = {}
    local stackCount = 0
    local oreStackCount = 0
    local aliasCount = 0

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

            local seenAliases = {}
            local matchedAsOre = false

            for _, oreName in ipairs(stack.oreNames or {}) do
                local material = oreName:match("^ore(.+)$")

                if material then
                    matchedAsOre = true
                    local key = normalizeMaterial(material)

                    if key and not seenAliases[key] then
                        seenAliases[key] = true
                        addAlias(key, material, stack, oreName)
                    end
                end
            end

            if matchedAsOre then
                oreStackCount = oreStackCount + 1

                local labelKey, labelMaterial =
                    materialFromRawOreLabel(stack.label)

                if labelKey and not seenAliases[labelKey] then
                    seenAliases[labelKey] = true
                    addAlias(
                        labelKey,
                        labelMaterial,
                        stack,
                        "label:" .. tostring(stack.label)
                    )
                end
            end
        end
    end

    return catalog, {
        networkStackCount = stackCount,
        oreStackCount = oreStackCount,
        rawAliasCount = aliasCount,
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

    if not data then
        error("例外映射文件读取失败: " .. tostring(err))
    end

    return data
end

-- ============================================================
-- Dispatch state
-- ============================================================

local demandMemory = {}

local function evaluateTargets(productMe, rawCatalog, overrides, targets)
    local states = {}

    for _, target in ipairs(targets) do
        local current, exemplar, err = getExactAmount(productMe, target)

        if current == nil then
            error(
                "读取成品网目标失败 "
                .. target.label
                .. ": "
                .. tostring(err)
            )
        end

        local ratio = 0
        if target.goal > 0 then
            ratio = current / target.goal
        end

        local materialKey = nil
        local materialName = nil
        local materialSource = nil

        if exemplar then
            materialKey, materialName, materialSource =
                materialFromOreNames(exemplar.oreNames)
        end

        if not materialKey and target.oreNames then
            materialKey, materialName, materialSource =
                materialFromOreNames(target.oreNames)
        end

        if not materialKey then
            materialKey, materialName, materialSource =
                materialFromLabel(target.label)
        end

        local raw = nil

        if materialKey then
            raw = rawCatalog[materialKey]
        end

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
        local demanding = false

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

local function chooseActive(states, slotLimit)
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

    table.sort(
        candidates,
        function(a, b)
            if a.ratio == b.ratio then
                return tostring(a.target.label)
                    < tostring(b.target.label)
            end
            return a.ratio < b.ratio
        end
    )

    local maxActive = tonumber(CFG.maxActive) or slotLimit
    local limit = math.min(maxActive, slotLimit)

    local selected = {}
    local seenRawItem = {}

    for _, state in ipairs(candidates) do
        if #selected >= limit then break end

        local id = itemId(state.raw.best)

        if id and not seenRawItem[id] then
            seenRawItem[id] = true
            state.selected = true
            state.status = "处理中"
            table.insert(selected, state)
        end
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

        local ok, current = pcall(
            bus.getStorageConfiguration,
            side,
            slot
        )

        if not ok then
            error(
                "读取 Storage Bus 槽 "
                .. tostring(slot)
                .. " 失败: "
                .. tostring(current)
            )
        end

        if want then
            if not sameItem(current, want) then
                changes = changes + 1

                if not CFG.dryRun then
                    local writeOk, result = pcall(
                        bus.setStorageConfiguration,
                        side,
                        slot,
                        want
                    )

                    if not writeOk or result ~= true then
                        error(
                            "写 Storage Bus 槽 "
                            .. tostring(slot)
                            .. " 失败: "
                            .. tostring(result)
                        )
                    end
                end
            end
        else
            if current ~= nil then
                changes = changes + 1

                if not CFG.dryRun then
                    local clearOk, result = pcall(
                        bus.setStorageConfiguration,
                        side,
                        slot
                    )

                    if not clearOk or result ~= true then
                        error(
                            "清空 Storage Bus 槽 "
                            .. tostring(slot)
                            .. " 失败: "
                            .. tostring(result)
                        )
                    end
                end
            end
        end
    end

    return changes
end

-- ============================================================
-- Dashboard v0.4
-- ============================================================

local UI = {
    initialized = false,
    color = false,
    w = 0,
    h = 0,
}

local COLORS = {
    bg          = 0x080B0D,
    panel       = 0x10161A,
    panel2      = 0x151D22,
    border      = 0x263138,
    text        = 0xDCE7EC,
    muted       = 0x6F818A,
    green       = 0x39D98A,
    greenDark   = 0x173C2A,
    cyan        = 0x55C7F3,
    amber       = 0xFFB84D,
    red         = 0xFF5C68,
    blue        = 0x6B8CFF,
    track       = 0x253039,
    black       = 0x000000,
    white       = 0xFFFFFF,
}

local function sortForUI(states)
    table.sort(
        states,
        function(a, b)
            if CFG.uiSort == "name" then
                return tostring(a.target.label)
                    < tostring(b.target.label)
            end

            if a.ratio == b.ratio then
                return tostring(a.target.label)
                    < tostring(b.target.label)
            end

            return a.ratio < b.ratio
        end
    )
end

local function uiInit()
    if UI.initialized then return end

    if not component.isAvailable("gpu") then
        UI.initialized = true
        return
    end

    local gpu = component.gpu

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

local function gpuSet(x, y, text, fg, bg)
    if x < 1 or y < 1 or x > UI.w or y > UI.h then return end

    gpuColors(fg, bg)

    local max = UI.w - x + 1
    if max <= 0 then return end

    pcall(component.gpu.set, x, y, fitText(text, math.min(displayWidth(text), max)))
end

local function gpuText(x, y, text, fg, bg)
    if x < 1 or y < 1 or x > UI.w or y > UI.h then return end
    gpuColors(fg, bg)
    pcall(component.gpu.set, x, y, tostring(text or ""))
end

local function gpuFill(x, y, w, h, bg)
    if w <= 0 or h <= 0 then return end

    if x < 1 then
        w = w - (1 - x)
        x = 1
    end

    if y < 1 then
        h = h - (1 - y)
        y = 1
    end

    w = math.min(w, UI.w - x + 1)
    h = math.min(h, UI.h - y + 1)

    if w <= 0 or h <= 0 then return end

    gpuColors(COLORS.text, bg)
    pcall(component.gpu.fill, x, y, w, h, " ")
end

local function statusColor(status)
    if status == "已完成" then
        return COLORS.green
    elseif status == "处理中" then
        return COLORS.cyan
    elseif status == "等待原矿" then
        return COLORS.amber
    elseif status == "映射失败" then
        return COLORS.red
    elseif status == "待处理" then
        return COLORS.blue
    end

    return COLORS.muted
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

    -- Track is a real colored rectangle.
    gpuFill(x, y, width, 1, COLORS.track)

    local full = math.floor(width * ratio + 0.5)

    if full > 0 then
        -- User-requested green solid filled block.
        gpuFill(x, y, full, 1, COLORS.green)
    end
end

local function renderTextFallback(states, info)
    pcall(term.clear)
    pcall(term.setCursor, 1, 1)

    print("ORE PROCESSING CONTROL CENTER  v" .. VERSION)
    print(
        string.format(
            "%s | targets=%d active=%d | bus=%d/%d",
            CFG.dryRun and "[DRY RUN]" or "[LIVE]",
            info.targetCount,
            info.activeCount,
            info.managedSlots,
            info.slotCount
        )
    )
    print(string.rep("-", 96))

    sortForUI(states)

    for _, state in ipairs(states) do
        local rawAmount = state.raw and state.raw.amount or 0

        print(
            string.format(
                "%s %8s / %-8s %s %6.1f%% raw=%8s %s",
                fitText(state.target.label, 22),
                fmtAmount(state.current),
                fmtAmount(state.target.goal),
                progressText(state.ratio, CFG.progressBarWidth or 24),
                state.ratio * 100,
                fmtAmount(rawAmount),
                state.status
            )
        )
    end
end

local function renderFancyUI(states, info)
    local gpu = component.gpu
    local w, h = UI.w, UI.h

    -- Background
    gpuFill(1, 1, w, h, COLORS.bg)

    -- Header panel
    gpuFill(1, 1, w, 3, COLORS.panel)
    gpuFill(1, 4, w, 1, COLORS.greenDark)

    gpuText(3, 1, "ORE PROCESSING CONTROL CENTER", COLORS.white, COLORS.panel)
    gpuText(
        3,
        2,
        "GTNH / AUTOMATED MATERIAL DISPATCH  ·  v" .. VERSION,
        COLORS.muted,
        COLORS.panel
    )

    local modeText = CFG.dryRun and "DRY RUN" or "LIVE"
    local modeBg = CFG.dryRun and 0x7A541A or 0x17633E
    local modeFg = CFG.dryRun and COLORS.amber or COLORS.green
    local modeW = displayWidth(modeText) + 2
    drawBadge(w - modeW - 2, 2, modeText, modeFg, modeBg)

    -- Summary cards
    local gap = 2
    local cards = 5
    local cardW = math.floor((w - 4 - gap * (cards - 1)) / cards)
    cardW = math.max(12, cardW)

    local cy = 6
    local x = 3

    drawCard(x, cy, cardW, "TARGETS", info.targetCount, COLORS.green)
    x = x + cardW + gap

    drawCard(x, cy, cardW, "ACTIVE", info.activeCount, COLORS.cyan)
    x = x + cardW + gap

    drawCard(
        x,
        cy,
        cardW,
        "RAW TYPES",
        info.oreStackCount or 0,
        COLORS.amber
    )
    x = x + cardW + gap

    drawCard(
        x,
        cy,
        cardW,
        "BUS SLOTS",
        tostring(info.managedSlots) .. "/" .. tostring(info.slotCount),
        COLORS.blue
    )
    x = x + cardW + gap

    drawCard(
        x,
        cy,
        math.max(12, w - x - 2),
        "CHANGES",
        info.changes,
        info.changes > 0 and COLORS.amber or COLORS.green
    )

    -- Network strip
    local stripY = 10
    gpuFill(3, stripY, w - 4, 2, COLORS.panel2)

    gpuText(
        5,
        stripY,
        "PRODUCT " .. shortAddress(info.productAddress),
        COLORS.muted,
        COLORS.panel2
    )

    gpuText(
        math.floor(w * 0.36),
        stripY,
        "CACHE " .. shortAddress(info.cacheAddress),
        COLORS.muted,
        COLORS.panel2
    )

    gpuText(
        math.floor(w * 0.68),
        stripY,
        "BUS " .. shortAddress(info.busAddress)
            .. "  S" .. tostring(info.side),
        COLORS.muted,
        COLORS.panel2
    )

    gpuText(
        5,
        stripY + 1,
        string.format(
            "scan %d stacks · %d ores · %d aliases · %d requesters",
            info.networkStackCount or 0,
            info.oreStackCount or 0,
            info.rawAliasCount or 0,
            info.requesterCount or 0
        ),
        COLORS.muted,
        COLORS.panel2
    )

    -- Column headings
    local headerY = 13
    gpuText(4, headerY, "MATERIAL", COLORS.muted, COLORS.bg)
    gpuText(math.floor(w * 0.57), headerY, "STOCK", COLORS.muted, COLORS.bg)
    gpuText(math.floor(w * 0.77), headerY, "RAW", COLORS.muted, COLORS.bg)
    gpuText(w - 12, headerY, "STATE", COLORS.muted, COLORS.bg)

    gpuFill(3, headerY + 1, w - 4, 1, COLORS.border)

    sortForUI(states)

    local rowY = headerY + 2
    local rowH = 3
    local footerRows = 2
    local maxRows = math.max(
        1,
        math.floor((h - rowY - footerRows + 1) / rowH)
    )

    local materialW = math.max(18, math.floor(w * 0.31))
    local stockX = math.floor(w * 0.57)
    local rawX = math.floor(w * 0.77)
    local stateX = w - 12

    for i = 1, math.min(#states, maxRows) do
        local state = states[i]
        local y = rowY + (i - 1) * rowH
        local rawAmount = state.raw and state.raw.amount or 0
        local statusFg = statusColor(state.status)

        -- Alternating dark card rows
        local rowBg = (i % 2 == 1) and COLORS.panel or COLORS.panel2
        gpuFill(3, y, w - 4, 2, rowBg)

        -- Left accent indicates urgency/status, while progress remains green.
        gpuFill(3, y, 1, 2, statusFg)

        gpuText(
            5,
            y,
            fitText(state.target.label, materialW),
            COLORS.text,
            rowBg
        )

        gpuText(
            stockX,
            y,
            fmtAmount(state.current)
                .. " / "
                .. fmtAmount(state.target.goal),
            state.ratio >= 1 and COLORS.green or COLORS.text,
            rowBg
        )

        gpuText(
            rawX,
            y,
            fmtAmount(rawAmount),
            rawAmount > 0 and COLORS.text or COLORS.amber,
            rowBg
        )

        gpuText(
            stateX,
            y,
            state.status,
            statusFg,
            rowBg
        )

        -- Premium solid progress bar.
        local barX = 5
        local percentText = string.format("%5.1f%%", state.ratio * 100)
        local percentW = displayWidth(percentText)
        local barRight = stockX - 3
        local barW = math.max(12, barRight - barX - percentW - 2)

        drawSolidBar(barX, y + 1, barW, state.ratio)

        gpuText(
            barX + barW + 2,
            y + 1,
            percentText,
            state.ratio >= 1 and COLORS.green or COLORS.muted,
            rowBg
        )

        local rawLabel =
            "RAW " .. fmtAmount(rawAmount)
            .. "  ·  PRIORITY "
            .. tostring(i)

        gpuText(
            stockX,
            y + 1,
            rawLabel,
            COLORS.muted,
            rowBg
        )
    end

    -- Footer
    local footerY = h

    if #states > maxRows then
        gpuText(
            3,
            footerY,
            "Showing "
                .. tostring(maxRows)
                .. " / "
                .. tostring(#states)
                .. " targets",
            COLORS.amber,
            COLORS.bg
        )
    else
        gpuText(
            3,
            footerY,
            "AUTO REFRESH "
                .. tostring(CFG.controlInterval or 3)
                .. "s",
            COLORS.muted,
            COLORS.bg
        )
    end

    local rightFooter =
        CFG.dryRun
        and "SAFE MODE · Storage Bus writes disabled"
        or "LIVE CONTROL · Storage Bus writes enabled"

    local rfW = displayWidth(rightFooter)
    gpuText(
        math.max(3, w - rfW - 2),
        footerY,
        rightFooter,
        CFG.dryRun and COLORS.amber or COLORS.green,
        COLORS.bg
    )

    -- Restore sane terminal colors for any later error text.
    gpuColors(COLORS.text, COLORS.bg)
end

local function renderUI(states, info)
    if CFG.enableUI == false then return end

    uiInit()

    if not component.isAvailable("gpu") then
        renderTextFallback(states, info)
        return
    end

    UI.w, UI.h = component.gpu.getResolution()

    -- Fancy UI needs enough room. Smaller screens fall back safely.
    if not UI.color or UI.w < 90 or UI.h < 20 then
        renderTextFallback(states, info)
        return
    end

    renderFancyUI(states, info)
end

-- ============================================================
-- Main loop
-- ============================================================

local function main()
    validateConfig()

    local productMe, cacheMe, meInfo = resolveMeNetworks()

    local bus,
          side,
          slotCount,
          busAddress = resolveStorageBus()

    local managedSlots = CFG.managedSlots or slotCount
    managedSlots = tonumber(managedSlots) or slotCount
    managedSlots = math.min(managedSlots, slotCount)

    if managedSlots < 1 then
        error("managedSlots 必须 > 0")
    end

    print("GTNH Ore Dispatch Controller v" .. VERSION)
    print("配置: " .. tostring(loadedConfigPath))
    print("启动完成，进入 Dashboard...")
    os.sleep(1)

    while true do
        local targets, requestInfo = readTargets()

        local rawCatalog,
              cacheScanInfo = scanRawOreCatalog(cacheMe)

        local overrides = loadOverrides()

        local states = evaluateTargets(
            productMe,
            rawCatalog,
            overrides,
            targets
        )

        local selected = chooseActive(
            states,
            managedSlots
        )

        local changes = applyStorageWhitelist(
            bus,
            side,
            managedSlots,
            selected
        )

        renderUI(
            states,
            {
                productAddress = meInfo.productAddress,
                cacheAddress = meInfo.cacheAddress,
                legacyConfig = meInfo.legacyConfig,

                busAddress = busAddress,
                side = side,
                slotCount = slotCount,
                managedSlots = managedSlots,

                requesterCount = requestInfo.requesterCount,
                targetCount = requestInfo.targetCount,
                duplicateCount = requestInfo.duplicateCount,

                networkStackCount = cacheScanInfo.networkStackCount,
                oreStackCount = cacheScanInfo.oreStackCount,
                rawAliasCount = cacheScanInfo.rawAliasCount,

                activeCount = #selected,
                changes = changes,
            }
        )

        os.sleep(tonumber(CFG.controlInterval) or 3)
    end
end

local ok, err = xpcall(
    main,
    function(e)
        if debug and debug.traceback then
            return debug.traceback(e, 2)
        end
        return tostring(e)
    end
)

if not ok then
    pcall(term.clear)

    if component.isAvailable("gpu") then
        pcall(component.gpu.setBackground, 0x000000)
        pcall(component.gpu.setForeground, 0xFFFFFF)
    end

    print("GTNH Ore Dispatch Controller 已停止")
    print(err)
end
