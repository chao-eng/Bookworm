<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256@2x.png" width="220" alt="Bookworm 应用图标" />
</p>

<h1 align="center">Bookworm</h1>

<p align="center">
  原生 macOS 阅读器，支持电子书与漫画（epub、mobi、pdf、cbr、cbz）
  <br/>
  基于 SwiftUI 构建，无第三方依赖。
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

所有读取器均以纯 Swift 实现，或调用 macOS 自带的工具——构建过程不含任何第三方依赖。

## 功能

- **书库**：首次扫描时生成封面缩略图（漫画取第一张图，EPUB/FB2 取内嵌封面，纯文本格式使用风格化占位封面）。支持搜索、按标题 / 添加日期 / 最近打开排序，封面卡片可调整大小。
- **扫描时自动跳过无法读取的文件**：判断标准是「`ArchiveFactory.makeReader` 能否打开」，因此损坏的 zip、加密 PDF、HUFF/CDIC 压缩的 MOBI 等都不会进入书库。
- **阅读器窗口**首次打开时按页面宽高比显示（不再把竖长的日漫塞进 4:3 窗口留下黑边），之后通过 `setFrameAutosaveName` 记住用户调整过的窗口大小。
- **各格式的阅读行为：**
  - **漫画 / 日漫** —— 阅读方向（从左到右、日漫从右到左、纵向条漫）、缩放模式（适合页面 / 适合宽度 / 适合高度 / 实际大小 / 50–200%）、按书记住的捏合缩放、点击边缘翻页、深色/浅色页面背景。
  - **电子书** —— WKWebView 渲染、可调字号（60–250%）、按章节导航、覆盖出版社样式的深色/浅色 CSS、内部链接与外部链接分别处理。
- **底部页面滑块**（从右到左模式下自动镜像——填充方向、拖动方向与两端标签都会翻转）。
- **通过工具栏页码弹出「跳转到页 / 章节」**。
- **键盘导航** —— 方向键、空格、Page Up/Down、Home/End。
- **按书持久化状态** —— 最后阅读页、阅读方向、缩放模式、电子书字号在重新打开后都会保留。
- **多窗口** —— 每本书都在各自可调整大小的窗口中打开。
- **翻译模式** —— 打开阅读器工具栏中的对话气泡图标，将鼠标悬停在任意气泡上即可查看译文。Apple Vision 框架在设备端完成 OCR；翻译可走 Google 翻译（默认，无需配置）、Bing，或 OpenAI（需自备 API 密钥，保存在 macOS 钥匙串中）。源语言、目标语言与当前引擎可在开关旁的齿轮设置面板中选择。

## 安装（预编译 DMG）

> DMG 采用临时签名（ad-hoc），**未经过 Apple 公证**（公证需要付费的 Developer ID）。在 macOS Sequoia 上，弹窗 *「Apple 无法验证 'Bookworm-x.y.z.dmg' 是否包含恶意软件」* 会在你看到 DMG 内容之前就阻止挂载，而且弹窗已不再提供「仍要打开」按钮——你需要先清除隔离标记，或走「系统设置」流程。

### 最快捷的方式 —— 一条终端命令，然后拖拽安装

1. 从 [Releases](https://github.com/moerdowo/Readpaw/releases) 页面下载 `Bookworm-x.y.z.dmg`。
2. 双击之前，先执行：
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/Bookworm-0.1.0.dmg
   ```
3. 双击 DMG，把 **Bookworm** 拖到 **Applications（应用程序）** 文件夹。
4. 对已安装的应用再清除一次隔离标记：
   ```bash
   xattr -dr com.apple.quarantine /Applications/Bookworm.app
   ```
5. 通过 Spotlight / 程序坞正常启动。

`xattr -dr com.apple.quarantine …` 会移除 macOS 给所有浏览器下载文件附加的 `com.apple.quarantine` 扩展属性。没有该属性后，Gatekeeper 就不会再拦截文件。

### 不用终端 —— 系统设置流程

1. 双击 DMG，macOS 会拒绝——在弹窗中点击 **完成**（不要把它移到废纸篓）。
2. 打开 **系统设置 → 隐私与安全性**，向下滚动到底部的「安全性」区域。
3. 在 Bookworm-x.y.z.dmg 那一行旁边点击 **仍要打开**，完成认证后 macOS 就会挂载该 DMG。
4. 把 **Bookworm** 拖到 **Applications（应用程序）**。首次启动仍需走一遍同样的「隐私与安全性」流程——macOS 拒绝时点击「完成」，然后在系统设置中点击「仍要打开」。

### 绕过 Gatekeeper —— 从源码构建

本地构建的文件不会被隔离：

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

# 用另一张源 PNG 重新生成应用图标：
swift scripts/make-appicon.swift Resources/AppIcon-source.png
```

**环境要求：** macOS 15+ 与 Swift 6.0 工具链（Xcode 16 或对应的 Command Line Tools）。Target 目前固定为 Swift 5 语言模式，暂时让代码库避开严格并发（strict concurrency）升级。

## 项目结构

```
Sources/Bookworm/
├── BookwormApp.swift           # @main、场景、菜单命令
├── SmokeTest.swift             # --smoke-test 命令行测试工具
├── Resources/
│   └── Color_orb.usdz          # 引导页 3D 模型
├── Models/
│   ├── ComicItem.swift         # 书籍元数据 + 按书的阅读偏好
│   └── LibraryStore.swift      # 扫描、持久化、缩略图
├── Archive/
│   ├── ArchiveReader.swift     # ContentReader 协议 + PageContent + 工厂
│   ├── PDFArchiveReader.swift  # 基于 PDFKit
│   ├── TarArchiveReader.swift  # bsdtar / libarchive（zip / rar / 7z）
│   ├── EpubReader.swift        # OPF / spine 解析，基于文件 URL 的章节
│   ├── MobiReader.swift        # PalmDB + PalmDOC 解压
│   ├── TxtReader.swift         # TXT / HTML / FB2 读取器
│   └── EbookStyle.swift        # 共享 HTML 样式（排版、深色模式）
├── Views/
│   ├── OnboardingView.swift    # 欢迎页 + 胶囊形按钮
│   ├── USDZView.swift          # SceneKit USDZ 加载器，自动旋转 + 拖拽
│   ├── LibraryView.swift       # 封面网格、搜索、排序
│   ├── ReaderView.swift        # 阅读器外壳 + 工具栏 + 分发
│   ├── PagedReaderView.swift   # 基于 NSScrollView 的图片阅读器
│   ├── VerticalPagesView.swift # 条漫式纵向滚动
│   ├── WebPageView.swift       # 电子书内容的 WKWebView 封装
│   ├── PageSlider.swift        # 滑块 + 键盘事件捕获
│   └── ReaderWindowController.swift
└── Utilities/
    └── NSImage+Resize.swift
Resources/
├── Info.plist                  # 由 build-app.sh 打进包内
├── AppIcon-source.png          # 读书虫线稿源图（1254×1254）
├── AppIcon.icns                # 由 make-appicon.swift 生成
└── AppIcon.iconset/            # 各尺寸图标，保留以便重新打包
scripts/
├── build-app.sh                # SwiftPM 构建 → Bookworm.app + 临时签名
├── make-dmg.sh                 # Bookworm.app → Bookworm-<version>.dmg
└── make-appicon.swift          # 圆角遮罩 .icns 生成器
```

## 说明

- 书库扫描会遍历整个文件夹树，跳过隐藏文件与包内容；zip 内的 `__MACOSX/` 条目会被过滤掉。
- 缩略图缓存在 `~/Library/Application Support/Bookworm/Thumbnails/`，书库状态保存在同目录下的 `~/Library/Application Support/Bookworm/library.json`。
- EPUB 在打开期间解压到 `~/Library/Caches/Bookworm/Books/<uuid>/`，阅读器关闭后该工作目录会被删除。
- 所选文件夹以安全作用域书签（security-scoped bookmark）形式保存在 `UserDefaults` 中。
- 带 DRM 的 MOBI/AZW 文件无法打开；采用 HUFF/CDIC 压缩的 MOBI 变体暂不支持。由于扫描会过滤掉无法读取的文件，这两类文件现在会在扫描时被静默跳过。
- 应用图标来自 `Resources/AppIcon-source.png`（读书虫与书的黑白线稿）。`scripts/make-appicon.swift` 会自动裁掉插画自带的空白边，把线稿放入 824×824 的圆角主体（画布 1024×1024、四周留 100px 安全区以容纳系统投影），叠加暖米色背景后用 `iconutil` 输出包含全部必需尺寸的 `.icns`。

---

本项目基于 [`https://github.com/moerdowo/Readpaw`](https://github.com/moerdowo/Readpaw) 二次开发。
