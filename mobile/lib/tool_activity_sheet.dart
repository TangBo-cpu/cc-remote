import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'activity_disclosure.dart';
import 'data/remote_models.dart';
import 'signal_console_theme.dart';
import 'thinking_block.dart' show thinkingDurationLabel;
import 'workspace_paths.dart';

String toolActivityStateLabel(ActivityState? state) => switch (state) {
  ActivityState.running => '运行中',
  ActivityState.done => '已完成',
  ActivityState.error => '执行失败',
  ActivityState.stopped => '已停止',
  null => '状态未知',
};

Future<void> showToolActivityDetail(
  BuildContext context, {
  required ValueListenable<TranscriptMessage> activity,
  required String title,
}) {
  final portal = WorkspacePortal.of(context);
  final sourceMedia = MediaQuery.of(context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: AppPalette.of(context).scrim,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 720),
    sheetAnimationStyle: reduceMotion
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: ActivityMotion.sheet,
            reverseDuration: ActivityMotion.fast,
          ),
    builder: (sheetContext) => MediaQuery(
      data: MediaQuery.of(sheetContext).copyWith(
        textScaler: sourceMedia.textScaler,
        disableAnimations:
            reduceMotion || MediaQuery.disableAnimationsOf(sheetContext),
      ),
      child: WorkspacePortal(
        workspaceDir: portal?.workspaceDir,
        onOpenPath: portal?.onOpenPath,
        child: _ToolActivityDetail(activity: activity, title: title),
      ),
    ),
  );
}

class _ToolActivityDetail extends StatelessWidget {
  const _ToolActivityDetail({required this.activity, required this.title});

  final ValueListenable<TranscriptMessage> activity;
  final String title;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final media = MediaQuery.of(context);
    final titleStyle = TextStyle(
      color: palette.ink,
      fontSize: 18,
      fontWeight: FontWeight.w500,
      height: 1.4,
    );
    return DraggableScrollableSheet(
      initialChildSize: 0.4,
      minChildSize: 0,
      maxChildSize: 0.8,
      snap: true,
      snapSizes: const [0.4, 0.8],
      snapAnimationDuration: MediaQuery.disableAnimationsOf(context)
          ? const Duration(milliseconds: 1)
          : ActivityMotion.sheet,
      expand: false,
      builder: (context, scrollController) => Material(
        key: const ValueKey('tool-activity-sheet'),
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        clipBehavior: Clip.antiAlias,
        child: ValueListenableBuilder<TranscriptMessage>(
          valueListenable: activity,
          builder: (context, message, _) => LayoutBuilder(
            builder: (context, constraints) {
              final titlePainter = TextPainter(
                text: TextSpan(text: title, style: titleStyle),
                textDirection: Directionality.of(context),
                textScaler: media.textScaler,
                maxLines: 2,
              )..layout(maxWidth: math.max(1, constraints.maxWidth - 40));
              final headerHeight =
                  16.0 + math.max(56.0, titlePainter.height + 12.0);
              titlePainter.dispose();
              final status = toolActivityStateLabel(message.activityState);
              final duration = thinkingDurationLabel(
                message.activityDurationMs,
              );
              final tone = switch (message.activityState) {
                ActivityState.error => palette.danger,
                ActivityState.stopped => palette.warning,
                _ => palette.muted,
              };
              final detail = message.activityDetail?.trim() ?? '';
              return CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _ToolDetailHeader(
                      title: title,
                      style: titleStyle,
                      height: headerHeight,
                      color: palette.surface,
                      handleColor: palette.lineStrong,
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      16,
                      0,
                      16,
                      math.max(media.padding.bottom, 16),
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              '$status${duration.isEmpty ? '' : ' · $duration'}',
                              key: const ValueKey('tool-detail-status'),
                              style: TextStyle(
                                color: tone,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '调用详情',
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          WorkspacePathText(
                            detail.isEmpty ? '暂无调用详情' : detail,
                            key: ValueKey(
                              'activity-detail-${message.activityId}',
                            ),
                            selectable: true,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 14,
                              height: 1.6,
                              fontFamily: message.activityTool == 'Bash'
                                  ? AppTypography.codeFontFamily
                                  : null,
                              fontFamilyFallback: message.activityTool == 'Bash'
                                  ? AppTypography.codeFontFamilyFallback
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ToolDetailHeader extends SliverPersistentHeaderDelegate {
  const _ToolDetailHeader({
    required this.title,
    required this.style,
    required this.height,
    required this.color,
    required this.handleColor,
  });

  final String title;
  final TextStyle style;
  final double height;
  final Color color;
  final Color handleColor;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: color,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              key: const ValueKey('tool-detail-handle'),
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: style,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  bool shouldRebuild(covariant _ToolDetailHeader oldDelegate) =>
      title != oldDelegate.title ||
      style != oldDelegate.style ||
      height != oldDelegate.height ||
      color != oldDelegate.color ||
      handleColor != oldDelegate.handleColor;
}
