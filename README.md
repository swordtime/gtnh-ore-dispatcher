# GTNH Ore Dispatcher

OpenComputers ore processing dispatcher for GTNH 2.9.

当前版本：`0.2.0`

## 目标

- 扫描多个 ME 请求器（`level_maintainer`）中的最终产物目标。
- 读取主网最终产物库存。
- 读取独立原矿缓存网。
- 通过 OreDictionary 自动关联 `dustBarium / gemRuby` 与 `oreBarium / oreRuby`。
- 用 OC 动态修改 `me_storagebus` 白名单，让集成矿石处理厂只访问当前需要处理的原矿。
- 终端 Dashboard 显示当前量、目标量、进度、原矿缓存和状态。

## 第一次安装

OC 需要 Internet Card。

```sh
wget -f https://raw.githubusercontent.com/swordtime/gtnh-ore-dispatcher/main/install.lua /tmp/ore-install.lua
/tmp/ore-install.lua
```

安装后编辑：

```sh
edit /home/ore_dispatch_config.lua
```

至少填写：

```lua
mainMeAddress = "主网二合一ME接口UUID",
cacheMeAddress = "原矿缓存网二合一ME接口UUID",
```

首次保持：

```lua
dryRun = true,
```

## 一键升级

以后只需要：

```sh
ore-update
```

强制重装当前版本：

```sh
ore-update --force
```

更新器只覆盖程序文件，不覆盖：

- `/home/ore_dispatch_config.lua`
- `/home/ore_dispatch_overrides.lua`

## 多请求器

程序扫描 OC 可见的所有 `level_maintainer`，默认每个读取 5 个槽。不同请求器可用于扩展目标数量。

同一目标重复且目标值一致：自动视为同一个目标。

同一目标重复但目标值不同：程序报配置冲突并拒绝调度，避免随机采用错误目标。

## 当前安全状态

首次部署建议 `dryRun=true`。在正式 LIVE 前，仍建议实机确认：

1. 缓存网接口 `getItemsInNetwork({})` 能扫描全部原矿。
2. `setStorageConfiguration(side, slot)` 无 descriptor 能正确清空过滤槽。
