import 'dart:io';
import 'package:flutter/widgets.dart';

/// Расширения, которые считаем изображениями.
const Set<String> kImageExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.jfif'
};

/// Одно изображение из файловой системы.
class PhotoItem {
  final String path; // полный путь к файлу
  final bool isGif;
  final String folderPath; // путь к папке-родителю
  final String folderName; // имя папки
  final DateTime modified;
  final int sizeBytes;

  const PhotoItem({
    required this.path,
    required this.isGif,
    required this.folderPath,
    required this.folderName,
    required this.modified,
    required this.sizeBytes,
  });

  String get fileName {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i >= 0 ? path.substring(i + 1) : path;
  }

  /// Превью: декодируется уменьшённым (cacheWidth) — это и держит сетку лёгкой.
  ImageProvider thumb(int cacheWidth) =>
      ResizeImage(FileImage(File(path)), width: cacheWidth, allowUpscaling: false);

  /// Полный размер — только для открытого на весь экран фото.
  ImageProvider get full => FileImage(File(path));
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
