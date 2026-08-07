-- 仅用于 OreDictionary 自动映射失败的极少数例外。
-- 正常的 Barium / Ruby / Diamond 等不需要写这里。
--
-- key 使用“归一化后的材料名”，程序会自动去空格、标点并转小写。
-- 例如 "Nether Quartz" -> "netherquartz"。
--
-- value 是要让 Storage Bus 标记的原矿描述。
-- 最稳妥的是 name + damage；label 只是为了 UI 好看。
return {
    -- 示例：
    -- ["someweirdmaterial"] = {
    --     name = "gregtech:gt.blockores",
    --     damage = 123,
    --     label = "Some Weird Ore",
    -- },
}
