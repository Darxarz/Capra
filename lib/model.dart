import 'dart:io';
import 'package:flutter/widgets.dart';

/// Расширения, которые считаем изображениями.
const Set<String> kImageExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.jfif'
};

/// Одно изображение. Обычно — файл на диске; но может быть и удалённым,
/// если получено с другого устройства по локальной сети (тогда заданы
/// remote-поля, а thumb/full тянутся по сети с хоста).
class PhotoItem {
  final String path; // полный путь к файлу (для удалённого — имя файла)
  final bool isGif;
  final String folderPath; // путь к папке-родителю
  final String folderName; // имя папки
  final DateTime modified;
  final int sizeBytes;
  final String? assetId; // id в MediaStore (Android) — для удаления через систему

  // ── удалённое фото (по локальной сети) ──
  final String? remoteBase; // напр. "http://192.168.1.5:8787"
  final String? remoteToken; // токен сессии, выданный хостом при сопряжении
  final String? remoteId; // id фото на хосте

  const PhotoItem({
    required this.path,
    required this.isGif,
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

  String get fileName {
    if (isRemote) return path; // у удалённого в path лежит имя
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /// Превью: декодируется уменьшённым (cacheWidth) — это и держит сетку лёгкой.
  /// Для удалённого фото берётся уменьшённая версия прямо с хоста.
  ImageProvider thumb(int cacheWidth) {
    if (isRemote) {
      return NetworkImage(
          '$remoteBase/thumb?token=$remoteToken&id=$remoteId&w=$cacheWidth');
    }
    return ResizeImage(FileImage(File(path)),
        width: cacheWidth, allowUpscaling: false);
  }

  /// Полный размер — только для открытого на весь экран фото.
  ImageProvider get full {
    if (isRemote) {
      return NetworkImage('$remoteBase/file?token=$remoteToken&id=$remoteId');
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
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'
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
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  return '$bytes Б';
}
