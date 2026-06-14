import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Держит раздачу по локальной сети живой в фоне. На Android для этого нужен
/// foreground-сервис с постоянным уведомлением (иначе система усыпляет
/// процесс и сервер отваливается при сворачивании/гашении экрана). WiFi-lock
/// не даёт Wi-Fi заснуть. На ПК сервер и так работает, пока приложение
/// запущено (в т.ч. свёрнуто), поэтому здесь только Android.
class BackgroundService {
  static bool _inited = false;

  static void _ensureInit() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'goat_share',
        channelName: 'Раздача GOAT',
        channelDescription: 'Сервер раздачи фото по локальной сети',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true, // держим Wi-Fi бодрым при погасшем экране
      ),
    );
    _inited = true;
  }

  /// Запустить фоновый сервис (Android). Тихо завершает, если что-то не так —
  /// раздача всё равно работает, пока приложение открыто.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      _ensureInit();
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 256,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'GOAT раздаёт фото',
        notificationText: 'Другие устройства могут подключиться по Wi-Fi',
      );
    } catch (_) {
      // не критично: на ПК и при отказе в уведомлениях раздача всё равно идёт
    }
  }

  /// Остановить фоновый сервис (Android).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}
