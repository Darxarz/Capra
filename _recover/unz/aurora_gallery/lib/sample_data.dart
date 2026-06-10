/// Тестовые данные для каркаса. Позже заменим на чтение реальных
/// фото с устройства (пакет photo_manager) — структура останется похожей.

class PhotoItem {
  final String id;
  final String url; // превью
  final String fullUrl; // полный размер
  final bool isGif;
  final String folder;
  final String dateGroup;

  const PhotoItem({
    required this.id,
    required this.url,
    required this.fullUrl,
    required this.isGif,
    required this.folder,
    required this.dateGroup,
  });
}

class AlbumItem {
  final String name;
  final int count;
  final String coverSeed;
  final String group;
  const AlbumItem(this.name, this.count, this.coverSeed, this.group);
}

String _thumb(String seed) => 'https://picsum.photos/seed/$seed/300/300';
String _full(String seed) => 'https://picsum.photos/seed/$seed/1200/900';

final List<String> _dateGroups = [
  'Сегодня',
  'Вчера',
  '7 июня 2026',
  '6 июня 2026',
  'Июнь 2026 · ранее',
];

final List<String> _folders = [
  '/Art/canine',
  '/Art/feline',
  '/Art/dragon',
  '/Downloads/telegram',
  '/Art/sketches',
];

/// Генерируем 300 тестовых картинок (в реальном приложении их будут сотни тысяч,
/// но рисуются только видимые — за счёт ленивой сетки GridView.builder).
final List<PhotoItem> kPhotos = List.generate(300, (i) {
  final seed = 'a$i';
  return PhotoItem(
    id: seed,
    url: _thumb(seed),
    fullUrl: _full(seed),
    isGif: i % 17 == 0,
    folder: _folders[i % _folders.length],
    dateGroup: _dateGroups[(i ~/ 22) % _dateGroups.length],
  );
});

const List<AlbumItem> kAlbums = [
  AlbumItem('Избранное', 2140, 'fav', 'Закреплённые'),
  AlbumItem('Commissions', 418, 'com', 'Закреплённые'),
  AlbumItem('Референсы', 3960, 'ref', 'Закреплённые'),
  AlbumItem('Обои', 286, 'wall', 'Закреплённые'),
  AlbumItem('/Art/canine', 24180, 'c1', 'Папки на устройстве'),
  AlbumItem('/Art/feline', 18920, 'c2', 'Папки на устройстве'),
  AlbumItem('/Art/dragon', 9740, 'c3', 'Папки на устройстве'),
  AlbumItem('/Downloads/telegram', 31200, 'c4', 'Папки на устройстве'),
  AlbumItem('/Art/sketches', 6610, 'c5', 'Папки на устройстве'),
];

String albumCover(String seed) => 'https://picsum.photos/seed/$seed/400/400';
