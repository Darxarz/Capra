import 'dart:math';
import 'package:flutter/foundation.dart';
import 'model.dart';

/// Состояние массового выделения фото в галерее. Singleton — выделение
/// одно на всё приложение (галерея показывается по одной за раз).
class Selection extends ChangeNotifier {
  Selection._();
  static final Selection instance = Selection._();

  bool active = false;
  final Set<String> _sel = {};

  Set<String> get paths => _sel;
  int get count => _sel.length;
  bool contains(String path) => _sel.contains(path);

  /// Войти в режим выделения и выделить один элемент.
  void enter(String path) {
    active = true;
    _sel.add(path);
    notifyListeners();
  }

  /// Переключить элемент (вне drag). Если выделение опустело — выйти.
  void toggle(String path) {
    if (!_sel.add(path)) _sel.remove(path);
    active = _sel.isNotEmpty;
    notifyListeners();
  }

  void addAll(Iterable<String> paths) {
    _sel.addAll(paths);
    if (_sel.isNotEmpty) active = true;
    notifyListeners();
  }

  void selectAll(List<PhotoItem> photos) {
    _sel
      ..clear()
      ..addAll(photos.map((p) => p.path));
    active = _sel.isNotEmpty;
    notifyListeners();
  }

  /// Выйти из режима выделения и снять всё.
  void clear() {
    _sel.clear();
    active = false;
    _dragBase = null;
    _dragStart = null;
    notifyListeners();
  }

  // ───────────── «паровозик»: покраска диапазона перетаскиванием ─────────────
  List<String>? _dragBase; // выделение на момент начала drag
  int? _dragStart; // индекс плитки, с которой начали

  bool get dragging => _dragStart != null;

  /// Начать покраску с плитки [index]. Базовое выделение запоминается, чтобы
  /// уже выделенное не пропадало.
  void beginDrag(List<PhotoItem> photos, int index) {
    active = true;
    _dragBase = _sel.toList();
    _dragStart = index;
    _applyDrag(photos, index);
  }

  /// Обновить покраску до плитки [index] — выделяется весь диапазон от старта.
  void updateDrag(List<PhotoItem> photos, int index) {
    if (_dragStart == null) return;
    _applyDrag(photos, index);
  }

  void endDrag() {
    _dragBase = null;
    _dragStart = null;
    active = _sel.isNotEmpty;
    notifyListeners();
  }

  void _applyDrag(List<PhotoItem> photos, int cur) {
    final start = _dragStart!;
    final a = min(start, cur).clamp(0, photos.length - 1);
    final b = max(start, cur).clamp(0, photos.length - 1);
    _sel
      ..clear()
      ..addAll(_dragBase ?? const []);
    for (var i = a; i <= b; i++) {
      _sel.add(photos[i].path);
    }
    notifyListeners();
  }
}
