import 'package:flutter/foundation.dart';
import 'model.dart';
import 'tag_service.dart';
import 'tagger_service.dart';

/// Пакетное тегирование библиотеки: проходит все фото, пропуская уже
/// отмеченные. Инференс и декод — в фоновых изолятах (UI не подвисает).
/// Останавливаемое; прогресс через [ChangeNotifier].
class BatchTagger extends ChangeNotifier {
  BatchTagger._();
  static final BatchTagger instance = BatchTagger._();

  bool running = false;
  bool _stop = false;
  int total = 0;
  int done = 0;
  int tagged = 0;
  String? error;

  double get progress => total == 0 ? 0 : done / total;

  void stop() => _stop = true;

  Future<void> start(List<PhotoItem> photos) async {
    if (running) return;
    error = null;
    if (!await Tagger.instance.isDownloaded()) {
      error = 'Сначала скачай модель: отметь одно фото кнопкой «Тегировать».';
      notifyListeners();
      return;
    }
    running = true;
    _stop = false;
    done = 0;
    tagged = 0;
    total = 0;
    notifyListeners();

    try {
      await Tagger.instance.load();
    } catch (e) {
      running = false;
      error = 'Не удалось загрузить модель: $e';
      notifyListeners();
      return;
    }

    final already = TagService.instance.taggedPaths();
    final todo =
        photos.where((ph) => !already.contains(ph.path)).toList(growable: false);
    total = todo.length;
    notifyListeners();

    for (final ph in todo) {
      if (_stop) break;
      try {
        final n = await Tagger.instance.tagAndStoreAsync(ph.path);
        if (n > 0) tagged++;
      } catch (_) {
        // битые/недоступные файлы просто пропускаем
      }
      done++;
      if (done % 3 == 0 || done == total) notifyListeners();
    }

    running = false;
    notifyListeners();
  }
}
