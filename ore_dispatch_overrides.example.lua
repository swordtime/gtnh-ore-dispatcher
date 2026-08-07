-- GTNH Ore Dispatcher v0.3.0
-- 特殊矿物覆盖配置
--
-- 正常材料无需填写：
--   dustBarium -> Barium -> oreBarium
--   gemRuby    -> Ruby    -> oreRuby
--
-- key:
--   归一化材料名（小写、去空格、去标点）
--
-- value:
--   Storage Bus 最终应标记的“原矿”物品描述。
--
-- 只有自动映射失败时才添加这里，主程序无需修改。

return {
    -- 示例：
    --
    -- ["someweirdmaterial"] = {
    --     name = "gregtech:gt.blockores",
    --     damage = 123,
    --     label = "Some Weird Ore",
    -- },
}
