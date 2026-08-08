-- GTNH Ore Dispatcher launcher
-- Installed as /bin/ore.lua
-- Usage: ore

local PROGRAM = "/home/ore_dispatcher.lua"

local fn, err = loadfile(PROGRAM)
if not fn then
    io.stderr:write("无法启动 Ore Dispatcher: " .. tostring(err) .. "\n")
    io.stderr:write("请确认 " .. PROGRAM .. " 已安装。\n")
    return false
end

return fn(...)
