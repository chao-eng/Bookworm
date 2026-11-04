export interface TutorialStep {
  id: string
  title: string
  bullets: string[]
  command?: string
  showHotkeys?: boolean
}

export const TUTORIAL_STEPS: TutorialStep[] = [
  {
    id: 'install',
    title: '安装并首次打开',
    bullets: [
      '从 GitHub Releases 下载 Bookworm-0.1.9.dmg。',
      '拖入「应用程序」；未公证的包可能被 Gatekeeper 拦截。',
      '执行命令清除隔离标记后正常启动。',
    ],
    command: 'xattr -dr com.apple.quarantine /Applications/Bookworm.app',
  },
  {
    id: 'folder',
    title: '选择书库文件夹',
    bullets: [
      '首次启动只有「选择书库文件夹」一个入口。',
      '递归扫描整个文件夹树，生成封面缩略图。',
      '打不开的文件会被跳过，不进入书架。',
    ],
  },
  {
    id: 'sources',
    title: '导入书源（可选）',
    bullets: [
      '从文件导入或直接粘贴 JSON。',
      '接受 [ … ]、{"sources": [ … ]} 和单个书源对象。',
      '导入前预览新增、冲突和失败数量。',
      '缺少搜索、目录或正文规则的源会被拒绝；老版 legado 字段自动映射。',
    ],
  },
  {
    id: 'search',
    title: '搜索并加入书架',
    bullets: [
      '最多同时请求 6 个源，单源 7 秒超时，整体 30 秒。',
      '结果到达即显示；同一本书合并成一条，可展开切换来源。',
      '点「加入书架」先抓目录再落库，封面后台下载。',
    ],
  },
  {
    id: 'read',
    title: '打开并调整阅读',
    bullets: [
      '目录侧栏打开时自动滚到当前章节。',
      '「格式」菜单调字号、字体、行距和主题，本地书与在线书共用。',
      '方向键、空格、Page Up / Down 翻页；每本书恢复上次位置。',
    ],
  },
  {
    id: 'floating',
    title: '用悬浮窗随手读',
    bullets: [
      '⌥⌘R 显示或隐藏；隐藏时按翻页键会自动唤出。',
      '与阅读窗口共用阅读会话，进度双向同步。',
      '迷你模式只显示一行正文和百分比，宽度 160–760 点可拖。',
    ],
    showHotkeys: true,
  },
  {
    id: 'translation',
    title: '翻译（可选）',
    bullets: [
      '打开阅读器工具栏的对话气泡图标。',
      '鼠标停在任意气泡上查看译文。',
      'Google 默认无需配置；Bing / OpenAI 需自填密钥，保存在钥匙串。',
    ],
  },
]
