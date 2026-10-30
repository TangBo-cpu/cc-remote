import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'data/native_session_api.dart';
import 'data/remote_models.dart';
import 'signal_console_theme.dart';

class NativeSessionPickerPage extends StatefulWidget {
  const NativeSessionPickerPage({
    super.key,
    required this.initialEngine,
    required this.onList,
    required this.onSync,
    required this.busyListenable,
  });

  final SessionEngine initialEngine;
  final Future<NativeSessionPage> Function(SessionEngine engine, String? cursor)
  onList;
  final Future<void> Function(NativeDesktopSession session) onSync;
  final ValueListenable<bool> busyListenable;

  @override
  State<NativeSessionPickerPage> createState() =>
      _NativeSessionPickerPageState();
}

class _NativeSessionPickerPageState extends State<NativeSessionPickerPage> {
  late SessionEngine engine = widget.initialEngine;
  final sessions = <NativeDesktopSession>[];
  NativeDesktopSession? selected;
  String? nextCursor;
  String? error;
  int? maxSessionBytes;
  bool loading = true;
  bool syncing = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load({bool more = false}) async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
      if (!more) {
        sessions.clear();
        selected = null;
        nextCursor = null;
      }
    });
    try {
      final page = await widget.onList(engine, more ? nextCursor : null);
      if (!mounted || request != generation) return;
      setState(() {
        final ids = sessions.map((item) => item.sessionId).toSet();
        sessions.addAll(page.sessions.where((item) => ids.add(item.sessionId)));
        nextCursor = page.nextCursor;
        maxSessionBytes = page.maxSessionBytes;
        loading = false;
      });
    } catch (failure) {
      if (!mounted || request != generation) return;
      setState(() {
        loading = false;
        error = nativeSessionErrorMessage(failure);
      });
    }
  }

  Future<void> sync() async {
    final target = selected;
    if (target == null || syncing || loading || widget.busyListenable.value) {
      return;
    }
    setState(() {
      syncing = true;
      error = null;
    });
    try {
      await widget.onSync(target);
      if (!mounted) return;
      setState(() => syncing = false);
      Navigator.of(context).pop();
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        syncing = false;
        error = nativeSessionErrorMessage(failure);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return PopScope(
      canPop: !syncing,
      child: Scaffold(
        key: const ValueKey('native-session-picker'),
        backgroundColor: palette.paper,
        appBar: AppBar(
          title: const Text('同步电脑会话'),
          backgroundColor: palette.paper,
          surfaceTintColor: Colors.transparent,
          actions: [
            IconButton(
              tooltip: '刷新电脑会话',
              onPressed: syncing || loading ? null : () => unawaited(load()),
              icon: const Icon(LucideIcons.refreshCw),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('每次选择一个会话，重复同步会更新已有记录。'),
                  const SizedBox(height: 8),
                  Text(
                    maxSessionBytes == null
                        ? '过长或无法读取的会话会自动过滤。'
                        : '超过 ${maxSessionBytes! ~/ (1024 * 1024)} MB 或无法读取的会话已过滤。',
                    style: TextStyle(color: palette.muted),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<SessionEngine>(
                    segments: [
                      for (final option in SessionEngine.values)
                        ButtonSegment(
                          value: option,
                          label: Text(option.displayName),
                        ),
                    ],
                    selected: {engine},
                    onSelectionChanged: syncing
                        ? null
                        : (values) {
                            setState(() => engine = values.single);
                            unawaited(load());
                          },
                  ),
                ],
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(error!, style: TextStyle(color: palette.danger)),
                ),
              ),
            Expanded(
              child: loading && sessions.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (sessions.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              error == null ? '没有找到可同步的电脑会话' : '请刷新列表后重试',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: palette.muted),
                            ),
                          ),
                        for (final session in sessions)
                          ListTile(
                            key: ValueKey(
                              'native-session-${session.sessionId}',
                            ),
                            selected: selected?.sessionId == session.sessionId,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 6,
                            ),
                            title: Text(
                              session.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${session.workspaceDir}\n${session.updatedAt.toLocal().toString().substring(0, 16)}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Icon(
                              selected?.sessionId == session.sessionId
                                  ? LucideIcons.circleCheck
                                  : LucideIcons.circle,
                              color: selected?.sessionId == session.sessionId
                                  ? palette.ink
                                  : palette.muted,
                            ),
                            onTap: syncing
                                ? null
                                : () => setState(() => selected = session),
                          ),
                        if (nextCursor != null)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: TextButton(
                              onPressed: loading || syncing
                                  ? null
                                  : () => unawaited(load(more: true)),
                              child: Text(loading ? '正在加载…' : '加载更多'),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.busyListenable,
              builder: (_, busy, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('当前任务或附件操作尚未结束，请稍后同步。'),
                    ),
                  FilledButton.icon(
                    key: const ValueKey('sync-native-session'),
                    onPressed: busy || syncing || loading || selected == null
                        ? null
                        : sync,
                    icon: syncing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            LucideIcons.refreshCw,
                            size: AppIconSizes.control,
                          ),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(syncing ? '正在同步会话…' : '同步并打开'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
