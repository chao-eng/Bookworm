<script setup lang="ts">
import {
  ActivityIcon,
  ArrowLeftRightIcon,
  BookOpenIcon,
  DatabaseIcon,
  FileJsonIcon,
  FilesIcon,
  HistoryIcon,
  ImageIcon,
  KeyRoundIcon,
  LanguagesIcon,
  LayersIcon,
  LibraryIcon,
  LinkIcon,
  ListFilterIcon,
  MinimizeIcon,
  PaletteIcon,
  PictureInPictureIcon,
  SearchIcon,
  TypeIcon,
  ZoomInIcon,
} from '@lucide/vue'
import type { Component } from 'vue'
import type { FeatureIconKey } from '@/lib/features'

const props = defineProps<{
  name: FeatureIconKey
  class?: string
}>()

const ICONS: Record<FeatureIconKey, Component> = {
  library: LibraryIcon,
  image: ImageIcon,
  files: FilesIcon,
  listFilter: ListFilterIcon,
  bookOpen: BookOpenIcon,
  arrowLeftRight: ArrowLeftRightIcon,
  zoomIn: ZoomInIcon,
  type: TypeIcon,
  history: HistoryIcon,
  fileJson: FileJsonIcon,
  activity: ActivityIcon,
  search: SearchIcon,
  layers: LayersIcon,
  database: DatabaseIcon,
  pictureInPicture: PictureInPictureIcon,
  link: LinkIcon,
  minimize: MinimizeIcon,
  palette: PaletteIcon,
  languages: LanguagesIcon,
  keyRound: KeyRoundIcon,
}
</script>

<template>
  <component :is="ICONS[props.name]" :class="props.class" />
</template>
