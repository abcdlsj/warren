# Warren 徽标

## 核心概念

徽标把字母 `W`、兔群地穴和终端光标合并为一个像素标记。

- 两个高位笔画像兔耳，也构成 `W` 的起笔和收笔。
- 下方分叉像相连的地穴，呼应 Warren 的名称和 Workspace 组织方式。
- 琥珀色方块既是地穴中的灯，也是终端光标。

## 响应式源文件

- `warren-app-icon.svg`：64 px 及以上使用的 1024 × 1024 主源文件。
- `warren-app-icon-32.svg`：原生 32 × 32 紧凑版本。保留一层深度，移除内侧明暗面。
- `warren-app-icon-16.svg`：原生 16 × 16 微型版本。只保留底板、`W` 和光标。
- `warren-app-icon.png`：1024 × 1024 预览和通用位图。
- `Warren.icns`：macOS app icon。

不得把主 SVG 直接缩放到 16 px。主图采用 32 px 构造网格，缩放到 16 px
会产生半像素边缘。修改任一源文件后运行：

```sh
mise run brand:assets
mise run web:build
```

第一条命令生成 macOS iconset、ICNS、Web favicon 和 PWA PNG；第二条命令把
`Web/public/` 构建到 `Web/dist/`。派生文件不得手工修改。

## 颜色

| 用途 | 色值 |
| --- | --- |
| 主背景 | `#1c1918` |
| 深阴影 | `#0f0d0c` |
| 主图形 | `#eae8e6` |
| 光标 | `#f59e0b` |

不要添加渐变、圆角描边或抗锯齿笔画。图形必须对齐 32 px 构造网格，缩小时才会保持清楚。
