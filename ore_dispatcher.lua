-- GTNH 2.9 / OpenComputers
-- 集成矿石处理厂：主网需求驱动 + 原矿缓存网 + OC 动态 Storage Bus 白名单
-- Release v0.2.0
--
-- 核心思路：
-- 1) level_maintainer 保存“最终产物 + 目标数量”。
-- 2) 主网 ME 接口读取最终产物当前库存。
-- 3) 原矿缓存网 ME 接口扫描 oreXxx 原矿并建立材料目录。
-- 4) 用 OreDictionary 的共同材料名把 dustBarium / gemRuby 与 oreBarium / oreRuby 对上。
-- 5) 只把当前需要处理的原矿动态写入 me_storagebus 过滤槽。
-- 6) 集成矿处直接从缓存网读取这些原矿，不经过 ME Interface 的 64 个小缓存。

local component = require("component")
local os = require("os")
local term = require("term")

local CONFIG_PATH = "/home/ore_dispatch_config.lua"
local FALLBACK_CONFIG_PATH = "ore_dispatch_config.lua"

local function loadLuaTable(path)
    local fn, err = loadfile(path)
    if not fn then return nil, err end
    local ok, data = pcall(fn)
    if not ok then return nil, data end
    if type(data) ~= "table" then return nil, "配置文件必须 return table" end
    return data
end

local CFG = nil
for _, path in ipairs({CONFIG_PATH, FALLBACK_CONFIG_PATH}) do
    local data = loadLuaTable(path)
    if data then
        CFG = data
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
    return a.name == b.name and (a.damage or 0) == (b.damage or 0)
end

local function fmtAmount(n)
    n = tonumber(n) or 0
    local abs = math.abs(n)
    if abs >= 1000000000 then return string.format("%.2fG", n / 1000000000) end
    if abs >= 1000000 then return string.format("%.2fM", n / 1000000) end
    if abs >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
end

local function utf8Units(s)
    local units = {}
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local n = 1
        if b and b >= 240 then n = 4
        elseif b and b >= 224 then n = 3
        elseif b and b >= 192 then n = 2 end
        local ch = s:sub(i, math.min(#s, i + n - 1))
        local w = (b and b >= 192) and 2 or 1
        table.insert(units, {ch = ch, width = w})
        i = i + n
    end
    return units
end

local function fitText(s, width)
    s = tostring(s or "")
    local units = utf8Units(s)
    local total = 0
    for _, u in ipairs(units) do total = total + u.width end
    if total <= width then return s .. string.rep(" ", width - total) end

    local limit = math.max(0, width - 3)
    local out, used = {}, 0
    for _, u in ipairs(units) do
        if used + u.width > limit then break end
        table.insert(out, u.ch)
        used = used + u.width
    end
    return table.concat(out) .. "..." .. string.rep(" ", math.max(0, width - used - 3))
end

local function progressBar(ratio, width)
    width = width or 18
    local shown = clamp(ratio or 0, 0, 1)
    local full = math.floor(shown * width + 0.5)
    return "[" .. string.rep("#", full) .. string.rep(".", width - full) .. "]"
end

local function collectAddresses(typeName)
    local result = {}
    for address in component.list(typeName) do
        table.insert(result, address)
    end
    return result
end

local function allMeAddresses()
    local result, seen = {}, {}
    for _, t in ipairs({"me_interface", "fluid_interface"}) do
        for _, address in ipairs(collectAddresses(t)) do
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

local function resolveStorageBus()
    local address = CFG.storageBusAddress
    if not address then
        local buses = collectAddresses("me_storagebus")
        if #buses == 0 then error("未检测到 me_storagebus") end
        if #buses > 1 then
            error("检测到多个 me_storagebus，请在配置文件填写 storageBusAddress")
        end
        address = buses[1]
    end

    local bus = requireProxy(address, "Storage Bus")
    local side = CFG.storageSide

    if side == nil then
        for s = 0, 5 do
            local ok, count = pcall(bus.getStorageSlotSize, s)
            if ok and type(count) == "number" and count > 0 then
                side = s
                break
            end
        end
    end

    if side == nil then error("无法自动识别 Storage Bus side") end

    local ok, slotCount = pcall(bus.getStorageSlotSize, side)
    if not ok then error("Storage Bus side 无效: " .. tostring(side)) end

    return bus, side, slotCount, address
end

local function resolveMeNetworks()
    -- 两个网络使用相同 component 类型，因此不能靠 component 类型区分“主网”和“缓存网”。
    -- 正式部署建议固定 UUID；这里在只有两个且未配置时拒绝猜顺序。
    local addresses = allMeAddresses()

    if not CFG.mainMeAddress or not CFG.cacheMeAddress then
        local lines = {"需要在 ore_dispatch_config.lua 指定 mainMeAddress / cacheMeAddress。", "当前可见 ME 接口:"}
        for _, a in ipairs(addresses) do table.insert(lines, "  " .. a) end
        error(table.concat(lines, "\n"))
    end

    if CFG.mainMeAddress == CFG.cacheMeAddress then
        error("mainMeAddress 与 cacheMeAddress 不能相同；它们必须分别属于主网与原矿缓存网")
    end

    return requireProxy(CFG.mainMeAddress, "主网 ME"), requireProxy(CFG.cacheMeAddress, "缓存网 ME")
end

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
    local targets, byKey = {}, {}
    local requesterCount = 0
    local conflicts = {}

    for address in component.list("level_maintainer") do
        requesterCount = requesterCount + 1
        local maintainer = component.proxy(address)
        for slot = 1, (CFG.requesterSlots or 5) do
            local ok, data = pcall(maintainer.getSlot, slot)
            if ok and data and data.isEnable and not data.isFluid then
                local t = parseTargetItem(data)
                if t and t.goal > 0 then
                    t.requesterAddress = address
                    t.requesterSlot = slot
                    local previous = byKey[t.key]
                    if not previous then
                        byKey[t.key] = t
                        table.insert(targets, t)
                    elseif previous.goal ~= t.goal then
                        table.insert(conflicts, string.format(
                            "%s: %s[%d]=%s, %s[%d]=%s",
                            t.label,
                            tostring(previous.requesterAddress), previous.requesterSlot or -1, fmtAmount(previous.goal),
                            tostring(address), slot, fmtAmount(t.goal)
                        ))
                    end
                    -- 完全相同的重复项视为同一个目标，不重复加入。
                end
            end
        end
    end

    if requesterCount == 0 then
        error("未检测到 level_maintainer；本程序使用 ME 请求器保存最终产物目标")
    end

    if #conflicts > 0 then
        error("检测到重复目标且目标值冲突，请删除重复配置或统一目标值：\n  " .. table.concat(conflicts, "\n  "))
    end

    return targets
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

local TARGET_OREDICT_PREFIXES = {
    "gemExquisite", "gemFlawless", "gemFlawed", "gemChipped",
    "dustTiny", "dustSmall", "dust",
    "gem", "ingot", "plate", "crystal", "block",
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

local function getAllNetworkItems(me)
    -- 2.9 二合一接口已实测有 getItemsInNetwork。
    -- 使用空过滤器扫描专用原矿缓存网；缓存网应尽量只放矿石类物品。
    local ok, items = pcall(me.getItemsInNetwork, {})
    if ok and type(items) == "table" then return items end

    -- 某些实现允许无参数调用，作为兼容回退。
    ok, items = pcall(me.getItemsInNetwork)
    if ok and type(items) == "table" then return items end

    error("无法扫描缓存网物品: " .. tostring(items))
end

local function scanRawOreCatalog(cacheMe)
    local catalog = {}

    for _, stack in ipairs(getAllNetworkItems(cacheMe)) do
        if stack and (stack.size or 0) > 0 then
            for _, oreName in ipairs(stack.oreNames or {}) do
                local material = oreName:match("^ore(.+)$")
                if material then
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
                        -- setStorageConfiguration(detail) 已实测接受完整 item detail。
                        row.best = stack
                        row.oreName = oreName
                    end
                end
            end
        end
    end

    return catalog
end

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

local demandMemory = {}

local function evaluateTargets(mainMe, rawCatalog, overrides, targets)
    local states = {}

    for _, target in ipairs(targets) do
        local current, exemplar, err = getExactAmount(mainMe, target)
        if current == nil then
            error("读取主网目标失败 " .. target.label .. ": " .. tostring(err))
        end

        local ratio = target.goal > 0 and current / target.goal or 0

        -- 识别最终产物所属材料：优先 OreDictionary，其次请求器数据，最后 label。
        local materialKey, materialName, source = nil, nil, nil

        if exemplar then
            materialKey, materialName, source = materialFromOreNames(exemplar.oreNames)
        end
        if not materialKey and target.oreNames then
            materialKey, materialName, source = materialFromOreNames(target.oreNames)
        end
        if not materialKey then
            materialKey, materialName, source = materialFromLabel(target.label)
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
            materialSource = source,
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

    table.sort(candidates, function(a, b)
        if a.ratio == b.ratio then
            return tostring(a.target.label) < tostring(b.target.label)
        end
        return a.ratio < b.ratio
    end)

    local limit = math.min(CFG.maxActive or slotLimit, slotLimit)
    local selected = {}
    local seenItem = {}

    for _, state in ipairs(candidates) do
        if #selected >= limit then break end
        local id = itemId(state.raw.best)
        if id and not seenItem[id] then
            seenItem[id] = true
            state.selected = true
            state.status = "处理中"
            table.insert(selected, state)
        end
    end

    return selected
end

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
        else
            if current ~= nil then
                changes = changes + 1
                if not CFG.dryRun then
                    -- API 文档中 database / detail 参数均为可选；无 descriptor 用于清空该过滤槽。
                    -- 正式上线前建议单独实测一次清空行为。
                    local clearOk, result = pcall(bus.setStorageConfiguration, side, slot)
                    if not clearOk or result ~= true then
                        error("清空 Storage Bus 槽 " .. tostring(slot) .. " 失败: " .. tostring(result))
                    end
                end
            end
        end
    end

    return changes
end

local function sortForUI(states)
    table.sort(states, function(a, b)
        if CFG.uiSort == "name" then
            return tostring(a.target.label) < tostring(b.target.label)
        end
        if a.ratio == b.ratio then
            return tostring(a.target.label) < tostring(b.target.label)
        end
        return a.ratio < b.ratio
    end)
end

local function renderUI(states, info)
    if CFG.enableUI == false then return end
    term.clear()
    term.setCursor(1, 1)

    print("GTNH Ore Dispatch Controller  v0.2.0")
    print(string.format("主网需求 -> 原矿缓存 -> Storage Bus -> 集成矿处    %s", CFG.dryRun and "[DRY RUN]" or "[LIVE]"))
    print(string.format("Bus side=%d  slots=%d  managed=%d  active=%d  changes=%d",
        info.side, info.slotCount, info.managedSlots, info.activeCount, info.changes))
    print(string.rep("=", 96))
    print("目标产物                  当前 / 目标          进度                  原矿缓存      状态")
    print(string.rep("-", 96))

    sortForUI(states)

    local _, h = component.gpu.getResolution()
    local maxRows = math.max(1, h - 7)
    for i = 1, math.min(#states, maxRows) do
        local s = states[i]
        local rawAmount = s.raw and s.raw.amount or 0
        local line = string.format(
            "%s %8s / %-8s %s %6.1f%%  %10s  %s",
            fitText(s.target.label, 24),
            fmtAmount(s.current),
            fmtAmount(s.target.goal),
            progressBar(s.ratio, CFG.progressBarWidth or 18),
            s.ratio * 100,
            fmtAmount(rawAmount),
            s.status
        )
        print(line)
    end

    if #states > maxRows then
        print(string.format("... 还有 %d 项未显示（后续版本可做分页/滚动）", #states - maxRows))
    end
end

local function main()
    local mainMe, cacheMe = resolveMeNetworks()
    local bus, side, slotCount, busAddress = resolveStorageBus()

    local managedSlots = CFG.managedSlots or slotCount
    managedSlots = math.min(managedSlots, slotCount)
    if managedSlots < 1 then error("managedSlots 必须 > 0") end

    print("Ore Dispatch Controller 启动")
    print("Storage Bus: " .. tostring(busAddress) .. " side=" .. tostring(side) .. " slots=" .. tostring(slotCount))
    os.sleep(1)

    while true do
        local targets = readTargets()
        local rawCatalog = scanRawOreCatalog(cacheMe)
        local overrides = loadOverrides()
        local states = evaluateTargets(mainMe, rawCatalog, overrides, targets)
        local selected = chooseActive(states, managedSlots)
        local changes = applyStorageWhitelist(bus, side, managedSlots, selected)

        renderUI(states, {
            side = side,
            slotCount = slotCount,
            managedSlots = managedSlots,
            activeCount = #selected,
            changes = changes,
        })

        os.sleep(CFG.controlInterval or 3)
    end
end

local ok, err = xpcall(main, function(e)
    if debug and debug.traceback then return debug.traceback(e, 2) end
    return tostring(e)
end)

if not ok then
    pcall(term.clear)
    print("Ore Dispatch Controller 已停止")
    print(err)
end
