import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'signal_console_theme.dart';

/// Noto Emoji 的扁平彩色字形（Apache-2.0，署名见 assets/noto/README.md）。
///
/// 保留字形原色，不随选中或语义色切换图标集；禁用态降低透明度。
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
    this.opacity = 1,
  });

  final NotoGlyph glyph;
  final double size;
  final String? semanticLabel;
  final double opacity;

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
      opacity: AlwaysStoppedAnimation(opacity),
    );
  }
}

/// 查表：Lucide 图标 → Noto 彩色字形。没有对应项时返回 null。
NotoGlyph? notoGlyphFor(IconData? icon) => switch (icon) {
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

/// 优先使用 Noto 彩色字形，其余符号使用主题图标色或调用方的语义色。
class SmartIcon extends StatelessWidget {
  const SmartIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final IconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final iconTheme = IconTheme.of(context);
    final requestedColor = color ?? iconTheme.color;
    final alpha = requestedColor == palette.inactive
        ? 0.4
        : requestedColor?.a ?? 1.0;
    final glyph = notoGlyphFor(icon);
    if (glyph != null) {
      return NotoIcon(
        glyph,
        size: size ?? iconTheme.size ?? AppIconSizes.control,
        semanticLabel: semanticLabel,
        opacity: alpha * (iconTheme.opacity ?? 1),
      );
    }
    final neutral =
        requestedColor == null ||
        (requestedColor.r == requestedColor.g &&
            requestedColor.g == requestedColor.b);
    // 实心按钮仍用配对前景色，避免彩色线条在按钮底色上失去对比。
    final buttonForeground =
        requestedColor == palette.onCta || requestedColor == palette.onStop;
    return Icon(
      icon,
      size: size,
      color: neutral && !buttonForeground
          ? palette.iconAccent.withValues(alpha: alpha)
          : requestedColor,
      semanticLabel: semanticLabel,
    );
  }
}
