import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Избранное: множество путей к файлам. Хранится в shared_preferences,
/// меняется вживую через [notifier] — на него подписан и интерфейс.
class Favorites {
  Favorites._();
  static final Favorites instance = Favorites._();

  static const _key = 'aurora_favorites';

  final ValueNotifier<Set<String>> notifier = ValueNotifier<Set<String>>({});

  Set<String> get paths => notifier.value;
  bool contains(String path) => notifier.value.contains(path);

  /// Загрузить сохранённое избранное (вызывать при старте).
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    notifier.value = (p.getStringList(_key) ?? const <String>[]).toSet();
  }

  /// Добавить/убрать из избранного и сохранить.
  Future<void> toggle(String path) async {
    final next = Set<String>.from(notifier.value);
    if (!next.add(path)) next.remove(path); // add вернул false → уже был → убрать
    notifier.value = next;
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, next.toList());
  }
}
