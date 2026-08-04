import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:photo_manager/photo_manager.dart';
import 'preview_service.dart';
import 'settings_service.dart';
import 'asset_image.dart';
import 'i18n.dart';

/// Расширения, которые считаем изображениями.
const Set<String> kImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.jfif'
};

/// Расширения, которые считаем видео.
const Set<String> kVideoExtensions = {
  '.mp4',
  '.m4v',
  '.mov',
  '.webm',
  '.mkv',
  '.avi',
  '.wmv',
  '.3gp',
  '.3gpp',
};

/// «Проектные» форматы редакторов: показываем встроенное превью, открываем
/// в соответствующем редакторе.
const Set<String> kProjectExtensions = {'.kra', '.psd'};

/// Потолок декодирования полного фото (по большей стороне, px). Защищает от
/// гигантских картинок, разворачивающихся в сотни МБ. 4096² ≈ 67 МБ на кадр.
const int _kFullDecodeMax = 4096;

/// Всё, что собираем при сканировании (картинки + видео + проекты).
const Set<String> kScanExtensions = {
  ...kImageExtensions,
  ...kVideoExtensions,
  ...kProjectExtensions,
};

/// Одно изображение. Обычно — файл на диске; но может быть и удалённым,
/// если получено с другого устройства по локальной сети (тогда заданы
/// remote-поля, а thumb/full тянутся по сети с хоста).
class PhotoItem {
  final String path; // полный путь к файлу (для удалённого — имя файла)
  final bool isGif;
  final bool isVideo;
  final String folderPath; // путь к папке-родителю
  final String folderName; // имя папки
  final DateTime modified;
  final int sizeBytes;
  final String?
      assetId; // id в MediaStore (Android) — для удаления через систему

  // ── удалённое фото (по локальной сети) ──
  final String? remoteBase; // напр. "http://192.168.1.5:8787"
  final String? remoteToken; // токен сессии, выданный хостом при сопряжении
  final String? remoteId; // id фото на хосте

  const PhotoItem({
    required this.path,
    required this.isGif,
    this.isVideo = false,
    required this.folderPath,
    required this.folderName,
    required this.modified,
    required this.sizeBytes,
    this.assetId,
    this.remoteBase,
    this.remoteToken,
    this.remoteId,
  });

  /// true — фото получено с другого устройства, файла на диске нет.
  bool get isRemote => remoteBase != null;

  /// Читаемый файл для операций, которым нужны пиксели/байты (поделиться,
  /// тегирование, метаданные). На Android с MediaStore прямой путь может быть
  /// недоступен — тогда берём файл через ассет (система отдаёт читаемую копию).
  Future<File?> resolveFile() async {
    if (isRemote) return null;
    if (Platform.isAndroid && assetId != null) {
      try {
        final a = await AssetEntity.fromId(assetId!);
        return await a?.file;
      } catch (_) {
        return null;
      }
    }
    final f = File(path);
    return f.existsSync() ? f : null;
  }

  /// Расширение в нижнем регистре (с точкой), напр. '.kra'.
  String get extension {
    final i = path.lastIndexOf('.');
    return i >= 0 ? path.substring(i).toLowerCase() : '';
  }

  /// true — «проектный» формат редактора (KRA/PSD): нужно встроенное превью.
  bool get isProject => kProjectExtensions.contains(extension);

  String get fileName {
    if (isRemote) return path; // у удалённого в path лежит имя
    final sep = path.contains('/') ? '/' : Platform.pathSeparator;
    final i = path.lastIndexOf(sep);
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /// Превью: декодируется уменьшённым (cacheWidth) — это и держит сетку лёгкой.
  /// Для удалённого фото — с хоста; для KRA/PSD — встроенное превью.
  ImageProvider thumb(int cacheWidth) {
    if (isRemote) {
      return NetworkImage(
          '$remoteBase/thumb?token=$remoteToken&id=$remoteId&w=$cacheWidth');
    }
    if (isProject) {
      return ProjectImage(path,
          mtime: modified.millisecondsSinceEpoch,
          full: false,
          cacheWidth: cacheWidth);
    }
    // Android: миниатюра прямо из MediaStore (быстро, без чтения файла).
    if (assetId != null && Platform.isAndroid) {
      return AssetThumbImage(assetId!, size: cacheWidth);
    }
    return CachedThumbImage(
      path,
      mtime: modified.millisecondsSinceEpoch,
      cacheWidth: cacheWidth,
      avoidCloudDownload: SettingsService.instance.avoidCloudThumbnailDownloads,
    );
  }

  /// Полный размер — только для открытого на весь экран фото.
  ///
  /// Декод ограничен потолком [_kFullDecodeMax] по большей стороне: огромная
  /// картинка (напр. 12000×12000) иначе разворачивается в памяти в сотни МБ и
  /// вешает/роняет приложение (особенно на Windows). Маленькие не трогаются
  /// (allowUpscaling: false) — для них качество полное.
  ImageProvider get full {
    if (isRemote) {
      return NetworkImage('$remoteBase/file?token=$remoteToken&id=$remoteId');
    }
    if (isProject) {
      return ProjectImage(path,
          mtime: modified.millisecondsSinceEpoch, full: true);
    }
    // Android: крупный кадр из MediaStore (с потолком, без чтения файла).
    if (assetId != null && Platform.isAndroid) {
      return AssetThumbImage(assetId!, size: _kFullDecodeMax);
    }
    return ResizeImage(
      FileImage(File(path)),
      width: _kFullDecodeMax,
      height: _kFullDecodeMax,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
  }
}

/// Альбом = папка на диске.
class AlbumItem {
  final String name;
  final String folderPath;
  final int count;
  final PhotoItem? cover;
  const AlbumItem({
    required this.name,
    required this.folderPath,
    required this.count,
    this.cover,
  });
}

const List<String> _monthsRu = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
];
const List<String> _monthsEn = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];
const List<String> _monthsEs = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
];

String _monthName(int month) {
  switch (uiLang) {
    case AppLang.en:
      return _monthsEn[month - 1];
    case AppLang.es:
      return _monthsEs[month - 1];
    default:
      return _monthsRu[month - 1];
  }
}

/// «5 января» / «January 5» / «5 de enero» — порядок зависит от языка.
String _dayMonth(DateTime d, {bool withYear = false}) {
  final mn = _monthName(d.month);
  switch (uiLang) {
    case AppLang.en:
      return withYear ? '$mn ${d.day}, ${d.year}' : '$mn ${d.day}';
    case AppLang.es:
      return withYear ? '${d.day} de $mn ${d.year}' : '${d.day} de $mn';
    default:
      return withYear ? '${d.day} $mn ${d.year}' : '${d.day} $mn';
  }
}

String _two(int n) => n < 10 ? '0$n' : '$n';

/// Группа по дате для режима «По датам».
String dateGroupOf(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff <= 0) return tr('Сегодня', 'Today', 'Hoy');
  if (diff == 1) return tr('Вчера', 'Yesterday', 'Ayer');
  if (diff < 7) return tr('На этой неделе', 'This week', 'Esta semana');
  return _dayMonth(d, withYear: d.year != now.year);
}

String prettyDate(DateTime d) =>
    '${_dayMonth(d, withYear: true)}, ${_two(d.hour)}:${_two(d.minute)}';

String prettySize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} ${tr('МБ', 'MB', 'MB')}';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} ${tr('КБ', 'KB', 'KB')}';
  }
  return '$bytes ${tr('Б', 'B', 'B')}';
}
