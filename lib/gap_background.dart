import 'package:flutter/material.dart';
import 'settings_service.dart';

/// Подложка под сеткой: зазоры между плитками прозрачны, поэтому сквозь них
/// виден этот фон. Так зазоры можно сделать цветными, «металлическими»,
/// голографическими или полароидными — с лёгким переливанием.
class GapBackground extends StatefulWidget {
  final Widget child;
  const GapBackground({super.key, required this.child});

  @override
  State<GapBackground> createState() => _GapBackgroundState();
}

class _GapBackgroundState extends State<GapBackground>
    with SingleTickerProviderStateMixin {
  // тикер запускаем ТОЛЬКО когда реально нужно мерцание — иначе он гонит
  // весь интерфейс на 60 fps впустую (заметно на слабом железе и по батарее)
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  void _syncTicker(bool wantAnim) {
    if (wantAnim && !_ctl.isAnimating) {
      _ctl.repeat();
    } else if (!wantAnim && _ctl.isAnimating) {
      _ctl.stop();
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  // палитры «металла» и голографии
  static const _silver = [
    Color(0xFF8E8E8E), Color(0xFFE9E9E9), Color(0xFFB4B4B4),
    Color(0xFFFFFFFF), Color(0xFF9C9C9C), Color(0xFFDADADA),
  ];
  static const _gold = [
    Color(0xFF7C5A1E), Color(0xFFE8C66A), Color(0xFFB8902E),
    Color(0xFFFFF0C0), Color(0xFF8A6A24), Color(0xFFD8B458),
  ];
  static const _holo = [
    Color(0xFFFF5D8F), Color(0xFFFFB35D), Color(0xFFFFF35D),
    Color(0xFF5DFF9E), Color(0xFF5DD8FF), Color(0xFF8A5DFF),
    Color(0xFFFF5DEC), Color(0xFFFF5D8F),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SettingsService.instance,
      builder: (context, _) {
        final s = SettingsService.instance;
        final style = s.gapStyle;
        final shimmer = style == GapStyle.silver ||
            style == GapStyle.gold ||
            style == GapStyle.holographic;
        // тикер крутим только при активном мерцающем стиле и без «тихого» режима
        _syncTicker(shimmer && !s.motionReduced);
        if (style == GapStyle.none) return widget.child;

        Widget bg;
        switch (style) {
          case GapStyle.color:
            bg = ColoredBox(color: Color(s.gapColorValue));
          case GapStyle.polaroid:
            bg = const ColoredBox(color: Color(0xFFFAFAF7));
          case GapStyle.silver:
          case GapStyle.gold:
          case GapStyle.holographic:
            final colors = style == GapStyle.silver
                ? _silver
                : style == GapStyle.gold
                    ? _gold
                    : _holo;
            bg = s.motionReduced
                ? _gradientBox(colors, 0)
                : AnimatedBuilder(
                    animation: _ctl,
                    builder: (_, __) => _gradientBox(colors, _ctl.value),
                  );
          case GapStyle.none:
            return widget.child; // недостижимо
        }

        return Stack(fit: StackFit.expand, children: [
          Positioned.fill(child: RepaintBoundary(child: bg)),
          widget.child,
        ]);
      },
    );
  }

  Widget _gradientBox(List<Color> colors, double t) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          tileMode: TileMode.mirror,
          transform: _SlideGradient(t),
        ),
      ),
    );
  }
}

/// Сдвигает градиент по горизонтали на долю [frac] ширины — даёт «переливание».
class _SlideGradient extends GradientTransform {
  final double frac;
  const _SlideGradient(this.frac);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * frac, 0, 0);
}
