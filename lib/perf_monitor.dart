import 'package:flutter/scheduler.dart';
import 'settings_service.dart';
import 'error_log.dart';

/// Авто-определение слабого устройства по реальной плавности. Слушает тайминги
/// кадров: если при активной отрисовке значительная доля кадров не укладывается
/// в бюджет (~30 fps), считаем устройство слабым и включаем режим экономии.
/// Это честнее, чем гадать по числу ядер: меряем то, что есть на самом деле.
class PerfMonitor {
  PerfMonitor._();
  static final PerfMonitor instance = PerfMonitor._();

  // кадр считаем «тяжёлым», если построение+растеризация дольше этого
  static const _slowFrameMs = 28.0; // ~ ниже 36 fps
  static const _minSample = 240; // решаем не раньше, чем набрали столько кадров
  static const _maxSample = 1800; // после стольких «хороших» кадров — успокоились
  static const _slowRatioWeak = 0.35; // доля тяжёлых, при которой устройство слабое

  int _slow = 0;
  int _total = 0;
  bool _done = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_done) return;
    final s = SettingsService.instance;
    // меряем только в режиме «авто» и пока решение не принято
    if (s.perfMode != PerfMode.auto || s.autoWeakDetected) {
      _done = true;
      return;
    }
    for (final t in timings) {
      _total++;
      final ms =
          (t.buildDuration + t.rasterDuration).inMicroseconds / 1000.0;
      if (ms > _slowFrameMs) _slow++;
    }
    if (_total >= _minSample) {
      final ratio = _slow / _total;
      if (ratio > _slowRatioWeak) {
        _done = true;
        ErrorLog.record(
            'авто-детект: слабое устройство (тяжёлых кадров ${(ratio * 100).round()}%)');
        s.markAutoWeak();
      } else if (_total >= _maxSample) {
        // долго рендерили плавно — устройство нормальное, прекращаем мерить
        _done = true;
      }
    }
  }
}
