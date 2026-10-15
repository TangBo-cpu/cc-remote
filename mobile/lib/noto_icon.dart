import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'signal_console_theme.dart';

/// Noto Emoji 的扁平彩色字形（Apache-2.0，署名见 assets/noto/README.md）。
///
/// 这些图标是多色位图，**无法被 IconTheme 染色**。需要语义着色的位置
/// （危险红、成功绿、选中态）必须继续用单色图标集——统一走 [SmartIcon]，
/// 它会自己判断回退。
enum NotoGlyph {
  archive('archive', 'file-cabinet'),
  arrowLeftRight('arrowLeftRight', 'left-right-arrow'),
  arrowUpRight('arrowUpRight', 'up-right-arrow'),
  ban('ban', 'prohibited'),
  bell('bell', 'bell'),
  blocks('blocks', 'input-symbols'),
  brain('brain', 'brain'),
  calendarX('calendarX', 'calendar'),
  camera('camera', 'camera'),
  check('check', 'check-mark'),
  circleAlert('circleAlert', 'red-exclamation-mark'),
  circleCheck('circleCheck', 'check-mark-button'),
  circlePause('circlePause', 'pause-button'),
  cloudOff('cloudOff', 'cloud'),
  copy('copy', 'clipboard'),
  cpu('cpu', 'brain'),
  diamond('diamond', 'gem-stone'),
  eye('eye', 'eye'),
  feather('feather', 'feather'),
  file('file', 'page-facing-up'),
  fileText('fileText', 'page-facing-up'),
  folder('folder', 'file-folder'),
  folderOpen('folderOpen', 'open-file-folder'),
  globe('globe', 'globe-with-meridians'),
  image('image', 'framed-picture'),
  link('link', 'link'),
  lockKeyhole('lockKeyhole', 'locked'),
  monitor('monitor', 'desktop-computer'),
  monitorSmartphone('monitorSmartphone', 'desktop-computer'),
  moonStar('moonStar', 'crescent-moon'),
  packageBox('package', 'package'),
  pause('pause', 'pause-button'),
  pencil('pencil', 'pencil'),
  play('play', 'play-button'),
  plus('plus', 'plus'),
  qrCode('qrCode', 'input-numbers'),
  route('route', 'motorway'),
  search('search', 'magnifying-glass-tilted-left'),
  settings('settings', 'gear'),
  shield('shield', 'shield'),
  slidersHorizontal('slidersHorizontal', 'control-knobs'),
  smartphone('smartphone', 'mobile-phone'),
  sparkle('sparkle', 'sparkles'),
  sparkles('sparkles', 'sparkles'),
  sun('sun', 'sun'),
  sunMoon('sunMoon', 'crescent-moon'),
  trash2('trash2', 'wastebasket'),
  triangleAlert('triangleAlert', 'warning'),
  type('type', 'input-latin-uppercase'),
  uploadCloud('uploadCloud', 'outbox-tray'),
  user('user', 'bust-in-silhouette'),
  wrench('wrench', 'wrench'),
  ;

  const NotoGlyph(this.assetName, this.sourceName);

  /// 资源文件名（不含扩展名），位于 assets/noto/。
  final String assetName;

  /// 上游 Noto Emoji 中的原名，供 tool/rasterize_noto_emoji.py 重新渲染。
  final String sourceName;

  String get assetPath => 'assets/noto/$assetName.png';
}

/// 渲染一个 Noto 彩色字形。尺寸走 [AppIconSizes] 阶梯。
class NotoIcon extends StatelessWidget {
  const NotoIcon(
    this.glyph, {
    super.key,
    this.size = AppIconSizes.control,
    this.semanticLabel,
  });

  final NotoGlyph glyph;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      glyph.assetPath,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
      gaplessPlayback: true,
    );
  }
}

/// 查表：Lucide 图标 → Noto 彩色字形。没有对应项时返回 null。
///
/// 只在 [SmartIcon] 没收到显式 `color` 时才会用到——有 color 就说明这个位置
/// 靠颜色表达语义，彩色位图做不到。
NotoGlyph? notoGlyphFor(IconData icon) => switch (icon) {
  LucideIcons.archive => NotoGlyph.archive,
  LucideIcons.arrowLeftRight => NotoGlyph.arrowLeftRight,
  LucideIcons.arrowUpRight => NotoGlyph.arrowUpRight,
  LucideIcons.ban => NotoGlyph.ban,
  LucideIcons.bell => NotoGlyph.bell,
  LucideIcons.blocks => NotoGlyph.blocks,
  LucideIcons.brain => NotoGlyph.brain,
  LucideIcons.calendarX => NotoGlyph.calendarX,
  LucideIcons.camera => NotoGlyph.camera,
  LucideIcons.check => NotoGlyph.check,
  LucideIcons.circleAlert => NotoGlyph.circleAlert,
  LucideIcons.circleCheck => NotoGlyph.circleCheck,
  LucideIcons.circlePause => NotoGlyph.circlePause,
  LucideIcons.cloudOff => NotoGlyph.cloudOff,
  LucideIcons.copy => NotoGlyph.copy,
  LucideIcons.cpu => NotoGlyph.cpu,
  LucideIcons.diamond => NotoGlyph.diamond,
  LucideIcons.eye => NotoGlyph.eye,
  LucideIcons.feather => NotoGlyph.feather,
  LucideIcons.file => NotoGlyph.file,
  LucideIcons.fileText => NotoGlyph.fileText,
  LucideIcons.folder => NotoGlyph.folder,
  LucideIcons.folderOpen => NotoGlyph.folderOpen,
  LucideIcons.globe => NotoGlyph.globe,
  LucideIcons.image => NotoGlyph.image,
  LucideIcons.link => NotoGlyph.link,
  LucideIcons.lockKeyhole => NotoGlyph.lockKeyhole,
  LucideIcons.monitor => NotoGlyph.monitor,
  LucideIcons.monitorSmartphone => NotoGlyph.monitorSmartphone,
  LucideIcons.moonStar => NotoGlyph.moonStar,
  LucideIcons.package => NotoGlyph.packageBox,
  LucideIcons.pause => NotoGlyph.pause,
  LucideIcons.pencil => NotoGlyph.pencil,
  LucideIcons.play => NotoGlyph.play,
  LucideIcons.plus => NotoGlyph.plus,
  LucideIcons.qrCode => NotoGlyph.qrCode,
  LucideIcons.route => NotoGlyph.route,
  LucideIcons.search => NotoGlyph.search,
  LucideIcons.settings => NotoGlyph.settings,
  LucideIcons.shield => NotoGlyph.shield,
  LucideIcons.slidersHorizontal => NotoGlyph.slidersHorizontal,
  LucideIcons.smartphone => NotoGlyph.smartphone,
  LucideIcons.sparkle => NotoGlyph.sparkle,
  LucideIcons.sparkles => NotoGlyph.sparkles,
  LucideIcons.sun => NotoGlyph.sun,
  LucideIcons.sunMoon => NotoGlyph.sunMoon,
  LucideIcons.trash2 => NotoGlyph.trash2,
  LucideIcons.triangleAlert => NotoGlyph.triangleAlert,
  LucideIcons.type => NotoGlyph.type,
  LucideIcons.uploadCloud => NotoGlyph.uploadCloud,
  LucideIcons.user => NotoGlyph.user,
  LucideIcons.wrench => NotoGlyph.wrench,
  _ => null,
};

/// [Icon] 的直插替代：能彩色就彩色，需要着色就回退成单色。
///
/// 回退条件有两个，任一满足就走原来的 [Icon]：
///
/// 1. 调用方传了 `color` —— 说明该位置靠颜色表达语义（危险态、成功态、选中态）；
/// 2. 这个 [IconData] 在 [notoGlyphFor] 里查不到 —— Noto 没有对应概念。
///    典型是结构性符号：省略号、折叠箭头、终端、刷新、关闭。它们是形状不是实物，
///    本来就该是单色的。
class SmartIcon extends StatelessWidget {
  const SmartIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final NotoGlyph? glyph = color == null ? notoGlyphFor(icon) : null;
    if (glyph == null) {
      return Icon(icon, size: size, color: color, semanticLabel: semanticLabel);
    }
    return NotoIcon(glyph, size: size ?? 24, semanticLabel: semanticLabel);
  }
}
