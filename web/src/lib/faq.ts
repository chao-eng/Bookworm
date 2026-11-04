export interface FaqItem {
  id: string
  question: string
  answer: string
}

export const FAQ_ITEMS: FaqItem[] = [
  {
    id: 'gatekeeper',
    question: '首次打开提示「Apple 无法验证」或「应用程序已损坏」怎么办？',
    answer:
      '这是 Gatekeeper 对未公证应用的拦截，不是文件损坏。确认安装包来自官方 Releases 后，在终端执行：\nxattr -dr com.apple.quarantine /Applications/Bookworm.app\n或到「系统设置 → 隐私与安全性」点「仍要打开」。',
  },
  {
    id: 'no-sources',
    question: '为什么应用里没有书源？',
    answer:
      'Bookworm 本身不带书源。导入一份 Legado（阅读）格式的 JSON 后，书源管理、搜索和阅读才可用。',
  },
  {
    id: 'import-failed',
    question: '导入书源失败或提示缺少规则怎么办？',
    answer:
      '缺少搜索、目录或正文规则的源会被拒绝；老版 legado 字段会自动映射。导入前的预览会列出新增、冲突和失败数量，按提示补齐规则即可。',
  },
  {
    id: 'source-health',
    question: '书源健康度低、403、302 或 TLS 失败怎么办？',
    answer:
      '每个源记录搜索和正文抓取成功率，低于 30% 会标「建议停用」，失败原因会写在源后面。可以一键停用失效源，或先编辑规则再试。',
  },
  {
    id: 'drm',
    question: '支持带 DRM 或加密的 MOBI/AZW 吗？',
    answer:
      '不支持。带 DRM 的 MOBI/AZW 无法打开，HUFF/CDIC 压缩变体也不支持；扫描时会跳过这些文件。',
  },
  {
    id: 'data',
    question: '数据存在哪里，会不会上传？',
    answer:
      '书库状态在 ~/Library/Application Support/Bookworm/library.json，书源在 Sources/sources.json，正文缓存在 ChapterCache/，悬浮窗状态在 Floating/state.json。本地阅读不联网；只有使用在线书源或翻译时才会请求对应服务。',
  },
  {
    id: 'intel',
    question: '安装包支持 Intel Mac 吗，能否自己构建？',
    answer:
      '支持。发布包为 Universal 通用二进制，同时包含 Apple Silicon（arm64）与 Intel（x86_64）两个架构，macOS 15+ 的 Intel Mac 可直接运行。也可以从源码构建：clone 后执行 ./scripts/build-app.sh，需要 macOS 15+ 与 Swift 6.0 工具链。',
  },
]
