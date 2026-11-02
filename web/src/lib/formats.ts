export interface FormatGroup {
  id: string
  label: string
  formats: string[]
  reader: string
  icon: 'comic' | 'ebook' | 'online'
}

export const FORMAT_GROUPS: FormatGroup[] = [
  {
    id: 'comic',
    label: '漫画与日漫',
    formats: ['.cbz', '.zip', '.cbr', '.rar', '.7z', '.pdf'],
    reader: 'bsdtar / libarchive、PDFKit',
    icon: 'comic',
  },
  {
    id: 'ebook',
    label: '电子书',
    formats: ['.epub', '.mobi', '.azw', '.azw3', '.fb2', '.txt', '.html', '.xhtml', '.htm'],
    reader: '原生 OPF / spine、PalmDB + PalmDOC、XML→HTML、自动分页、WKWebView',
    icon: 'ebook',
  },
  {
    id: 'online',
    label: '在线书源',
    formats: ['HTML 站点', 'JSON 接口', '老版 legado 书源'],
    reader: 'CSS 选择器、$$ 路径、字段自动映射',
    icon: 'online',
  },
]

export const FORMAT_NOTE =
  '带 DRM 的 MOBI/AZW 与 HUFF/CDIC 压缩变体不支持，扫描时会跳过。'
