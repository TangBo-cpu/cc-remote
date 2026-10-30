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

class ToolActivityDetail extends StatefulWidget {
  const ToolActivityDetail({
    super.key,
    required this.activity,
    required this.title,
    required this.titleWidget,
    required this.leading,
    this.running = false,
    this.reveal = false,
  });

  final TranscriptMessage activity;
  final String title;
  final Widget titleWidget;
  final Widget leading;
  final bool running;
  final bool reveal;

  @override
  State<ToolActivityDetail> createState() => _ToolActivityDetailState();
}

class _ToolActivityDetailState extends State<ToolActivityDetail> {
  bool expanded = true;
  bool fullDetail = false;

  @override
  void initState() {
    super.initState();
    expanded =
        PageStorage.maybeOf(context)?.readState(
              context,
              identifier: ('tool-expanded', widget.activity.activityId),
            )
            as bool? ??
        true;
    fullDetail =
        PageStorage.maybeOf(context)?.readState(
              context,
              identifier: ('tool-detail-full', widget.activity.activityId),
            )
            as bool? ??
        false;
  }

  @override
  void didUpdateWidget(covariant ToolActivityDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.activityId != widget.activity.activityId) {
      expanded = true;
      fullDetail = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.activity;
    final palette = AppPalette.of(context);
    final detail = message.activityDetail?.trim() ?? '';
    final duration = thinkingDurationLabel(message.activityDurationMs);
    final fileAction = switch (message.activityTool) {
      'Read' => '读取',
      'Write' => '写入',
      'Edit' => '修改',
      'FileChange' => '变更',
      _ => null,
    };
    final filePath =
        fileAction != null && detail.isNotEmpty && !detail.contains('\n')
        ? normalizeWorkspacePath(
                detail,
                workspaceDir: WorkspacePortal.of(context)?.workspaceDir,
              ) ??
              detail.replaceAll(r'\', '/')
        : null;
    final fileName = filePath?.split('/').last;
    final status = toolActivityStateLabel(message.activityState);
    final tone = switch (message.activityState) {
      ActivityState.error => palette.danger,
      ActivityState.stopped => palette.warning,
      _ => palette.muted,
    };
    return ActivityDisclosure(
      toggleKey: ValueKey('activity-step-toggle-${message.activityId}'),
      contentRevision: (fullDetail, widget.reveal),
      title: fileName ?? widget.title,
      titleWidget: fileName == null
          ? widget.titleWidget
          : Tooltip(
              message: filePath!,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: message.activityState == ActivityState.error
                            ? palette.danger
                            : palette.ink,
                        fontSize: AppTypography.activityBodySize,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.control,
                      borderRadius: BorderRadius.circular(AppRadii.compact),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        fileAction!,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
      leading: widget.leading,
      running: widget.running,
      compact: true,
      expanded: (expanded || widget.reveal) && detail.isNotEmpty,
      statusText: '$status${duration.isEmpty ? '' : ' · $duration'}',
      tone: tone,
      semanticLabel:
          '${filePath == null ? widget.title : '$fileAction $filePath'}，$status'
          '${duration.isEmpty ? '' : '，$duration'}',
      onToggle: detail.isEmpty
          ? null
          : () {
              setState(() => expanded = !expanded);
              PageStorage.maybeOf(context)?.writeState(
                context,
                expanded,
                identifier: ('tool-expanded', message.activityId),
              );
            },
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 8, 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final text = filePath ?? detail;
            final style = DefaultTextStyle.of(context).style.merge(
              TextStyle(
                color: palette.muted,
                fontSize: AppTypography.activityBodySize,
                height: 1.6,
                fontFamily:
                    filePath != null ||
                        const {'Bash', 'Shell'}.contains(message.activityTool)
                    ? AppTypography.codeFontFamily
                    : null,
                fontFamilyFallback:
                    filePath != null ||
                        const {'Bash', 'Shell'}.contains(message.activityTool)
                    ? AppTypography.codeFontFamilyFallback
                    : null,
              ),
            );
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              maxLines: 3,
              ellipsis: '…',
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
              locale: Localizations.maybeLocaleOf(context),
            )..layout(maxWidth: constraints.maxWidth);
            final overflows = painter.didExceedMaxLines;
            painter.dispose();
            final showFull = !overflows || fullDetail || widget.reveal;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WorkspacePathText(
                  text,
                  key: ValueKey('activity-detail-${message.activityId}'),
                  selectable: showFull,
                  maxLines: showFull ? null : 3,
                  overflow: showFull ? null : TextOverflow.ellipsis,
                  style: style,
                ),
                if (overflows && !widget.reveal)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: ValueKey(
                        'activity-detail-more-${message.activityId}',
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSizes.touchTarget),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        textStyle: const TextStyle(
                          fontSize: AppTypography.activityBodySize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onPressed: () {
                        setState(() => fullDetail = !fullDetail);
                        PageStorage.maybeOf(context)?.writeState(
                          context,
                          fullDetail,
                          identifier: ('tool-detail-full', message.activityId),
                        );
                      },
                      child: Text(fullDetail ? '收起详情' : '展开全部'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
