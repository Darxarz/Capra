import 'package:flutter/foundation.dart';
import 'model.dart';
import 'embed_service.dart';
import 'embed_store.dart';
import 'i18n.dart';

/// Пакетное вычисление эмбеддингов библиотеки: проходит все фото, пропуская
/// уже посчитанные. Декод — в изоляте, инференс — в изоляте движка. UI не
/// подвисает. Останавливаемое; прогресс через [ChangeNotifier].
class BatchEmbedder extends ChangeNotifier {
  BatchEmbedder._();
  static final BatchEmbedder instance = BatchEmbedder._();

  bool running = false;
  bool downloading = false;
  double downloadProgress = 0;
  bool _stop = false;
  int total = 0;
  int done = 0;
  int embedded = 0;
  String? error;

  double get progress => total == 0 ? 0 : done / total;

  void stop() => _stop = true;

  Future<void> start(List<PhotoItem> photos) async {
    if (running) return;
    error = null;
    running = true;
    _stop = false;
    done = 0;
    embedded = 0;
    total = 0;
    notifyListeners();

    await EmbedStore.instance.init();

    if (!await EmbedService.instance.isDownloaded()) {
      downloading = true;
      downloadProgress = 0;
      notifyListeners();
      try {
        var last = -1;
        await EmbedService.instance.download(onProgress: (pr) {
          downloadProgress = pr;
          final pct = (pr * 100).round();
          if (pct != last) {
            last = pct;
            notifyListeners();
          }
        });
      } catch (e) {
        downloading = false;
        running = false;
        error =
            '${tr('Не удалось скачать модель', 'Could not download model', 'No se pudo descargar el modelo')}: $e';
        notifyListeners();
        return;
      }
      downloading = false;
      notifyListeners();
    }

    try {
      await EmbedService.instance.load();
    } catch (e) {
      running = false;
      error =
          '${tr('Не удалось загрузить модель', 'Could not load model', 'No se pudo cargar el modelo')}: $e';
      notifyListeners();
      return;
    }

    final todo = photos
        .where((ph) =>
            !ph.isVideo && !ph.isRemote && !EmbedStore.instance.has(ph.path))
        .toList(growable: false);
    total = todo.length;
    notifyListeners();

    for (final ph in todo) {
      if (_stop) break;
      try {
        final rf = await ph.resolveFile();
        if (rf != null) {
          final bytes = await rf.readAsBytes();
          final vec = await EmbedService.instance.embedBytes(bytes);
          if (vec != null) {
            EmbedStore.instance.put(ph.path, vec);
            embedded++;
          }
        }
      } catch (_) {
        // битые/недоступные файлы пропускаем
      }
      done++;
      if (done % 3 == 0 || done == total) notifyListeners();
    }

    running = false;
    notifyListeners();
  }
}
