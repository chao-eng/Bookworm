export interface NavItem {
  label: string
  href: string
}

export interface Shortcut {
  keys: string[]
  name: string
  description: string
}

export interface TrustStat {
  value: string
  label: string
}

export interface DownloadOption {
  label: string
  href: string
}

export interface DownloadChannel {
  id: string
  tag: string
  title: string
  description: string
  note: string
  variant: 'default' | 'outline'
  icon: 'download' | 'github'
  options: DownloadOption[]
}

export interface Acknowledgement {
  name: string
  url: string
}

export interface AuthorProfile {
  name: string
  avatar: string
  repoLabel: string
  intro: string
  links: { label: string; href: string }[]
}

export const SITE = {
  name: 'Bookworm',
  domain: 'bookworm.bujic.cc',
  locale: 'zh-CN',
  title: 'Bookworm — 原生 macOS 电子书、漫画与在线书源阅读器',
  description:
    'Bookworm 是一个用 SwiftUI 原生开发的 macOS 阅读器：本地电子书、漫画与在线书源统一进一个书架，支持全局悬浮窗阅读、阅读进度同步与网页翻译。MIT 开源，除自动更新外不依赖第三方组件。',
  keywords:
    'Bookworm,macOS 阅读器,电子书阅读器,漫画阅读器,在线书源,legado 书源,EPUB,Mobi,AZW3,CBZ,CBR,悬浮窗阅读,SwiftUI',
  version: 'v0.1.8',
  license: 'MIT License',
  subheadline:
    '本地电子书、漫画与在线书源统一管理，阅读窗口与全局悬浮窗共享同一份进度。',
  specs: ['纯 Swift / SwiftUI 原生', 'macOS 15 或更高', 'MIT 开源'],
  osRequirement: 'macOS 15.0 (Sequoia) 或更高版本',
  archRequirement: 'Apple Silicon（当前发布包为 arm64）；Intel Mac 可从源码构建',
  repo: 'https://github.com/chao-eng/Bookworm',
  releases: 'https://github.com/chao-eng/Bookworm/releases',
  issues: 'https://github.com/chao-eng/Bookworm/issues',
  licenseUrl: 'https://github.com/chao-eng/Bookworm/blob/main/LICENSE',
  downloadUrl:
    'https://github.com/chao-eng/Bookworm/releases/download/v0.1.8/Bookworm-0.1.8.dmg',
} as const

export const NAV_ITEMS: NavItem[] = [
  { label: '核心功能', href: '#features' },
  { label: '格式支持', href: '#formats' },
  { label: '上手教程', href: '#tutorial' },
  { label: '安全边界', href: '#trust' },
  { label: '下载', href: '#download' },
  { label: '更新日志', href: '#changelog' },
  { label: '关于作者', href: '#about' },
]

export const SHORTCUTS: Shortcut[] = [
  { keys: ['⌥', '⌘', 'R'], name: '显示 / 隐藏悬浮窗', description: '任何 App 里都能唤出，不抢占前台焦点' },
  { keys: ['⌥', '⌘', '→'], name: '下一页', description: '隐藏状态下按翻页键会自动唤出' },
  { keys: ['⌥', '⌘', '←'], name: '上一页', description: '与阅读窗口保持同一页' },
  { keys: ['⌥', '⌘', '↓'], name: '下一章', description: '按章节向后跳转' },
  { keys: ['⌥', '⌘', '↑'], name: '上一章', description: '按章节向前跳转' },
  { keys: ['⌥', '⌘', 'P'], name: '自动翻页开关', description: '间隔可选关闭、5 秒、10 秒、30 秒' },
]

export const TRUST_STATS: TrustStat[] = [
  { value: '13', label: '种格式扩展名' },
  { value: '6', label: '路并发书源' },
  { value: '500MB', label: '默认正文缓存' },
  { value: '1', label: '个第三方依赖' },
]

export const DOWNLOAD_CHANNELS: DownloadChannel[] = [
  {
    id: 'github',
    tag: '官方开源仓库',
    title: 'GitHub Releases 与源码',
    description: '获取最新 DMG、核对版本号，或查看全部源码与发版记录。',
    note: '支持 Star 与 Issue 反馈',
    variant: 'default',
    icon: 'github',
    options: [
      { label: `下载 ${SITE.name} ${SITE.version.replace('v', '')}`, href: SITE.downloadUrl },
      { label: '查看全部 Releases', href: SITE.releases },
    ],
  },
]

export const ACKNOWLEDGEMENTS: Acknowledgement[] = [
  { name: 'Readpaw', url: 'https://github.com/moerdowo/Readpaw' },
  { name: 'Sparkle', url: 'https://github.com/sparkle-project/Sparkle' },
  { name: 'Legado', url: 'https://github.com/gedoor/legado' },
]

export const AUTHOR: AuthorProfile = {
  name: 'chao-eng',
  avatar: '/images/author-avatar.webp',
  repoLabel: 'github.com/chao-eng/Bookworm',
  intro:
    'Bookworm 是一个个人开源项目，基于上游 Readpaw 二次开发，从阅读器到官网都由作者维护。',
  links: [
    { label: 'GitHub 仓库', href: SITE.repo },
    { label: '提交 Issue', href: SITE.issues },
    { label: '开源协议', href: SITE.licenseUrl },
  ],
}

export interface RewardCode {
  id: string
  label: string
  src: string
  width: number
  height: number
  alt: string
}

export const REWARD_NOTE =
  'Bookworm 以 MIT License 开源，免费使用。如果它确实帮到了你，可以随意赞赏一点，不赞赏也完全不影响使用。'

export const REWARD_CODES: RewardCode[] = [
  {
    id: 'wechat',
    label: '微信赞赏',
    src: '/images/reward-wechat.webp',
    width: 480,
    height: 478,
    alt: 'Bookworm 作者的微信赞赏码',
  },
  {
    id: 'alipay',
    label: '支付宝',
    src: '/images/reward-alipay.webp',
    width: 560,
    height: 560,
    alt: 'Bookworm 作者的支付宝收款码',
  },
]

export const INSTALL_COMMAND =
  'xattr -dr com.apple.quarantine /Applications/Bookworm.app'

export const SAFETY_BOUNDARIES = [
  '不内置任何书源，导入、启停与编辑都由自己决定',
  '书库、书源配置和正文缓存全部保存在本机',
  '唯一的第三方依赖是 Sparkle 2，只用于应用内更新',
  '关闭 TLS 校验默认不开启，开启前会提示中间人风险并二次确认',
  '扫描时跳过无法读取的文件，损坏与加密文件不会进入书库',
  '本地读取全部为纯 Swift 实现，或调用 macOS 自带工具',
]
