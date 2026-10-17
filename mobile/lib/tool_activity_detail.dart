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
  }

  @override
  void didUpdateWidget(covariant ToolActivityDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.activityId != widget.activity.activityId) {
      expanded = true;
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
        padding: const EdgeInsetsDirectional.fromSTEB(26, 0, 8, 8),
        child: WorkspacePathText(
          filePath ?? detail,
          key: ValueKey('activity-detail-${message.activityId}'),
          selectable: true,
          style: TextStyle(
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
        ),
      ),
    );
  }
}
