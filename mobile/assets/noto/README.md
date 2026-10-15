# Noto Emoji — 第三方素材署名

本目录下的 PNG 图标来自 **Noto Emoji**，按 Apache License 2.0 使用。

| 项 | 内容 |
|---|---|
| 来源项目 | [googlefonts/noto-emoji](https://github.com/googlefonts/noto-emoji) |
| 素材索引 | Iconify 的 [`noto`](https://icon-sets.iconify.design/noto/) 图标集（3819 个） |
| 作者 | Google LLC |
| 图像资源许可 | **Apache License, Version 2.0**（原文见同目录 `LICENSE.txt`） |
| 字体许可 | SIL Open Font License 1.1 —— **本项目未使用其字体**，只用 SVG/PNG 图形 |

上游 README 原文：

> Tools and most image resources are under the [Apache license, version 2.0](./LICENSE).

## 加工方式

原始素材是 128×128 的 SVG。这里光栅化为 **128×128 PNG**（渲染器 `cairosvg`），
文件名对应 `lib/noto_icon.dart` 中 `NotoGlyph` 的枚举值。

再生成：

```bash
python tool/rasterize_noto_emoji.py     # 在 mobile/ 目录下执行
```

脚本会自己下载 Iconify 的 `noto` 数据，再按 `lib/noto_icon.dart` 里的映射重新渲染。
新增图标时，先在该文件的 `NotoGlyph` 里加条目，再跑一次脚本。

## 使用约束（重要）

这些图标是**多色位图**，因此：

- **不能**被 `IconTheme` / `color` 染色。需要语义着色的位置（危险红、成功绿、选中高亮）
  必须继续使用单色图标集。
- 代码中统一通过 `SmartIcon` 使用：它一旦收到 `color` 就自动回退成单色 `Icon`。
