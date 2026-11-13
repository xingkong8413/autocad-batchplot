# BatchPlot —— AutoCAD 批量打印插件（批量输出 PDF）

纯 AutoLISP 实现的 AutoCAD 批量打印工具：不用安装程序、不用编译，加载一个 `.lsp` 就能用。

- 适用：**AutoCAD 2010 及以上 Windows 完整版**（AutoCAD LT 无 AutoLISP，用不了）
- 输出：**PDF**（走内置 `DWG To PDF.pc3` 虚拟打印机）
- 两种模式：当前图纸的**全部布局**、**整个文件夹**内所有 DWG（可选含子文件夹）

---

## 一、文件清单

| 文件 | 说明 |
|---|---|
| `BatchPlot.lsp` | 插件主程序 |
| `tools/to-gbk.ps1` | 把源码转成 GBK/ANSI（中文版 AutoCAD 使用前跑一次） |
| `README.md` | 本说明 |

设置保存在注册表 `HKEY_CURRENT_USER\Software\Doubao\BatchPlot`（不是配置文件），所以插件放哪个目录都能用，也不怕路径带中文。

### 编码说明（重要）

AutoCAD 读 `.lsp` 用的是系统 ANSI 代码页（中文 Windows 为 GBK），UTF-8 源码里的中文会乱码。仓库里的 `BatchPlot.lsp` 为便于在 GitHub 上查看，存的是 **UTF-8**；下载后请执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\to-gbk.ps1 .\BatchPlot.lsp
```

转换后文件即为 GBK，可直接 `APPLOAD`。已随本地交付的 GBK 版本无需转换。

---

## 二、安装

1. AutoCAD 命令行输入 `APPLOAD`（菜单：工具 → 加载应用程序）。
2. 选择 `BatchPlot.lsp` → 「加载」。看到 `BatchPlot 1.00 已加载。输入 BP / BPF / BPSET / BPHELP 使用。` 即成功。
3. 想每次开 CAD 自动加载：在 APPLOAD 对话框右下角「启动组」把该文件加进去。

---

## 三、快速上手（3 步）

```
BPSET   → 设置纸张、比例、输出目录等（回车即保持当前值）
BP      → 当前图纸所有布局 → PDF，输出到 <图纸目录>\PDF
BPF     → 输入目标文件夹（回车 = 当前图纸目录）→ 整目录 DWG 批量出 PDF
```

**先拿一张图纸跑 `BP` 验证**，确认纸张、比例、PDF 内容都对，再用 `BPF` 跑整目录。

---

## 四、命令

| 命令 | 作用 |
|---|---|
| `BP` | 当前图纸所有布局逐个输出 PDF |
| `BPF` | 指定文件夹内所有 `.dwg` 逐个批量输出 PDF（可含子文件夹） |
| `BPSET` | 查看/修改设置（存注册表） |
| `BPHELP` | 命令行帮助 |

---

## 五、输出规则

- 文件名：`前缀 + 图纸名 + "-" + 布局名 + 后缀 + .pdf`
- 同名 PDF 已存在时自动追加 `(1)`、`(2)`，**绝不覆盖**已有文件
- 默认输出目录：`BP` → 当前图纸所在目录下的 `PDF` 子目录；`BPF` → 被处理文件夹下的 `PDF` 子目录
- 每次运行生成日志 `批量打印日志_年-月-日_时分秒.txt`，逐条记录 时间 / 图纸 / 布局 / PDF 路径 / 结果

---

## 六、设置项（`BPSET` 改，或直接改注册表）

| 键 | 默认 | 取值与说明 |
|---|---|---|
| `PAPER` | `AUTO` | `AUTO` = 沿用各布局原有纸张（最安全）；也可填 `A0/A1/A2/A3/A4/LETTER` 统一幅面 |
| `SCALE` | `LAYOUT` | `LAYOUT` = 沿用布局原有比例；`FIT` = 布满图纸 |
| `STYLESHEET` | 空 | `.ctb/.stb` 完整路径；空 = 沿用布局原有样式表 |
| `OUTDIR` | 空 | 空 = 源目录下 `PDF`；`AUTO` = 源目录本身；也可填绝对路径 |
| `INCMODEL` | `1` | 是否包含模型空间 |
| `SKIPEMPTY` | `1` | 跳过空布局（无任何对象） |
| `SUB` | `0` | `BPF` 是否递归子文件夹 |
| `PREFIX` | 空 | 文件名前缀 |
| `SUFFIX` | 空 | 文件名后缀 |
| `OPEN` | `1` | 完成后自动打开输出目录 |
| `ENGINE` | `COM` | 出图引擎：`COM` = ActiveX `PlotToFile`；`PLOT` = `-PLOT` 命令行（前者卡住时切换） |

纸张尺寸名采用「候选名 + 设置后回读校验」，中英文版 AutoCAD 都能命中；改不到就沿用原纸张，不会把图打废。

---

## 七、工作原理

1. 遍历目标文档的 `Layouts` 集合（模型空间本身也是一个 Layout）。
2. 每个布局：换打印设备为 `DWG To PDF.pc3` → 按设置选纸张 → 可选设样式表 / 布满图纸；打印区域、旋转、着色打印未指定时沿用该布局原页面设置。
3. 出图：默认 ActiveX `Layout.PlotToFile` 直接写 PDF，不弹对话框；`ENGINE=PLOT` 时走 `-PLOT`，全部回车沿用现有页面设置。
4. `BPF` 用 `Documents.Open` 逐个打开 DWG，出图后**不保存直接关闭**，源图不被改动。
5. 全程 `BACKGROUNDPLOT=0`（同步出图）、`PROXYNOTICE=0`（不弹代理对象提示），结束或出错都恢复原值。

---

## 八、常见问题

1. **纸张变了，图被裁切或缩小**：插件只换设备与纸张。布局原本 A1、把 `PAPER` 改 A3 而比例锁 1:100，就会按 A3 裁切。统一幅面时把 `SCALE` 设 `FIT`，或让 `PAPER` 保持 `AUTO`。
2. **某布局提示「未生成 PDF」**：页面设置指向本机不存在的绘图仪或自定义尺寸。用 `PAGESETUP` 检查，或把 `PAPER` 显式设为 `A3/A4` 重试；日志里会写失败原因。
3. **跑到一半像卡住**：`ESC` 中断 → `BPSET` 把 `ENGINE` 改 `PLOT` → 重跑；仍不行就先用 `PLOT` 手动出一次图让驱动初始化。
4. **`BPF` 跳过某文件**：该图纸已在当前 CAD 会话中打开，先关闭再跑。
5. **`BPF` 屏幕不停切图**：正常现象，必须真正打开文件才能读到布局与页面设置，中途可 `ESC`（会恢复系统变量）。
6. **想合成多页 PDF**：本插件是一布局一 PDF，不合并。用 AutoCAD 的「发布（PUBLISH）」或第三方合并工具。
7. **线宽/灰度不对**：插件强制 `PlotWithPlotStyles = 是`。要黑白出图把 `STYLESHEET` 指到 `monochrome.ctb`。

---

## 九、验证状态

在 AutoCAD 2022 简体中文版实机测试：

| 项目 | 状态 |
|---|---|
| `APPLOAD` 加载、命令注册 | ✅ 实测通过 |
| 布局枚举（含中文布局名「布局1/布局2/模型」） | ✅ 实测通过 |
| 纸张切换 A4 → A3、设备切到 `DWG To PDF.pc3` | ✅ 实测通过（回读一致） |
| 目录创建、跳过空布局、日志与统计 | ✅ 实测通过 |
| 真正生成 PDF 文件 | ⚠️ 未验证：自动化会话里打印引擎等待图形界面消息循环而阻塞，需手动跑一次 `BP` 确认 |
| `BPF` 多文件循环 | ⚠️ 未验证：依赖上一条结果 |

---

## 十、自定义扩展

- 改文件名规则：`bp:batch-doc` 里 `base` 的拼接段
- 换输出设备：头部 `(setq *bp:dev* "DWG To PDF.pc3")`
- 增加幅面：`bp:media-cands` 按 `ISO_A2_(594.00_x_420.00_MM)` 格式加候选名
- 出图前加校验：在 `bp:prep-layout` 末尾追加判断
