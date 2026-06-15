import 'dart:ui';
import 'settings_service.dart';

export 'settings_service.dart' show AppLang;

/// Действующий язык — английский? Учитывает выбор в настройках, а для «как в
/// системе» — язык устройства (en → английский, иначе русский).
bool get isEnglishUi {
  switch (SettingsService.instance.appLang) {
    case AppLang.en:
      return true;
    case AppLang.ru:
      return false;
    case AppLang.system:
      return PlatformDispatcher.instance.locale.languageCode == 'en';
  }
}

/// Перевод одной строки: русский / английский. Если язык не английский —
/// возвращаем русский (он же фолбэк для непереведённого).
String tr(String ru, String en) => isEnglishUi ? en : ru;
