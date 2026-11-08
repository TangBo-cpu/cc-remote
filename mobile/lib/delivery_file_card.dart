import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'attachments.dart';
import 'data/remote_models.dart';
import 'delivery_files.dart';
import 'noto_icon.dart';
import 'signal_console_theme.dart';

class DeliveryFileCard extends StatefulWidget {
  const DeliveryFileCard({
    super.key,
    required this.files,
    required this.session,
    required this.sessionId,
  });

  final List<RemoteAttachment> files;
  final SavedSession? session;
  final String? sessionId;

  @override
  State<DeliveryFileCard> createState() => _DeliveryFileCardState();
}

class _DeliveryFileCardState extends State<DeliveryFileCard> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final files = widget.files;
    if (files.isEmpty) return const SizedBox.shrink();
    return SelectionContainer.disabled(
      child: Material(
        key: const ValueKey('delivery-file-card'),
        color: palette.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: palette.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(
                children: [
                  const SmartIcon(LucideIcons.package, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '交付文件 · ${files.length}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final file in expanded ? files : files.take(4))
              _DeliveryFileRow(
                key: ValueKey((
                  widget.session?.origin,
                  widget.sessionId,
                  file.id,
                )),
                attachment: file,
                session: widget.session,
                sessionId: widget.sessionId,
              ),
            if (files.length > 4)
              TextButton.icon(
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(
                  expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 16,
                ),
                label: Text(expanded ? '收起文件' : '查看全部 ${files.length} 个文件'),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

enum _FileAction { preview, open, save, share, copyPath }

class _DeliveryFileRow extends StatefulWidget {
  const _DeliveryFileRow({
    super.key,
    required this.attachment,
    required this.session,
    required this.sessionId,
  });

  final RemoteAttachment attachment;
  final SavedSession? session;
  final String? sessionId;

  @override
  State<_DeliveryFileRow> createState() => _DeliveryFileRowState();
}

class _DeliveryFileRowState extends State<_DeliveryFileRow> {
  File? localFile;
  http.Client? client;
  bool busy = false;
  String? note;
  bool failed = false;

  String get extension => widget.attachment.name.split('.').last.toLowerCase();
  bool get bitmap => widget.attachment.isImage && extension != 'svg';
  bool get textFile =>
      widget.attachment.mimeType.startsWith('text/') || extension == 'svg';
  bool get previewable => bitmap || textFile;

  @override
  void dispose() {
    client?.close();
    super.dispose();
  }

  Future<void> act(_FileAction action) async {
    if (busy) return;
    setState(() {
      busy = true;
      failed = false;
      note = '正在获取文件…';
    });
    try {
      final attachment = widget.attachment;
      if (action == _FileAction.copyPath) {
        await Clipboard.setData(
          ClipboardData(text: attachment.source ?? attachment.name),
        );
        if (mounted) setState(() => note = '路径已复制');
        return;
      }
      final session = widget.session;
      final sessionId = widget.sessionId;
      if (session == null || sessionId == null) {
        throw const AttachmentException('offline');
      }
      var file = localFile;
      if (file == null || !await file.exists()) {
        final downloadClient = http.Client();
        client = downloadClient;
        var lastPercent = -1;
        try {
          file = await downloadDelivery(
            client: downloadClient,
            attachment: attachment,
            session: session,
            sessionId: sessionId,
            onProgress: (value) {
              final percent = (value * 100).floor();
              if (mounted && percent != lastPercent) {
                lastPercent = percent;
                setState(() => note = '正在获取文件… $percent%');
              }
            },
          );
          localFile = file;
        } finally {
          downloadClient.close();
          client = null;
        }
      }
      if (!mounted) return;
      setState(() => note = action == _FileAction.save ? '正在保存…' : '正在打开…');
      switch (action) {
        case _FileAction.preview:
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  _DeliveryPreview(file: file!, attachment: attachment),
            ),
          );
        case _FileAction.save:
          final saved = await FilePicker.saveFile(
            dialogTitle: '保存交付文件',
            fileName: file.uri.pathSegments.last,
            bytes: await file.readAsBytes(),
          );
          if (mounted) setState(() => note = saved == null ? null : '文件已保存');
          return;
        case _FileAction.open:
        case _FileAction.share:
          await openDeliveryFile(
            file,
            attachment.mimeType,
            share: action == _FileAction.share,
          );
        case _FileAction.copyPath:
          break;
      }
      if (mounted) setState(() => note = null);
    } catch (error) {
      final code = error is PlatformException
          ? error.code
          : error is AttachmentException
          ? error.code
          : '';
      if (mounted) {
        setState(() {
          failed = true;
          note = switch (code) {
            'no_app' => '没有可打开此文件的应用，可先保存',
            'unauthorized' => '连接授权已失效，请重新配对',
            'attachment_not_found' => '文件已不存在',
            'attachment_too_large' => '文件超过 25 MB 限制',
            'offline' => '请先连接电脑',
            _ => '文件操作失败，请重试',
          };
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    final palette = AppPalette.of(context);
    final (icon, color) = switch (extension) {
      'pdf' => (LucideIcons.fileText, palette.danger),
      'xls' ||
      'xlsx' ||
      'csv' ||
      'tsv' => (LucideIcons.table2, palette.success),
      'ppt' || 'pptx' => (LucideIcons.presentation, palette.warning),
      'doc' || 'docx' => (LucideIcons.fileText, palette.iconAccent),
      'zip' || '7z' || 'tar' || 'gz' => (LucideIcons.archive, palette.warning),
      _ => (
        attachment.isImage ? LucideIcons.image : LucideIcons.file,
        palette.iconAccent,
      ),
    };
    final thumb = Icon(icon, color: color, size: 22);
    final session = widget.session;
    final sessionId = widget.sessionId;
    return InkWell(
      onTap: busy
          ? null
          : () => act(previewable ? _FileAction.preview : _FileAction.open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: bitmap && session != null && sessionId != null
                  ? Image.network(
                      attachment
                          .contentUri(session.origin, sessionId)
                          .toString(),
                      headers: {'Authorization': 'Bearer ${session.token}'},
                      cacheWidth: 120,
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                      errorBuilder: (_, _, _) => thumb,
                    )
                  : thumb,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      color: palette.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    note ??
                        '${extension.toUpperCase()} · ${formatAttachmentSize(attachment.size)}',
                    maxLines: failed ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: failed ? palette.danger : palette.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            if (!busy)
              PopupMenuButton<_FileAction>(
                tooltip: '${attachment.name}的操作',
                icon: Icon(
                  LucideIcons.ellipsis,
                  color: palette.muted,
                  size: 20,
                ),
                onSelected: act,
                itemBuilder: (_) => [
                  if (previewable)
                    const PopupMenuItem(
                      value: _FileAction.preview,
                      child: Text('预览'),
                    ),
                  const PopupMenuItem(
                    value: _FileAction.open,
                    child: Text('用其他应用打开'),
                  ),
                  const PopupMenuItem(
                    value: _FileAction.save,
                    child: Text('保存到手机'),
                  ),
                  const PopupMenuItem(
                    value: _FileAction.share,
                    child: Text('分享文件'),
                  ),
                  if (attachment.source != null)
                    const PopupMenuItem(
                      value: _FileAction.copyPath,
                      child: Text('复制路径'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _DeliveryPreview extends StatefulWidget {
  const _DeliveryPreview({required this.file, required this.attachment});
  final File file;
  final RemoteAttachment attachment;

  @override
  State<_DeliveryPreview> createState() => _DeliveryPreviewState();
}

class _DeliveryPreviewState extends State<_DeliveryPreview> {
  static const textLimit = 768 * 1024;
  late final bool bitmap =
      widget.attachment.isImage &&
      widget.attachment.mimeType != 'image/svg+xml';
  late final Future<String>? text = bitmap ? null : readText();

  Future<String> readText() async {
    final input = await widget.file.open();
    try {
      return utf8.decode(await input.read(textLimit), allowMalformed: true);
    } finally {
      await input.close();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.attachment.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: bitmap
        ? Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.file(
                widget.file,
                errorBuilder: (_, _, _) => const Text('无法预览此图片，请用其他应用打开'),
              ),
            ),
          )
        : FutureBuilder<String>(
            future: text,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('无法读取文件，请返回重试'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.attachment.size > textLimit)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text('仅预览前 768 KB，保存后可查看完整文件'),
                        ),
                      if (widget.attachment.mimeType == 'text/markdown')
                        MarkdownBody(
                          data: snapshot.data!,
                          imageBuilder: (_, _, _) => const SizedBox.shrink(),
                        )
                      else
                        Text(
                          snapshot.data!,
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}
