-- GTNH Ore Dispatcher - Storage Bus read-only probe
-- v0.7.0-rc1
-- NEVER writes or clears any filter.

local component = require("component")

print("Storage Bus Probe")
print("=================")

local count = 0

for address in component.list("me_storagebus") do
    count = count + 1

    print("")
    print("#" .. tostring(count))
    print("UUID = " .. tostring(address))
    print("type = " .. tostring(component.type(address)))

    local methods = component.methods(address)

    if not methods
       or methods.getStorageSlotSize == nil
       or methods.getStorageConfiguration == nil
    then
        print("  缺少可读 Storage Bus API")
    else
        for side = 0, 5 do
            local ok, slots = pcall(
                component.invoke,
                address,
                "getStorageSlotSize",
                side
            )

            if ok
               and type(slots) == "number"
               and slots > 0
            then
                print(
                    "  side="
                    .. tostring(side)
                    .. " slots="
                    .. tostring(slots)
                )

                local nonEmpty = 0

                for slot = 0, slots - 1 do
                    local okSlot, item = pcall(
                        component.invoke,
                        address,
                        "getStorageConfiguration",
                        side,
                        slot
                    )

                    if okSlot and item then
                        nonEmpty = nonEmpty + 1

                        if nonEmpty <= 12
                           or slot == slots - 1
                        then
                            print(
                                "    GUI "
                                .. tostring(slot + 1)
                                .. ": "
                                .. tostring(item.label or item.name or "?")
                                .. " ["
                                .. tostring(item.name or "?")
                                .. ":"
                                .. tostring(item.damage or 0)
                                .. "]"
                            )
                        end
                    end
                end

                print(
                    "  configured="
                    .. tostring(nonEmpty)
                    .. " / "
                    .. tostring(slots)
                )
            end
        end
    end
end

if count == 0 then
    print("")
    print("未检测到 me_storagebus。")
else
    print("")
    print("只读探测完成。")
    print("请根据 UUID 区分 PROCESS 与 OVERFLOW 总线。")
    print("本工具没有执行任何写入或清空。")
end
