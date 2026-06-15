import 'dart:io';
import 'package:flutter/widgets.dart';
import 'preview_service.dart';
import 'settings_service.dart';

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
    return CachedThumbImage(
      path,
      mtime: modified.millisecondsSinceEpoch,
      cacheWidth: cacheWidth,
      avoidCloudDownload: SettingsService.instance.avoidCloudThumbnailDownloads,
    );
  }

  /// Полный размер — только для открытого на весь экран фото.
  ImageProvider get full {
    if (isRemote) {
      return NetworkImage('$remoteBase/file?token=$remoteToken&id=$remoteId');
    }
    if (isProject) {
      return ProjectImage(path,
          mtime: modified.millisecondsSinceEpoch, full: true);
    }
    return FileImage(File(path));
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

const List<String> _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря'
];

String _two(int n) => n < 10 ? '0$n' : '$n';

/// Группа по дате для режима «По датам».
String dateGroupOf(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff <= 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  if (diff < 7) return 'На этой неделе';
  if (d.year == now.year) return '${d.day} ${_months[d.month - 1]}';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

String prettyDate(DateTime d) =>
    '${d.day} ${_months[d.month - 1]} ${d.year}, ${_two(d.hour)}:${_two(d.minute)}';

String prettySize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  return '$bytes Б';
}
