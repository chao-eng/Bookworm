export interface Shot {
  src: string
  width: number
  height: number
  caption: string
  alt: string
}

export type FeatureIconKey =
  | 'library'
  | 'image'
  | 'files'
  | 'listFilter'
  | 'bookOpen'
  | 'arrowLeftRight'
  | 'zoomIn'
  | 'type'
  | 'history'
  | 'fileJson'
  | 'activity'
  | 'search'
  | 'layers'
  | 'database'
  | 'pictureInPicture'
  | 'link'
  | 'minimize'
  | 'palette'
  | 'languages'
  | 'keyRound'

export interface FeatureItem {
  icon: FeatureIconKey
  title: string
  description: string
}

export interface FeatureGroup {
  id: string
  label: string
  summary: string
  items: FeatureItem[]
  shots: Shot[]
}

const SHOT_ONBOARDING: Shot = {
  src: '/images/onboarding.webp',
  width: 1400,
  height: 1246,
  caption: '欢迎页',
  alt: 'Bookworm 欢迎页，一本翻开的书、一句标语和选择书库文件夹按钮',
}

const SHOT_LIBRARY: Shot = {
  src: '/images/library.webp',
  width: 1400,
  height: 1246,
  caption: '书架',
  alt: 'Bookworm 书架，左侧分类侧边栏与右侧封面网格',
}

const SHOT_SOURCES: Shot = {
  src: '/images/sources.webp',
  width: 1400,
  height: 1246,
  caption: '书源管理',
  alt: 'Bookworm 书源管理，每个源一行，显示开关、名称、域名与健康度',
}

const SHOT_ONLINE_SEARCH: Shot = {
  src: '/images/online-search.webp',
  width: 1400,
  height: 1239,
  caption: '在线搜书',
  alt: 'Bookworm 在线搜书结果，命中来源逐条列出并提供阅读与加入书架按钮',
}

const SHOT_READER: Shot = {
  src: '/images/reader.webp',
  width: 956,
  height: 1400,
  caption: '阅读页',
  alt: 'Bookworm 阅读页，顶部工具栏提供目录、翻页、书名与格式菜单',
}

const SHOT_FLOATING: Shot = {
  src: '/images/floating.webp',
  width: 1400,
  height: 894,
  caption: '悬浮窗',
  alt: 'Bookworm 悬浮窗，显示正文与当前页数，并支持迷你模式',
}

export const FEATURE_GROUPS: FeatureGroup[] = [
  {
    id: 'library',
    label: '书库与格式',
    summary: '本地文件和在线书进同一个书架，封面、分类和排序都不用二次整理。',
    items: [
      {
        icon: 'library',
        title: '本地书与在线书同架',
        description: '在线书带来源名与书源健康度标记。',
      },
      {
        icon: 'image',
        title: '首扫生成封面',
        description: '漫画取首图，EPUB / FB2 取内嵌封面，纯文本用占位封面。',
      },
      {
        icon: 'files',
        title: '九类格式直接读取',
        description: '全部原生解析，或调用 macOS 自带工具。',
      },
      {
        icon: 'listFilter',
        title: '分类、搜索与排序',
        description: '八个分类，按标题或最近打开排序。',
      },
    ],
    shots: [SHOT_ONBOARDING, SHOT_LIBRARY],
  },
  {
    id: 'reading',
    label: '本地阅读',
    summary: '漫画按日漫方向翻，电子书按自己的字号排，每本书的偏好都留在书里。',
    items: [
      {
        icon: 'bookOpen',
        title: '漫画方向与翻页',
        description: '从左到右、日漫从右到左、纵向条漫。',
      },
      {
        icon: 'zoomIn',
        title: '缩放按书记忆',
        description: '适合页面 / 宽度 / 高度 / 实际大小 / 50%–200%。',
      },
      {
        icon: 'type',
        title: '电子书排版',
        description: '字号 60%–250%，字体、行距和深浅主题。',
      },
      {
        icon: 'history',
        title: '进度与窗口恢复',
        description: '最后页、方向、缩放和字号都会记住。',
      },
    ],
    shots: [SHOT_READER],
  },
  {
    id: 'online',
    label: '在线书源',
    summary: '导入自己的书源，多个站点并发搜索，正文按章缓存并预取。',
    items: [
      {
        icon: 'fileJson',
        title: 'Legado 书源导入',
        description: '文件或粘贴 JSON，导入前先给出预览。',
      },
      {
        icon: 'activity',
        title: '健康度与失效标记',
        description: '成功率低于 30% 标「建议停用」，可一键停用。',
      },
      {
        icon: 'search',
        title: '六路并发搜索',
        description: '单源 7 秒超时，整体预算 30 秒。',
      },
      {
        icon: 'layers',
        title: '同书多源合并',
        description: '一本书命中多个源时合并成一条。',
      },
      {
        icon: 'database',
        title: '正文缓存与预取',
        description: '默认 500MB，预取前后各 2 章。',
      },
    ],
    shots: [SHOT_SOURCES, SHOT_ONLINE_SEARCH],
  },
  {
    id: 'floating',
    label: '悬浮窗',
    summary: '在任何 App 里读，不抢焦点，也不打断当前工作。',
    items: [
      {
        icon: 'pictureInPicture',
        title: '不抢焦点的全局悬浮窗',
        description: '前台 App 不会失焦。',
      },
      {
        icon: 'link',
        title: '与阅读窗口同步',
        description: '本地书与在线书进度双向同步。',
      },
      {
        icon: 'minimize',
        title: '迷你模式',
        description: '只显示一行正文和百分比，宽度 160–760 点可拖。',
      },
      {
        icon: 'palette',
        title: '外观与自动翻页',
        description: '字号、透明度、颜色和间隔都能调。',
      },
    ],
    shots: [SHOT_FLOATING],
  },
  {
    id: 'assist',
    label: '翻译与辅助',
    summary: '网页气泡就地识别与翻译，原文和译文都不离开当前阅读页。',
    items: [
      {
        icon: 'languages',
        title: '气泡级网页翻译',
        description: '鼠标停在气泡上即可查看译文。',
      },
      {
        icon: 'search',
        title: '本地 OCR + 三种引擎',
        description: 'Vision 识别，Google / Bing / OpenAI 翻译。',
      },
      {
        icon: 'keyRound',
        title: '密钥存钥匙串',
        description: 'OpenAI 密钥写入 macOS 钥匙串。',
      },
    ],
    shots: [],
  },
]
