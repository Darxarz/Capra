import 'dart:ui';
import 'settings_service.dart';

export 'settings_service.dart' show AppLang;

/// Действующий язык интерфейса (ru / en / es). Для режима «как в системе»
/// определяем по языку устройства: en и es распознаём, всё прочее → русский.
AppLang get uiLang {
  final l = SettingsService.instance.appLang;
  if (l != AppLang.system) return l;
  switch (PlatformDispatcher.instance.locale.languageCode) {
    case 'en':
      return AppLang.en;
    case 'es':
      return AppLang.es;
    default:
      return AppLang.ru;
  }
}

bool get isEnglishUi => uiLang == AppLang.en;

/// Перевод одной строки. Русский — обязательный фолбэк. Испанский ([es])
/// необязателен: пока его нет, испанский интерфейс показывает английский
/// перевод (а где нет и его — русский). Так языки добавляются постепенно.
String tr(String ru, String en, [String? es]) {
  switch (uiLang) {
    case AppLang.en:
      return en;
    case AppLang.es:
      return es ?? en;
    case AppLang.ru:
    case AppLang.system:
      return ru;
  }
}
