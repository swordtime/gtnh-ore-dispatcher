-- GTNH Ore Dispatcher - ME Export Bus read-only probe
-- v0.6.1-stable
-- This tool NEVER writes configuration and NEVER exports items.

local component = require("component")

print("ME Export Bus Probe")
print("===================")

local count = 0

for address in component.list("me_exportbus") do
    count = count + 1
    print("")
    print("#" .. tostring(count) .. "  " .. tostring(address))
    print("type = " .. tostring(component.type(address)))

    local methods = component.methods(address)

    if not methods then
        print("  <无法读取 methods>")
    else
        local names = {}
        for name in pairs(methods) do
            table.insert(names, name)
        end
        table.sort(names)

        for _, name in ipairs(names) do
            local mode = methods[name]
            if mode == false then
                mode = "indirect"
            elseif mode == true then
                mode = "direct"
            else
                mode = tostring(mode)
            end

            print("  " .. name .. " = " .. mode)
        end
    end
end

if count == 0 then
    print("")
    print("未检测到 me_exportbus。")
    print("如果要实测 VOID，请先把一个独立 ME Export Bus 通过 OC 网络暴露出来。")
else
    print("")
    print("只读探测完成。请把这段输出截图给我；本工具没有执行任何导出或写配置。")
end
