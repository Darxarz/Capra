import 'tag_service.dart';

/// Разобранная строка поиска. Синтаксис тот же, что в Goat Archive, чтобы
/// один и тот же запрос значил в обоих приложениях одно и то же:
///
///   слово         — есть в имени файла, в пути папки или в тегах;
///   -тег          — исключить файлы с таким тегом;
///   artist:имя    — нужен автор (то же самое — `автор:имя`).
///
/// Части разделяются пробелами и действуют вместе (И).
class SearchQuery {
  final List<String> terms; // в нижнем регистре
  final List<String> excluded;
  final List<String> artists;
  const SearchQuery({
    this.terms = const [],
    this.excluded = const [],
    this.artists = const [],
  });

  bool get isEmpty => terms.isEmpty && excluded.isEmpty && artists.isEmpty;

  static SearchQuery parse(String raw) {
    final terms = <String>[], excluded = <String>[], artists = <String>[];
    for (final token in raw.toLowerCase().split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      if (token.startsWith('-')) {
        final tag = token.substring(1);
        if (tag.isNotEmpty) excluded.add(tag);
      } else if (token.startsWith('artist:') || token.startsWith('автор:')) {
        final name = token.substring(token.indexOf(':') + 1);
        if (name.isNotEmpty) artists.add(name);
      } else {
        terms.add(token);
      }
    }
    return SearchQuery(terms: terms, excluded: excluded, artists: artists);
  }
}

/// Запрос, уже сверенный с базой тегов: для каждой части — готовое множество
/// путей. Проверка одного фото после этого — несколько поисков в множествах.
class SearchMatcher {
  final SearchQuery query;
  final List<Set<String>> _termTagPaths; // по одному на слово
  final Set<String> _excludedPaths;
  final List<Set<String>> _artistPaths;

  SearchMatcher._(this.query, this._termTagPaths, this._excludedPaths,
      this._artistPaths);

  /// Запрос без условий — подходит всё.
  static final SearchMatcher none =
      SearchMatcher._(const SearchQuery(), const [], const {}, const []);

  bool get isEmpty => query.isEmpty;

  /// Сверить запрос с базой. Слова ищутся в словаре тегов (подстрокой), пути
  /// берутся по индексу тегов — таблица с миллионами строк не перебирается.
  factory SearchMatcher.resolve(String raw, {TagService? tags}) {
    final q = SearchQuery.parse(raw);
    if (q.isEmpty) return none;
    final svc = tags ?? TagService.instance;
    return SearchMatcher._(
      q,
      [
        for (final t in q.terms)
          // одна буква совпала бы почти с каждым тегом — по тегам её не ищем
          t.length < 2 ? const <String>{} : svc.pathsMatchingTag(t)
      ],
      {for (final t in q.excluded) ...svc.pathsWithTag(t)},
      [for (final a in q.artists) svc.pathsWithArtist(a)],
    );
  }

  /// Подходит ли файл. [nameLower] — имя файла, [folderLower] — путь папки
  /// (оба в нижнем регистре).
  bool matches(String path, String nameLower, String folderLower) {
    if (_excludedPaths.contains(path)) return false;
    for (final a in _artistPaths) {
      if (!a.contains(path)) return false;
    }
    for (var i = 0; i < query.terms.length; i++) {
      final t = query.terms[i];
      if (nameLower.contains(t) ||
          folderLower.contains(t) ||
          _termTagPaths[i].contains(path)) {
        continue;
      }
      return false;
    }
    return true;
  }
}
