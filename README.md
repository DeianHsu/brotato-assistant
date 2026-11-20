# 土豆兄弟助手（brotato-assistant）

《土豆兄弟》（Brotato）的 Windows 单人模组，提供自动走位、构筑建议和商店交易。可选的自动开局模式会处理战后奖励，并用尚未通关的角色挑战难度 5。

助手版本 **0.32.18**，适用 Steam 游戏版本 **1.2.0.1** 和 **1.2.0.3**，兼容模组加载器（ModLoader）**6.3.0**。支持本体和已安装的可下载内容（DLC）。

## 安装与卸载

1. 退出游戏，双击安装目录里的 `Potato-AutoBuild-Setup.exe`。这个程序可以单独复制到任意目录运行。
2. 确认程序找到的游戏目录，或通过「浏览」选择包含 `Brotato.exe` 的文件夹。可在 Steam 库通过游戏的「管理 → 浏览本地文件」找到它。
3. 点击「安装 / 更新」。安装完成后，从 Steam 启动游戏，按 **Alt+2** 查看助手预览。已有其他自动走位模组时，先在加载器配置中停用它。

卸载时退出游戏，打开同一个程序，选择游戏目录并点击「卸载」。程序会删除助手文件和它的自动加载入口，保留游戏存档和其他模组的配置。

从源码安装或卸载也可在仓库根目录使用以下 PowerShell 命令，将 `-GamePath` 换成实际游戏目录。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -GamePath 'C:\SteamLibrary\steamapps\common\Brotato'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -GamePath 'C:\SteamLibrary\steamapps\common\Brotato'
```

安装使用游戏目录内的 `override.cfg` 加载模组，源码位于 `mods-unpacked/Potato-AutoBuild/`。

## 手动开局与自动开局

**手动开局**时，你选择角色、初始武器和难度，并确认战利品、加点、开波和死亡重试。助手默认接管走位，并在商店处理购买、换装、锁定和刷新。武器沿用游戏的自动瞄准。

**自动开局**可在主菜单、选角页或结算页按 **Alt+5** 启动。助手挑选已解锁且尚未通关的角色，带上可用的初始武器进入难度 5。右下角显示「自动开局已开启」。战后由助手确认可自动处理的战利品和加点，购物后进入下一波。

同一波前四次阵亡会重试，第五次阵亡后换一位尚未通关的角色。没有合适的角色时，界面会提示原因。选角读取当前存档槽里的游戏通关记录，任一地图、任一难度的胜利都计入。所有角色通关后，循环停在结算页。

需要固定最后挑战的角色时，可在游戏进程的环境变量 `POTATO_LAST_CHARACTER` 中填入角色编号，例如 `character_masochist`。其余角色通关后，该角色才进入候选。

## 快捷键

| 操作 | 键盘 | Xbox 手柄 |
| --- | --- | --- |
| 执行本页建议 | Alt+1 | 按住右摇杆（RS）＋十字键右 |
| 查看本页建议 | Alt+2 | 按住右摇杆（RS）＋十字键上 |
| 显示或隐藏日志 | Alt+3 | 按住右摇杆（RS）＋十字键下 |
| 暂停或恢复自动操作 | Alt+4 | 按住右摇杆（RS）＋十字键左 |
| 开始难度 5 自动局 | Alt+5 | |
| 单独开关自动走位 | Shift+空格 | |

执行键在商店进行本页推荐交易，在奖励界面处理当前一件宝箱或一级属性。预览和执行都使用当前货架、装备与余额。

## 评分与日志

助手根据职业限制、属性收益倍率、武器缩放、套装、敌群压力和剩余波次评估构筑。购买、换装、留钱和刷新同时考虑当前补强、预期收益和可用预算。屏幕日志默认隐藏，打开后可以查看选择理由、花费和本页计算耗时。

快捷键和自动操作设置保存在 `%APPDATA%\Brotato\potato_autobuy.cfg`，文件日志位于 `%APPDATA%\Brotato\potato_autobuy.log`。修改配置前请退出游戏。

命中覆盖、战斗接触和未来收益使用估计。角色或效果需要手动处理时，助手会显示原因。自动局中可回收的未估值宝箱按游戏给出的价格回收。多人模式、无尽模式和第三方内容模组暂未适配。

- 查看各角色支持的效果、估值近似和手动操作条件。 [角色机制覆盖](docs/角色机制覆盖.md)
- 查阅游戏 1.2.0.1 本体与免费更新的计算说明、参数表和效果索引。 [原生计算档案](reference/native-calculation/1.2.0.1/原生公式.md)

## 生成安装目录

在 Windows 上从源码根目录运行以下命令。安装目录生成在 `dist/Potato-AutoBuild-<版本>/`，内含可独立运行的 `Potato-AutoBuild-Setup.exe`。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package.ps1
```
