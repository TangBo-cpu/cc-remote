import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppNotification {
  const AppNotification({
    required this.key,
    required this.title,
    required this.body,
    this.sessionId,
  });

  final String key;
  final String title;
  final String body;
  final String? sessionId;
}

abstract class BackgroundNotificationService {
  Future<void> initialize({required ValueChanged<String?> onTap});
  Future<bool> requestPermission();
  Future<void> show(AppNotification notification);
  Future<void> cancelAll();
}

class LocalBackgroundNotificationService
    implements BackgroundNotificationService {
  LocalBackgroundNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'cc_remote_tasks';
  static const channelName = 'Claude 任务';
  static const channelDescription = '任务完成、执行失败和权限确认通知';

  final FlutterLocalNotificationsPlugin plugin;

  @override
  Future<void> initialize({required ValueChanged<String?> onTap}) async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    );
    await plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      onTap(launch?.notificationResponse?.payload);
    }
  }

  @override
  Future<bool> requestPermission() async {
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ?? true;
  }

  @override
  Future<void> show(AppNotification notification) {
    return plugin.show(
      id: notification.key.hashCode & 0x7fffffff,
      title: notification.title,
      body: notification.body,
      payload: notification.sessionId == null
          ? null
          : 'session:${notification.sessionId}',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.status,
        ),
      ),
    );
  }

  @override
  Future<void> cancelAll() => plugin.cancelAll();
}

class BackgroundNotificationController {
  BackgroundNotificationController({
    required this.service,
    this.enabled = true,
    this.lifecycleState = AppLifecycleState.resumed,
  });

  final BackgroundNotificationService service;
  bool enabled;
  AppLifecycleState lifecycleState;

  Future<void> notify(AppNotification notification) async {
    if (!enabled || lifecycleState == AppLifecycleState.resumed) return;
    await service.show(notification);
  }
}

class NotificationPreferenceStore {
  NotificationPreferenceStore({FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();

  static const key = 'cc_remote_notifications_enabled';
  final FlutterSecureStorage storage;

  Future<bool> load() async {
    return await storage.read(key: key) != '0';
  }

  Future<void> save(bool enabled) {
    return storage.write(key: key, value: enabled ? '1' : '0');
  }
}

String notificationBody({
  required String? projectName,
  required String? sessionTitle,
  String? detail,
}) {
  final context = [
    projectName,
    sessionTitle,
  ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');
  final cleanDetail = detail?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleanDetail != null && cleanDetail.isNotEmpty) {
    return context.isEmpty ? cleanDetail : '$context\n$cleanDetail';
  }
  return context.isEmpty ? '打开 CC Remote 查看详情' : context;
}
