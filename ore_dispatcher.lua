-- GTNH 2.9 / OpenComputers
-- GTNH Ore Dispatch Controller
-- Release v0.3.0
--
-- 专用成品网架构：
--
--   请求器（最终产物目标）
--          |
--          v
--   [矿处成品网] <------ 集成矿石处理厂
--          ^                    ^
--          |                    |
--      主网消费             矿处处理网
--                               ^
--                               |
--                       OC 控制 Storage Bus
--                               ^
--                               |
--                        [原矿缓存网]
--
-- 核心逻辑：
-- 1) 自动扫描所有 level_maintainer，读取最终产物目标。
-- 2) productMeAddress 只读取“矿处成品网”中的目标库存。
-- 3) cacheMeAddress 扫描独立原矿缓存网。
-- 4) 用 OreDictionary 共同材料键自动关联：
--      dustBarium <-> Barium <-> oreBarium
--      gemRuby    <-> Ruby    <-> oreRuby
-- 5) 根据最终产物缺口选择当前需要处理的原矿。
-- 6) 用 setStorageConfiguration() 动态修改 me_storagebus 白名单。
-- 7) 支持多请求器、重复目标冲突保护、滞回控制、Dashboard。
--
-- v0.3 兼容 v0.2 本地配置：
-- 如果旧配置仍使用 mainMeAddress，程序会把它当作 productMeAddress 使用，
-- 但建议以后手动改名以免混淆。

local component = require("component")
local os = require("os")
local term = require("term")

local VERSION = "0.3.0"

local CONFIG_PATH = "/home/ore_dispatch_config.lua"
local FALLBACK_CONFIG_PATH = "ore_dispatch_config.lua"

-- ============================================================
-- 基础工具
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
    end

    if abs >= 1000000 then
        return string.format("%.2fM", n / 1000000)
    end

    if abs >= 1000 then
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

        table.insert(units, {
            ch = ch,
            width = w,
        })

        i = i + n
    end

    return units
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

local function progressBar(ratio, width)
    width = width or 18

    local shown = clamp(ratio or 0, 0, 1)
    local full = math.floor(shown * width + 0.5)

    return "["
        .. string.rep("#", full)
        .. string.rep(".", width - full)
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

    for _, componentType in ipairs({
        "me_interface",
        "fluid_interface",
    }) do
        for _, address in ipairs(collectAddresses(componentType)) do
            if not seen[address] then
                seen[address] = true
                table.insert(result, address)
            end
        end
    end

    return result
end

local function requireProxy(address, role)
    if not address then
        error(role .. " 地址未配置")
    end

    local ok, proxy = pcall(component.proxy, address)

    if not ok or not proxy then
        error(role .. " 无法连接: " .. tostring(address))
    end

    return proxy
end

local function hasMethod(proxy, name)
    return proxy and type(proxy[name]) == "function"
end

local function validateMeProxy(proxy, role)
    if not hasMethod(proxy, "getItemsInNetwork") then
        error(role .. " 不提供 getItemsInNetwork()")
    end
end

local function validateConfig()
    local reopen = tonumber(CFG.reopenRatio) or 0.95
    local stop = tonumber(CFG.stopRatio) or 1.00

    if reopen <= 0 then
        error("reopenRatio 必须 > 0")
    end

    if stop <= 0 then
        error("stopRatio 必须 > 0")
    end

    if reopen > stop then
        error("reopenRatio 不能大于 stopRatio")
    end

    local interval = tonumber(CFG.controlInterval) or 3
    if interval < 1 then
        error("controlInterval 建议至少为 1 秒")
    end

    local maxActive = tonumber(CFG.maxActive) or 12
    if maxActive < 1 then
        error("maxActive 必须 >= 1")
    end

    local requesterSlots = tonumber(CFG.requesterSlots) or 5
    if requesterSlots < 1 then
        error("requesterSlots 必须 >= 1")
    end
end

-- ============================================================
-- 网络 / Storage Bus 解析
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

    local bus = requireProxy(address, "Storage Bus")

    if not hasMethod(bus, "getStorageSlotSize") then
        error("Storage Bus 不提供 getStorageSlotSize()")
    end

    if not hasMethod(bus, "getStorageConfiguration") then
        error("Storage Bus 不提供 getStorageConfiguration()")
    end

    if not hasMethod(bus, "setStorageConfiguration") then
        error("Storage Bus 不提供 setStorageConfiguration()")
    end

    local side = CFG.storageSide

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
        error("无法自动识别 Storage Bus side")
    end

    local ok, slotCount = pcall(
        bus.getStorageSlotSize,
        side
    )

    if not ok then
        error("Storage Bus side 无效: " .. tostring(side))
    end

    if type(slotCount) ~= "number" or slotCount < 1 then
        error("Storage Bus 返回的槽位数量异常: " .. tostring(slotCount))
    end

    return bus, side, slotCount, address
end

local function resolveMeNetworks()
    -- v0.3 正式名称：productMeAddress
    -- v0.2 兼容：mainMeAddress
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

    local productMe = requireProxy(
        productAddress,
        "成品网 ME"
    )

    local cacheMe = requireProxy(
        cacheAddress,
        "缓存网 ME"
    )

    validateMeProxy(productMe, "成品网 ME")
    validateMeProxy(cacheMe, "缓存网 ME")

    return productMe, cacheMe, {
        productAddress = productAddress,
        cacheAddress = cacheAddress,
        legacyConfig = legacyConfig,
    }
end

-- ============================================================
-- 请求器
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

    target.key = target.name
        .. ":"
        .. tostring(target.damage or 0)

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

        local maintainer = component.proxy(address)

        for slot = 1, slotsPerRequester do
            local ok, data = pcall(
                maintainer.getSlot,
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
        error(
            "未检测到 level_maintainer；"
            .. "本程序使用 ME 请求器保存最终产物目标"
        )
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
-- 成品库存
-- ============================================================

local function getExactAmount(me, target)
    local filter = {
        name = target.name,
    }

    if target.damage and target.damage > 0 then
        filter.damage = target.damage
    end

    local ok, items = pcall(
        me.getItemsInNetwork,
        filter
    )

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
-- OreDictionary / 材料识别
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

                return
                    normalizeMaterial(material),
                    material,
                    oreName
            end
        end
    end

    return nil
end

local function materialFromLabel(label)
    if type(label) ~= "string" then
        return nil
    end

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
            material = material:sub(
                1,
                #material - #suffix
            )
            break
        end
    end

    return
        normalizeMaterial(material),
        material,
        "label-fallback"
end

-- ============================================================
-- 原矿缓存扫描
-- ============================================================

local function getAllNetworkItems(me)
    -- 第一优先：
    -- GTNH 2.9 二合一接口的 getItemsInNetwork({})
    local ok, items = pcall(
        me.getItemsInNetwork,
        {}
    )

    if ok and type(items) == "table" then
        return items
    end

    -- 兼容回退：部分实现允许无参数。
    ok, items = pcall(
        me.getItemsInNetwork
    )

    if ok and type(items) == "table" then
        return items
    end

    error(
        "无法扫描原矿缓存网全部物品: "
        .. tostring(items)
    )
end

local function scanRawOreCatalog(cacheMe)
    local catalog = {}
    local stackCount = 0
    local oreStackCount = 0

    for _, stack in ipairs(getAllNetworkItems(cacheMe)) do
        if stack and (stack.size or 0) > 0 then
            stackCount = stackCount + 1

            for _, oreName in ipairs(stack.oreNames or {}) do
                local material = oreName:match("^ore(.+)$")

                if material then
                    oreStackCount = oreStackCount + 1

                    local key = normalizeMaterial(material)
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

                        -- setStorageConfiguration(detail)
                        -- 已由用户实机验证可写入。
                        row.best = stack
                        row.oreName = oreName
                    end
                end
            end
        end
    end

    return catalog, {
        networkStackCount = stackCount,
        oreStackCount = oreStackCount,
    }
end

-- ============================================================
-- 特殊覆盖
-- ============================================================

local function loadOverrides()
    local path = CFG.overrideFile

    if not path then
        return {}
    end

    local f = io.open(path, "r")

    if not f then
        return {}
    end

    f:close()

    local data, err = loadLuaTable(path)

    if not data then
        error(
            "例外映射文件读取失败: "
            .. tostring(err)
        )
    end

    return data
end

-- ============================================================
-- 调度
-- ============================================================

local demandMemory = {}

local function evaluateTargets(
    productMe,
    rawCatalog,
    overrides,
    targets
)
    local states = {}

    for _, target in ipairs(targets) do
        local current, exemplar, err = getExactAmount(
            productMe,
            target
        )

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

        -- 识别目标材料：
        -- 1) 成品网现有 ItemStack 的 OreDictionary
        -- 2) 请求器槽位数据中的 oreNames
        -- 3) label 回退
        local materialKey = nil
        local materialName = nil
        local materialSource = nil

        if exemplar then
            materialKey,
            materialName,
            materialSource = materialFromOreNames(
                exemplar.oreNames
            )
        end

        if not materialKey and target.oreNames then
            materialKey,
            materialName,
            materialSource = materialFromOreNames(
                target.oreNames
            )
        end

        if not materialKey then
            materialKey,
            materialName,
            materialSource = materialFromLabel(
                target.label
            )
        end

        local raw = nil

        if materialKey then
            raw = rawCatalog[materialKey]
        end

        -- 特殊覆盖只影响“该材料应该开放哪个原矿”。
        if materialKey and overrides[materialKey] then
            raw = {
                material = materialName or materialKey,

                -- 若缓存目录中能找到同材料，则沿用真实原矿总量。
                -- 找不到时 amount=0，UI 会显示等待原矿。
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
        if #selected >= limit then
            break
        end

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
-- Storage Bus 白名单
-- ============================================================

local function applyStorageWhitelist(
    bus,
    side,
    managedSlots,
    selected
)
    local desired = {}

    for _, state in ipairs(selected) do
        table.insert(
            desired,
            state.raw.best
        )
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
                    -- API 文档显示 descriptor 为可选参数。
                    -- 无 descriptor 用于清空过滤槽。
                    -- 正式 LIVE 前仍建议先完成一次实机清空测试。
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
-- Dashboard
-- ============================================================

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

local function renderUI(states, info)
    if CFG.enableUI == false then
        return
    end

    pcall(term.clear)
    pcall(term.setCursor, 1, 1)

    print(
        "GTNH Ore Dispatch Controller  v"
        .. VERSION
    )

    print(
        string.format(
            "成品网 %s | 缓存网 %s | %s",
            shortAddress(info.productAddress),
            shortAddress(info.cacheAddress),
            CFG.dryRun and "[DRY RUN]" or "[LIVE]"
        )
    )

    print(
        string.format(
            "StorageBus %s side=%d slots=%d managed=%d | 请求器=%d 目标=%d | active=%d changes=%d",
            shortAddress(info.busAddress),
            info.side,
            info.slotCount,
            info.managedSlots,
            info.requesterCount,
            info.targetCount,
            info.activeCount,
            info.changes
        )
    )

    if info.legacyConfig then
        print(
            "[兼容提示] 当前仍使用旧字段 mainMeAddress；"
            .. "建议以后改名为 productMeAddress。"
        )
    else
        print(
            string.format(
                "缓存扫描: 网络物品栈=%d 原矿匹配=%d | 重复目标=%d",
                info.networkStackCount or 0,
                info.oreStackCount or 0,
                info.duplicateCount or 0
            )
        )
    end

    print(string.rep("=", 104))
    print(
        "目标产物                  当前 / 目标          进度                  原矿缓存      状态"
    )
    print(string.rep("-", 104))

    sortForUI(states)

    local maxRows = #states

    if component.isAvailable("gpu") then
        local _, height = component.gpu.getResolution()
        maxRows = math.max(1, height - 8)
    end

    for i = 1, math.min(#states, maxRows) do
        local state = states[i]

        local rawAmount = 0
        if state.raw then
            rawAmount = state.raw.amount or 0
        end

        local line = string.format(
            "%s %8s / %-8s %s %6.1f%%  %10s  %s",
            fitText(state.target.label, 24),
            fmtAmount(state.current),
            fmtAmount(state.target.goal),
            progressBar(
                state.ratio,
                CFG.progressBarWidth or 18
            ),
            state.ratio * 100,
            fmtAmount(rawAmount),
            state.status
        )

        print(line)
    end

    if #states > maxRows then
        print(
            string.format(
                "... 还有 %d 项未显示",
                #states - maxRows
            )
        )
    end
end

-- ============================================================
-- 主循环
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
    managedSlots = math.min(
        managedSlots,
        slotCount
    )

    if managedSlots < 1 then
        error("managedSlots 必须 > 0")
    end

    print("==============================================")
    print("GTNH Ore Dispatch Controller v" .. VERSION)
    print("==============================================")
    print("配置: " .. tostring(loadedConfigPath))
    print(
        "成品网: "
        .. tostring(meInfo.productAddress)
    )
    print(
        "缓存网: "
        .. tostring(meInfo.cacheAddress)
    )
    print(
        "Storage Bus: "
        .. tostring(busAddress)
        .. " side="
        .. tostring(side)
        .. " slots="
        .. tostring(slotCount)
    )
    print(
        "模式: "
        .. (CFG.dryRun and "DRY RUN" or "LIVE")
    )

    if meInfo.legacyConfig then
        print(
            "提示: 旧配置 mainMeAddress 已自动兼容为 productMeAddress"
        )
    end

    print("启动完成，开始调度...")
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

                activeCount = #selected,
                changes = changes,
            }
        )

        os.sleep(
            tonumber(CFG.controlInterval) or 3
        )
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
    print("GTNH Ore Dispatch Controller 已停止")
    print(err)
end
