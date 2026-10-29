<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256@2x.png" width="220" alt="Bookworm 应用图标" />
</p>

<h1 align="center">Bookworm</h1>

<p align="center">
  原生 macOS 阅读器，支持本地电子书、漫画以及在线书源
  <br/>
  基于 SwiftUI 构建，读取器不依赖第三方库；唯一的第三方依赖是 Sparkle 2，用于应用内自动更新。
</p>

***

## 支持的格式

**漫画与日漫**

| 格式              | 读取方式                                |
| --------------- | ----------------------------------- |
| `.cbz` / `.zip` | `/usr/bin/tar`（bsdtar / libarchive） |
| `.cbr` / `.rar` | `/usr/bin/tar`（libarchive RAR 读取器）  |
| `.7z`           | `/usr/bin/tar`                      |
| `.pdf`          | PDFKit                              |

**电子书**

| 格式                          | 读取方式                              |
| --------------------------- | --------------------------------- |
| `.epub`                     | 原生 OPF/spine 解析器，章节由 WKWebView 渲染 |
| `.mobi` / `.azw` / `.azw3`  | 原生 PalmDB + PalmDOC 解压器（未加密文件）    |
| `.fb2`                      | XML → HTML，内嵌封面与图片                |
| `.txt`                      | 自动分页，并包裹为带样式的 HTML                |
| `.html` / `.xhtml` / `.htm` | 直接加载，相对资源可正常解析                    |

读取器均为纯 Swift 实现或调用 macOS 自带的工具。除自动更新用的 Sparkle 外，没有别的第三方依赖。

**在线书源**

| 来源类型        | 读取方式                                     |
| ----------- | ---------------------------------------- |
| HTML 站点     | CSS 选择器提取搜索结果、目录和正文                      |
| JSON 接口     | `$$` 路径（`key$$name.index$$0.key$$value`） |
| 老版 legado 书源 | 导入时自动映射到当前规则字段                           |

## 功能

### 书库

- 首次扫描时生成封面缩略图。漫画取第一张图，EPUB / FB2 取内嵌封面，纯文本格式使用风格化占位封面。
- 扫描时跳过打不开的文件。判断标准是 `ArchiveFactory.makeReader` 能否读取，所以损坏的 zip、加密 PDF、HUFF/CDIC 压缩的 MOBI 都不会进入书库。
- 本地书和在线书放在同一个书库，在线书显示来源名和书源健康度标记。
- 支持搜索、按标题 / 添加日期 / 最近打开排序，封面卡片可以调整大小。

### 本地阅读

- 阅读窗口首次打开时按页面宽高比显示，之后用 `setFrameAutosaveName` 记住用户调整过的窗口尺寸。
- 漫画与日漫可以设置阅读方向（从左到右、日漫从右到左、纵向条漫）和缩放模式（适合页面 / 宽度 / 高度 / 实际大小 / 50% 到 200%），捏合缩放按书保存，点击边缘翻页，页面背景可选深色或浅色。
- 电子书使用 WKWebView 渲染，字号 60% 到 250%，支持按章节导航，可用深色 / 浅色 CSS 覆盖出版社样式，内部链接和外部链接分开处理。
- 底部页面滑块在从右到左模式下自动镜像，填充方向、拖动方向和两端标签都会翻转。
- 工具栏页码可以直接跳到指定页或章节。
- 键盘导航支持方向键、空格、Page Up / Page Down、Home / End。
- 每本书记住最后阅读页、阅读方向、缩放模式和电子书字号，重新打开后恢复。
- 每本书开在各自可调整大小的窗口里。

### 在线阅读

应用本身不带书源。导入一份 Legado（阅读）格式的书源 JSON 之后，书源管理、搜索和阅读才可用。

**书源管理**

- 从文件导入或直接粘贴 JSON，接受 `[ … ]`、`{"sources": [ … ]}` 和单个书源对象三种写法。
- 老版 legado 书源（`source_name`、`book_menu`、`chapter_content` 等字段）会自动转换成当前规则。缺少搜索、目录或正文规则的源在导入时会被拒绝。
- 导入前先给出预览，列出新增、冲突和失败的数量，确认后才写盘。
- 每个源可以单独启停、编辑规则、导出备份。
- 每个源记录搜索和正文抓取的成功率。健康度低于 30% 的已启用源会标记「建议停用」，也可以一键停用全部失效源或全部在线源。
- 书源的「关闭 TLS 校验」默认不开启。开启前会提示中间人攻击风险，需要二次确认。

**搜索与书架**

- 搜索时最多同时请求 6 个书源，单个源 7 秒超时，整体预算 30 秒。结果到达就显示，不用等全部结束，中途可以停止。
- 同一本书出现在多个来源时合并成一条，展开后能看到其他来源和匹配等级，可以换一个来源阅读。
- 「加入书架」先抓目录再落库，封面在后台下载。封面失败时用占位图，不影响阅读。
- 书源规则改动后，目录的规则指纹会变化，应用会提示重建目录，避免继续使用旧的失效章节地址。

**阅读**

- 目录侧栏打开时自动滚到当前章节，深色主题下也能看清。
- 工具栏可以调字号、字体、行距和主题，设置与本地电子书共用。
- 底栏默认隐藏，鼠标移到窗口底部才淡入，显示章节名、书源、章节进度和全书百分比。
- 方向键、空格、Page Up / Page Down 的翻页语义与本地书一致。
- 正文按章缓存，默认上限 500MB，可以在 100MB 到 5GB 之间调整，超出后按最近访问时间淘汰。
- 读到某一章时预取前后各 2 章，并发 3 个请求。切章或关闭窗口会取消未完成的预取。
- 在线书也能在悬浮窗里打开，和本地书共用同一套阅读会话。

**规则能力**

- 搜索、目录和正文都支持 CSS 选择器和 JSON `$$` 路径。
- 支持目录与正文分页、正文过滤规则、按选择器移除广告节点。

### 悬浮窗

默认快捷键见下表。

| 动作           | 默认组合      |
| ------------ | --------- |
| 显示 / 隐藏悬浮窗   | ⌥⌘R       |
| 下一页 / 上一页    | ⌥⌘→ / ⌥⌘← |
| 下一章 / 上一章    | ⌥⌘↓ / ⌥⌘↑ |
| 自动翻页开关       | ⌥⌘P       |

- 悬浮窗不会成为 key window，前台 App 不会失焦，在任何 App 里都能用。
- 与阅读窗口共用同一个阅读会话，本地书和在线书的进度双向同步。
- 隐藏状态下按翻页键会自动唤出。还没打开书时只提示「先打开一本书」，不会自动开书。
- 鼠标滚轮也能翻页，累计超过 30 点触发一次。
- 迷你模式只显示一行正文和百分比，宽度可以在 160 到 760 点之间拖动，重启后沿用上次的模式和宽度。
- 右键菜单可以临时调字号、透明度、自动翻页间隔，切换正常 / 迷你模式，或直接隐藏。

**悬浮窗设置**

- 快捷键可以重新录制，要求至少包含 ⌘、⌥ 或 ⌃。与已有动作冲突会提示，也可以把单个动作置空禁用。
- 字号 12 到 28，透明度 35% 到 100%。
- 字体颜色和背景颜色支持输入 `#RRGGBB`，也可以点色块唤起系统屏幕取色器。
- 自动翻页间隔可选关闭、5 秒、10 秒、30 秒。
- 可以一键恢复默认快捷键。

### 翻译

打开阅读器工具栏的对话气泡图标后，把鼠标停在任意气泡上就能看到译文。Apple Vision 框架在设备端做 OCR，翻译可以走 Google 翻译（默认，无需配置）、Bing 或 OpenAI（需要自己的 API 密钥，保存在 macOS 钥匙串）。源语言、目标语言和当前引擎在开关旁的齿轮面板里选择。

## 安装（预编译 DMG）

> DMG 采用临时签名（ad-hoc），**未经过 Apple 公证**（公证需要付费的 Developer ID）。在 macOS Sequoia 上，弹窗 *「Apple 无法验证 'Bookworm-x.y.z.dmg' 是否包含恶意软件」* 会在你看到 DMG 内容之前就阻止挂载，而且弹窗已不再提供「仍要打开」按钮。你需要先清除隔离标记，或者走「系统设置」流程。

### 最快捷的方式，一条终端命令加拖拽安装

1. 从 [Releases](https://github.com/chao-eng/Bookworm/releases) 页面下载 `Bookworm-x.y.z.dmg`。
2. 双击之前，先在终端执行下面这行命令。
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/Bookworm-0.1.0.dmg
   ```
3. 双击 DMG，把 **Bookworm** 拖到 **Applications（应用程序）** 文件夹。
4. 装好后再对应用清除一次隔离标记。
   ```bash
   xattr -dr com.apple.quarantine /Applications/Bookworm.app
   ```
5. 通过 Spotlight / 程序坞正常启动。

`xattr -dr com.apple.quarantine …` 会移除 macOS 给所有浏览器下载文件附加的 `com.apple.quarantine` 扩展属性。没有该属性后，Gatekeeper 就不会再拦截文件。

### 不用终端时的系统设置流程

1. 双击 DMG，macOS 会拒绝。在弹窗中点击 **完成**（不要把它移到废纸篓）。
2. 打开 **系统设置 → 隐私与安全性**，向下滚动到底部的「安全性」区域。
3. 在 Bookworm-x.y.z.dmg 那一行旁边点击 **仍要打开**，完成认证后 macOS 就会挂载该 DMG。
4. 把 **Bookworm** 拖到 **Applications（应用程序）**。首次启动仍需走一遍同样的「隐私与安全性」流程。macOS 拒绝时点击「完成」，然后在系统设置中点击「仍要打开」。

### 绕过 Gatekeeper，从源码构建

本地构建的文件不会被隔离。

```bash
git clone <本仓库地址>
cd Bookworm
./scripts/build-app.sh
open build/Bookworm.app
```

## 构建与运行

```bash
# 开发时快速启动（不生成 .app 包）：
swift run

# 对一本书所在文件夹无界面地验证所有读取器：
swift run Bookworm --smoke-test /path/to/books

# 构建可直接放进 /Applications 的 .app：
./scripts/build-app.sh
open build/Bookworm.app

# 把 .app 打包为带版本号、临时签名的 DMG 用于分发：
./scripts/make-dmg.sh     # 输出 build/Bookworm-<version>.dmg

# 一键发版：递增版本号、打包 DMG、EdDSA 签名并写入 appcast.xml：
./scripts/release.sh      # 修订号加 1，也可以传 minor 或 major

# 用另一张源 PNG 重新生成应用图标：
swift scripts/make-appicon.swift Resources/AppIcon-source.png
```

**环境要求** macOS 15+ 与 Swift 6.0 工具链（Xcode 16 或对应的 Command Line Tools）。Target 目前固定为 Swift 5 语言模式，暂时让代码库避开严格并发（strict concurrency）升级。

## 项目结构

```
Sources/Bookworm/
├── BookwormApp.swift           # @main、场景、菜单命令
├── SmokeTest.swift             # --smoke-test 命令行测试工具
├── Updater.swift               # Sparkle 自动更新封装
├── Resources/
│   └── onboarding_book.gif     # 引导页手绘翻页书动画（透明 GIF）
├── Models/
│   ├── ComicItem.swift         # 书籍元数据 + 按书的阅读偏好
│   ├── LibraryStore.swift      # 扫描、持久化、缩略图
│   ├── EbookSettings.swift     # 字号、字体、行距、主题
│   └── FloatingState.swift     # 悬浮窗配置与持久化
├── Session/
│   ├── ReadingSession.swift    # 本地书与在线书共用的阅读会话
│   └── ReaderNavigation.swift  # 统一的翻页键位映射
├── Archive/
│   ├── ArchiveReader.swift     # ContentReader 协议 + PageContent + 工厂
│   ├── PDFArchiveReader.swift  # 基于 PDFKit
│   ├── TarArchiveReader.swift  # bsdtar / libarchive（zip / rar / 7z）
│   ├── EpubReader.swift        # OPF / spine 解析，基于文件 URL 的章节
│   ├── MobiReader.swift        # PalmDB + PalmDOC 解压
│   ├── TxtReader.swift         # TXT / HTML / FB2 读取器
│   └── EbookStyle.swift        # 共享 HTML 样式（排版、深色模式）
├── Online/
│   ├── OnlineModels.swift      # 书源规则与在线书模型
│   ├── SourceRepository.swift  # 书源导入、导出、健康度
│   ├── RuleEngine.swift        # CSS 选择器与 JSON $$ 规则解析
│   ├── SearchService.swift     # 跨源并发搜索
│   ├── ChapterService.swift    # 目录、正文抓取与预取
│   ├── ChapterCache.swift      # 章节正文缓存与淘汰
│   ├── NetworkClient.swift     # 网络请求封装
│   ├── OnlineShelfService.swift # 加入书架与封面下载
│   ├── OnlineSearchView.swift  # 在线搜索面板
│   ├── SourceManagementView.swift # 书源管理面板
│   └── OnlineReaderView.swift  # 在线阅读器
├── Floating/
│   ├── FloatingPanelController.swift # 面板、排版、翻页
│   ├── FloatingSettingsView.swift    # 悬浮窗设置
│   └── HotkeyCenter.swift            # 全局热键注册
├── Translation/
│   ├── TranslationEngine.swift
│   ├── GoogleTranslator.swift
│   ├── BingTranslator.swift
│   ├── OpenAITranslator.swift
│   ├── TranslationSettings.swift
│   └── TranslationState.swift
├── OCR/
│   ├── OCRService.swift
│   ├── LiveTextOCR.swift
│   ├── BubbleDetector.swift
│   └── OCRDiagnostic.swift
├── Server/
│   └── BrowseServer.swift      # 局域网浏览图片书
├── Views/
│   ├── OnboardingView.swift    # 欢迎页 + 胶囊形按钮
│   ├── PaperBookHero.swift     # 引导页手绘翻页书动画
│   ├── LibraryView.swift       # 封面网格、搜索、排序
│   ├── ReaderView.swift        # 阅读器外壳 + 工具栏 + 分发
│   ├── PagedReaderView.swift   # 基于 NSScrollView 的图片阅读器
│   ├── VerticalPagesView.swift # 条漫式纵向滚动
│   ├── WebPageView.swift       # 电子书内容的 WKWebView 封装
│   ├── PageSlider.swift        # 滑块 + 键盘事件捕获
│   ├── PageGridView.swift      # 页面缩略图网格
│   ├── EbookNavigatorView.swift # 章节导航
│   ├── TranslateOverlayView.swift # 翻译气泡浮层
│   ├── TranslateSettingsView.swift
│   ├── TranslationPanelView.swift
│   └── ReaderWindowController.swift
└── Utilities/
    ├── AppPaths.swift          # 应用数据目录
    ├── Diagnostics.swift       # 日志
    ├── TextPaginator.swift     # 文本分页
    └── NSImage+Resize.swift
Resources/
├── Info.plist                  # 由 build-app.sh 打进包内
├── AppIcon-source.png          # 读书虫线稿源图（1254×1254）
├── AppIcon.icns                # 由 make-appicon.swift 生成
└── AppIcon.iconset/            # 各尺寸图标，保留以便重新打包
scripts/
├── build-app.sh                # SwiftPM 构建 → Bookworm.app + 临时签名
├── make-dmg.sh                 # Bookworm.app → Bookworm-<version>.dmg
├── release.sh                  # 递增版本、EdDSA 签名并更新 appcast.xml
└── make-appicon.swift          # 圆角遮罩 .icns 生成器
```

## 说明

- 书库扫描会遍历整个文件夹树，跳过隐藏文件与包内容；zip 内的 `__MACOSX/` 条目会被过滤掉。
- 缩略图缓存在 `~/Library/Application Support/Bookworm/Thumbnails/`，书库状态保存在同目录下的 `~/Library/Application Support/Bookworm/library.json`。
- 书源配置保存在 `~/Library/Application Support/Bookworm/Sources/sources.json`，导入、编辑和导出的都是这个结构。
- 在线书正文按章缓存在 `~/Library/Application Support/Bookworm/ChapterCache/`，索引文件是 `index.json`，默认上限 500MB，按最近访问时间淘汰。
- 悬浮窗的位置、尺寸、透明度、颜色、热键和上次使用的模式保存在 `~/Library/Application Support/Bookworm/Floating/state.json`。
- EPUB 在打开期间解压到 `~/Library/Caches/Bookworm/Books/<uuid>/`，阅读器关闭后该工作目录会被删除。
- 所选文件夹以安全作用域书签（security-scoped bookmark）形式保存在 `UserDefaults` 中。
- 应用内更新由 Sparkle 2 负责，更新源指向本仓库的 `appcast.xml`，发版时用 `scripts/release.sh` 签名并写入新版本。
- 带 DRM 的 MOBI/AZW 文件无法打开；采用 HUFF/CDIC 压缩的 MOBI 变体暂不支持。由于扫描会过滤掉无法读取的文件，这两类文件现在会在扫描时被静默跳过。
- 应用图标来自 `Resources/AppIcon-source.png`（读书虫与书的黑白线稿）。`scripts/make-appicon.swift` 会自动裁掉插画自带的空白边，把线稿放入 824×824 的圆角主体（画布 1024×1024、四周留 100px 安全区以容纳系统投影），叠加暖米色背景后用 `iconutil` 输出包含全部必需尺寸的 `.icns`。

---

本项目基于 [`https://github.com/moerdowo/Readpaw`](https://github.com/moerdowo/Readpaw) 二次开发。
