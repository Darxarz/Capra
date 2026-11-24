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

/// Русская форма слова при числе: 1 файл, 2 файла, 5 файлов, 11 файлов, 21 файл.
String pluralRu(int n, String one, String few, String many) {
  final a = n.abs();
  final tens = a % 100;
  if (tens >= 11 && tens <= 14) return many;
  final last = a % 10;
  if (last == 1) return one;
  if (last >= 2 && last <= 4) return few;
  return many;
}

/// «3 изображения» / «3 images» / «3 imágenes».
String picturesLabel(int n) => '$n ${tr(
      pluralRu(n, 'изображение', 'изображения', 'изображений'),
      n == 1 ? 'image' : 'images',
      n == 1 ? 'imagen' : 'imágenes',
    )}';

/// «3 видео» / «3 videos» / «3 vídeos» (по-русски слово не склоняется).
String videosLabel(int n) => '$n ${tr(
      'видео',
      n == 1 ? 'video' : 'videos',
      n == 1 ? 'vídeo' : 'vídeos',
    )}';

/// «3 файла» — когда неизвестно, сколько среди них картинок и видео.
String filesLabel(int n) => '$n ${tr(
      pluralRu(n, 'файл', 'файла', 'файлов'),
      n == 1 ? 'file' : 'files',
      n == 1 ? 'archivo' : 'archivos',
    )}';

/// Строка состояния: картинки и видео отдельно, пустая часть не показывается.
String mediaCountLabel(int pictures, int videos) {
  if (videos == 0) return picturesLabel(pictures);
  if (pictures == 0) return videosLabel(videos);
  return '${picturesLabel(pictures)} · ${videosLabel(videos)}';
}
