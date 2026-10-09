import 'package:flutter/material.dart';
import 'package:path_drawing/path_drawing.dart';
import 'theme.dart';

/// Кирпичики интерфейса Goat Explorer, перенесённые в галерею один в один:
/// те же линейные значки, те же кнопки 44×40 со скруглением 7, те же тонкие
/// линии вместо теней. Всё новое в галерее собирается из них, чтобы её нельзя
/// было отличить от проводника.

/// Скругление — как в проводнике.
final BorderRadius gxCorner = BorderRadius.circular(AuroraColors.radius);

/// Линейный значок на сетке 24×24, заданный SVG-путём (как Glyph в проводнике).
/// [solid] — фигура получает слабую заливку своим же цветом (двухтоновый вид).
class GxGlyph {
  final String d;
  final bool solid;
  const GxGlyph(this.d, [this.solid = false]);

  // ── общие с проводником ──
  static const back = GxGlyph('M15 5l-7 7 7 7');
  static const forward = GxGlyph('M9 5l7 7-7 7');
  static const up = GxGlyph('M12 19V5M6 11l6-6 6 6');
  static const down = GxGlyph('M6 9l6 6 6-6');
  static const search = GxGlyph(
      'M17.5 11a6.5 6.5 0 1 1-13 0a6.5 6.5 0 0 1 13 0M16 16l4.5 4.5');
  static const list = GxGlyph('M4 7h16M4 12h16M4 17h16');
  static const grid = GxGlyph(
      'M4 4h6.5v6.5H4zM13.5 4H20v6.5h-6.5zM4 13.5h6.5V20H4zM13.5 13.5H20V20h-6.5z');
  static const folder = GxGlyph(
      'M3 8a2.5 2.5 0 0 1 2.5-2.5H9l2.2 2.5h7.3A2.5 2.5 0 0 1 21 10.5V17a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17zM3.5 11.5h17',
      true);
  static const library = GxGlyph(
      'M7.5 4h9A1.5 1.5 0 0 1 18 5.5V20l-6-4-6 4V5.5A1.5 1.5 0 0 1 7.5 4z',
      true);
  static const star = GxGlyph(
      'M12 4l2.4 5 5.4.7-4 3.8 1 5.4-4.8-2.6-4.8 2.6 1-5.4-4-3.8 5.4-.7z',
      true);
  static const settings = GxGlyph(
      'M4 7h10M18 7h2M4 17h2M10 17h10M18 7a2 2 0 1 1-4 0a2 2 0 0 1 4 0M10 17a2 2 0 1 1-4 0a2 2 0 0 1 4 0');
  static const plus = GxGlyph('M12 5v14M5 12h14');
  static const info = GxGlyph(
      'M20.5 12a8.5 8.5 0 1 1-17 0a8.5 8.5 0 0 1 17 0M12 11v5.5M12 7.6v.2');
  static const sidebar = GxGlyph(
      'M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5zM9.5 4.5v15');
  static const swap = GxGlyph(
      'M4 8.5h15M15.5 5L19 8.5 15.5 12M20 15.5H5M8.5 12L5 15.5 8.5 19');
  static const gallery = GxGlyph(
      'M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5zM4 16l4.5-4.5 4 4 2.5-2.5 5 5M16.5 9.5a1 1 0 1 1-2 0a1 1 0 0 1 2 0');
  static const monitor = GxGlyph(
      'M5 4h14a2.5 2.5 0 0 1 2.5 2.5v8A2.5 2.5 0 0 1 19 17H5a2.5 2.5 0 0 1-2.5-2.5v-8A2.5 2.5 0 0 1 5 4zM8.5 20.5h7M12 17v3.5',
      true);
  static const refresh =
      GxGlyph('M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4h-4');
  static const close = GxGlyph('M6 6l12 12M18 6L6 18');
  static const check = GxGlyph('M5 12.5l4.5 4.5L19 7.5');
  static const bolt = GxGlyph('M13 3.5L5.5 13.5H11l-1 7 7.5-10H12z', true);
  static const copy = GxGlyph(
      'M10 8.5h8.5a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H10a1.5 1.5 0 0 1-1.5-1.5V10A1.5 1.5 0 0 1 10 8.5zM15.5 5.5V5A1.5 1.5 0 0 0 14 3.5H5.5A1.5 1.5 0 0 0 4 5v8.5A1.5 1.5 0 0 0 5.5 15H6');
  static const pencil = GxGlyph('M4 20h4L19 9l-4-4L4 16zM13 7l4 4', true);
  static const bin = GxGlyph(
      'M4.5 7h15M9.5 7V4.5h5V7M6.5 7l.8 12a1.5 1.5 0 0 0 1.5 1.5h6.4a1.5 1.5 0 0 0 1.5-1.5l.8-12M10 11v5.5M14 11v5.5');
  static const share = GxGlyph(
      'M17.5 8.5a2.5 2.5 0 1 0 0-5a2.5 2.5 0 0 0 0 5zM6.5 14.5a2.5 2.5 0 1 0 0-5a2.5 2.5 0 0 0 0 5zM17.5 20.5a2.5 2.5 0 1 0 0-5a2.5 2.5 0 0 0 0 5zM8.7 10.9l6.6-3.8M8.7 13.1l6.6 3.8');
  static const selectAll =
      GxGlyph('M4.5 4.5h15v15h-15zM8 12.2l2.8 2.8L16 9.5');
  static const moveTo = GxGlyph(
      'M3 8a2.5 2.5 0 0 1 2.5-2.5H9l2.2 2.5h7.3A2.5 2.5 0 0 1 21 10.5V17a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17zM9 13.5h6M12.5 11l2.5 2.5-2.5 2.5');

  // ── свои для галереи, в том же начертании ──
  static const calendar = GxGlyph(
      'M5.5 5.5h13A1.5 1.5 0 0 1 20 7v11.5a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18.5V7a1.5 1.5 0 0 1 1.5-1.5zM4 10h16M8 3.5v4M16 3.5v4');
  static const tag = GxGlyph(
      'M3.5 12.5V5A1.5 1.5 0 0 1 5 3.5h7.5l8 8a1.5 1.5 0 0 1 0 2.1l-6.4 6.4a1.5 1.5 0 0 1-2.1 0zM8 8h.2',
      true);
  static const mosaic =
      GxGlyph('M4 4h7v9H4zM13 4h7v5h-7zM13 11h7v9h-7zM4 15h7v5H4z');
  static const sort = GxGlyph('M5 7h14M7.5 12h9M10 17h4');
  static const shield = GxGlyph(
      'M12 3.5l7 2.5v5.5c0 4.5-3 7.7-7 9-4-1.300-7-4.500-7-9V6z', true);
  static const tree = GxGlyph(
      'M6 4.5v10.5a2 2 0 0 0 2 2h4M6 9h6M12 7h7v4h-7zM12 15h7v4h-7z');
  static const duplicates = GxGlyph(
      'M8 8h11.5v11.5H8zM4.5 15.5V4.5h11M11 13.500h5.500M13.750 10.750v5.500');
  static const network = GxGlyph(
      'M4.5 9.5a11 11 0 0 1 15 0M7.5 13a7 7 0 0 1 9 0M10.5 16.5a2.5 2.5 0 0 1 3 0M12 19.5h.2');
  static const heart = GxGlyph(
      'M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.300 4.300 4.300 0 0 1 19.500 10c0 5.400-7.500 10-7.500 10z',
      true);
  static const more = GxGlyph('M6 12h.2M12 12h.2M18 12h.2');
  static const play = GxGlyph('M8 5.5v13l10.5-6.5z', true);
  static const eyeOff = GxGlyph(
      'M4 4l16 16M9.5 5.8A9 9 0 0 1 12 5.5c5 0 8.5 6.5 8.5 6.5a15 15 0 0 1-2.6 3.3M14.5 14.6A3.5 3.5 0 0 1 9.4 9.5M6.3 7.7A15 15 0 0 0 3.5 12s3.5 6.5 8.5 6.5a8.5 8.5 0 0 0 3-.55');
}

final Map<String, Path> _paths = {};

class _GlyphPainter extends CustomPainter {
  final GxGlyph glyph;
  final Color color;
  _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = _paths[glyph.d] ??= parseSvgPathData(glyph.d);
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    if (glyph.solid) {
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.2));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph.d != glyph.d || old.color != color;
}

class GxIcon extends StatelessWidget {
  final GxGlyph glyph;
  final Color? color;
  final double size;
  const GxIcon(this.glyph, {super.key, this.color, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return CustomPaint(
      size: Size.square(size),
      painter: _GlyphPainter(glyph, color ?? c.text),
    );
  }
}

/// Кнопка-значок 44×40 — основная кнопка проводника (рейка, панели, полосы).
class GxIconBtn extends StatelessWidget {
  final GxGlyph glyph;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color? tint;
  final double iconSize;
  const GxIconBtn(
    this.glyph,
    this.label, {
    super.key,
    required this.onTap,
    this.active = false,
    this.tint,
    this.iconSize = 19,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final enabled = onTap != null;
    final color = !enabled ? c.dim : (tint ?? (active ? c.text : c.muted));
    return Tooltip(
      message: label,
      child: Material(
        color: active ? c.active : Colors.transparent,
        borderRadius: gxCorner,
        child: InkWell(
          borderRadius: gxCorner,
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 40,
            child: Center(child: GxIcon(glyph, color: color, size: iconSize)),
          ),
        ),
      ),
    );
  }
}

class GxHLine extends StatelessWidget {
  final Color? color;
  const GxHLine({super.key, this.color});
  @override
  Widget build(BuildContext context) => Container(
      height: 1, color: color ?? AuroraTheme.of(context).colors.line);
}

class GxVLine extends StatelessWidget {
  final Color? color;
  const GxVLine({super.key, this.color});
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: color ?? AuroraTheme.of(context).colors.line);
}

/// Текстовая кнопка в рамке (как TextBtn проводника); [primary] — залитая акцентом.
class GxTextBtn extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final bool primary;
  final double height;
  const GxTextBtn(this.text,
      {super.key, required this.onTap, this.primary = false, this.height = 40});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Material(
      color: primary ? c.accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: gxCorner,
        side: primary ? BorderSide.none : BorderSide(color: c.field),
      ),
      child: InkWell(
        borderRadius: gxCorner,
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(text,
              maxLines: 1,
              style: TextStyle(
                  color: primary ? c.onAccent : c.text,
                  fontSize: 14,
                  fontWeight: primary ? FontWeight.w600 : FontWeight.w500)),
        ),
      ),
    );
  }
}

/// Переключатель из нескольких значков в общей рамке (как «списком / плиткой»).
class GxSegments<T> extends StatelessWidget {
  final T value;
  final List<(T, GxGlyph, String)> items;
  final ValueChanged<T> onChanged;
  const GxSegments(
      {super.key,
      required this.value,
      required this.items,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      height: 40,
      decoration: BoxDecoration(
          borderRadius: gxCorner, border: Border.all(color: c.field)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (v, glyph, label) in items)
          Tooltip(
            message: label,
            child: Material(
              color: v == value ? c.active : Colors.transparent,
              child: InkWell(
                onTap: () => onChanged(v),
                child: SizedBox(
                  width: 44,
                  height: 40,
                  child: Center(
                      child: GxIcon(glyph,
                          color: v == value ? c.text : c.muted, size: 19)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Текстовые вкладки в одну строку: активная — ярче и с чертой акцента снизу.
class GxTabs<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final double height;
  const GxTabs(
      {super.key,
      required this.value,
      required this.items,
      required this.onChanged,
      this.height = 34});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (v, label) in items)
        InkWell(
          onTap: () => onChanged(v),
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: v == value ? c.accent : Colors.transparent,
                      width: 2)),
            ),
            child: Text(label,
                style: TextStyle(
                    color: v == value ? c.strong : c.muted,
                    fontSize: 13,
                    fontWeight:
                        v == value ? FontWeight.w600 : FontWeight.w400)),
          ),
        ),
    ]);
  }
}
