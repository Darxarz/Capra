import 'package:flutter/material.dart';

/// Палитра одной темы (то, что в итоге видит весь UI).
///
/// Цвета — те же, что в Goat Explorer (его Theme.kt), значение в значение:
/// галерея должна выглядеть как часть проводника. Старые поля (surface,
/// surface2, accentSoft, accentInk) оставлены, чтобы прежний код продолжал
/// работать; новые (panel, field, active…) — словарь проводника.
@immutable
class AuroraColors {
  final String id; // композитный: "{baseId}+{accentId}"
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface; // = panel проводника
  final Color surface2; // = active проводника
  final Color text;
  final Color muted;
  final Color line;
  final Color accent;
  final Color accentSoft; // фон выбранного (= selected проводника)
  final Color accentInk; // текст/иконка поверх accentSoft

  // ── словарь проводника ──
  final Color field; // рамки полей и кнопок
  final Color rowLine; // тонкие линии между строками
  final Color selected; // фон выбранной строки/плитки
  final Color strong; // то единственное, что должно выделяться из текста
  final Color dim; // недоступное, третьестепенное
  final Color current; // второй акцент (перивинкль): «текущее», избранное
  final Color danger; // удаление, ошибки
  final Color onAccent; // текст поверх залитой акцентом кнопки

  const AuroraColors({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.accentInk,
    required this.field,
    required this.rowLine,
    required this.selected,
    required this.strong,
    required this.dim,
    required this.current,
    required this.danger,
    required this.onAccent,
  });

  Color get panel => surface;
  Color get active => surface2;

  /// Скругление всего интерфейса — как в проводнике.
  static const double radius = 7;

  ThemeData toThemeData() {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: line),
    );
    final plain =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      surface: surface,
      onSurface: text,
      onSurfaceVariant: muted,
      primary: accent,
      onPrimary: onAccent,
      secondary: current,
      onSecondary: onAccent,
      error: danger,
      outline: field,
      outlineVariant: line,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface2,
      surfaceContainerHighest: surface2,
      surfaceTint: Colors.transparent,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      colorScheme: scheme,
      fontFamily: 'Onest',
      visualDensity: VisualDensity.compact,
      splashFactory: NoSplash.splashFactory,
      highlightColor: surface2.withValues(alpha: 0.6),
      hoverColor: surface2.withValues(alpha: 0.5),
      dividerColor: line,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      iconTheme: IconThemeData(color: muted, size: 20),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 52,
        titleSpacing: 4,
        shape: Border(bottom: BorderSide(color: line)),
        titleTextStyle: TextStyle(
            fontFamily: 'Onest',
            color: text,
            fontSize: 15,
            fontWeight: FontWeight.w600),
        iconTheme: IconThemeData(color: muted, size: 20),
      ),
      cardTheme: CardThemeData(
          color: surface, elevation: 0, margin: EdgeInsets.zero, shape: shape),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 0,
        shape: shape,
        titleTextStyle: TextStyle(
            fontFamily: 'Onest',
            color: text,
            fontSize: 16,
            fontWeight: FontWeight.w600),
        contentTextStyle:
            TextStyle(fontFamily: 'Onest', color: muted, fontSize: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(radius)),
          side: BorderSide(color: line),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        elevation: 0,
        shape: shape,
        textStyle: TextStyle(fontFamily: 'Onest', color: text, fontSize: 14),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surface2,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: field),
        ),
        textStyle: TextStyle(fontFamily: 'Onest', color: text, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface2,
        contentTextStyle:
            TextStyle(fontFamily: 'Onest', color: text, fontSize: 13),
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: field),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          elevation: 0,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: plain,
          textStyle: const TextStyle(
              fontFamily: 'Onest', fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: surface2,
          foregroundColor: text,
          elevation: 0,
          minimumSize: const Size(0, 40),
          shape: plain,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          side: BorderSide(color: field),
          shape: plain,
          textStyle: const TextStyle(
              fontFamily: 'Onest', fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: plain,
          textStyle: const TextStyle(
              fontFamily: 'Onest', fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: muted,
          shape: plain,
          minimumSize: const Size(40, 40),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: false,
        hintStyle: TextStyle(color: dim, fontSize: 14),
        labelStyle: TextStyle(color: muted, fontSize: 14),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: field)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: field)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: accent)),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.3),
        selectionHandleColor: accent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: selected,
        side: BorderSide(color: field),
        shape: plain,
        labelStyle: TextStyle(fontFamily: 'Onest', color: text, fontSize: 13),
        elevation: 0,
        pressElevation: 0,
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        iconColor: muted,
        textColor: text,
        selectedColor: strong,
        selectedTileColor: selected,
        shape: plain,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? onAccent : muted),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : surface2),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : field),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : Colors.transparent),
        checkColor: WidgetStatePropertyAll(onAccent),
        side: BorderSide(color: field, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accent : field),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: line,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.12),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: current,
        linearTrackColor: line,
        circularTrackColor: line,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(plain),
          side: WidgetStatePropertyAll(BorderSide(color: field)),
          backgroundColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? surface2 : Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? text : muted),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(field),
        radius: const Radius.circular(3),
        thickness: const WidgetStatePropertyAll(5),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: plain,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg,
        elevation: 0,
        indicatorColor: surface2,
        indicatorShape: plain,
      ),
    );
  }
}

// ─────────────────────────── базы (палитры проводника) ───────────────────────────

/// Одна палитра Goat Explorer. Акцент — часть палитры (в проводнике он не
/// выбирается отдельно: бирюза на тёмных, тёмная бирюза на «Бумаге»).
@immutable
class AuroraBase {
  final String id;
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color line;
  final Color field;
  final Color rowLine;
  final Color selected;
  final Color strong;
  final Color dim;
  final Color accent;
  final Color current;
  final Color danger;
  final Color onAccent;

  const AuroraBase({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.line,
    required this.field,
    required this.rowLine,
    required this.selected,
    required this.strong,
    required this.dim,
    required this.accent,
    required this.current,
    required this.danger,
    required this.onAccent,
  });
}

/// Светлая: не белая. Приглушённая бумага с чуть зеленоватым оттенком и
/// тёмно-сланцевым текстом — читается лучше всего и не слепит.
const List<AuroraBase> kLightBases = [
  AuroraBase(
    id: 'paper',
    name: 'Бумага',
    brightness: Brightness.light,
    bg: Color(0xFFEAEDE6),
    surface: Color(0xFFF2F4EE),
    surface2: Color(0xFFDCE3DA),
    text: Color(0xFF1F2B2A),
    muted: Color(0xFF566562),
    line: Color(0xFFD3D9CF),
    field: Color(0xFFC2CAC0),
    rowLine: Color(0xFFDDE2D8),
    selected: Color(0xFFD2E4DB),
    strong: Color(0xFF111A19),
    dim: Color(0xFF8A9692),
    accent: Color(0xFF1B6F63),
    current: Color(0xFF4558B8),
    danger: Color(0xFFB04438),
    onAccent: Color(0xFFF2F4EE),
  ),
];

/// Тёмные: глубокий тёмно-синий «Ночь» и настоящий чёрный для OLED.
const List<AuroraBase> kDarkBases = [
  AuroraBase(
    id: 'night',
    name: 'Ночь',
    brightness: Brightness.dark,
    bg: Color(0xFF0B1622),
    surface: Color(0xFF0E1B29),
    surface2: Color(0xFF16283A),
    text: Color(0xFFE6ECF4),
    muted: Color(0xFF8FA3B8),
    line: Color(0xFF1A2B3D),
    field: Color(0xFF1F3247),
    rowLine: Color(0xFF132131),
    selected: Color(0xFF12283A),
    strong: Color(0xFFFFFFFF),
    dim: Color(0xFF56697E),
    accent: Color(0xFF5FD6C8),
    current: Color(0xFF8FA6FF),
    danger: Color(0xFFFF9A8F),
    onAccent: Color(0xFF0B1622),
  ),
  AuroraBase(
    id: 'oled',
    name: 'OLED',
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    surface: Color(0xFF050709),
    surface2: Color(0xFF11181F),
    text: Color(0xFFD9DEE5),
    muted: Color(0xFF8592A0),
    line: Color(0xFF1A2129),
    field: Color(0xFF232C36),
    rowLine: Color(0xFF10151B),
    selected: Color(0xFF0B2024),
    strong: Color(0xFFF2F4F7),
    dim: Color(0xFF525E6A),
    accent: Color(0xFF5FD6C8),
    current: Color(0xFF8FA6FF),
    danger: Color(0xFFFF9A8F),
    onAccent: Color(0xFF000000),
  ),
];

// ─────────────────────────── акцент ───────────────────────────

/// Цвет акцента. Оставлен один — «как в проводнике» (берётся из палитры):
/// свой набор акцентов делал галерею непохожей на проводник.
@immutable
class AuroraAccent {
  final String id;
  final String name;
  final Color base;
  const AuroraAccent({required this.id, required this.name, required this.base});
}

const List<AuroraAccent> kAccents = [
  AuroraAccent(id: 'explorer', name: 'Как в проводнике', base: Color(0xFF5FD6C8)),
];

// ─────────────────────────── сборка палитры ───────────────────────────

/// Палитра по id; незнакомый id (от прежних тем галереи) даёт первую в списке.
AuroraBase resolveBase(String id, Brightness brightness) {
  final list = brightness == Brightness.light ? kLightBases : kDarkBases;
  return list.firstWhere((b) => b.id == id, orElse: () => list.first);
}

AuroraAccent resolveAccent(String id) =>
    kAccents.firstWhere((a) => a.id == id, orElse: () => kAccents.first);

AuroraColors composeColors(AuroraBase base, AuroraAccent accent) {
  return AuroraColors(
    id: base.id,
    name: base.name,
    brightness: base.brightness,
    bg: base.bg,
    surface: base.surface,
    surface2: base.surface2,
    text: base.text,
    muted: base.muted,
    line: base.line,
    accent: base.accent,
    accentSoft: base.selected,
    accentInk: base.accent,
    field: base.field,
    rowLine: base.rowLine,
    selected: base.selected,
    strong: base.strong,
    dim: base.dim,
    current: base.current,
    danger: base.danger,
    onAccent: base.onAccent,
  );
}

// ─────────────────────────── InheritedWidget ───────────────────────────

/// Прокидывает активную палитру вниз по дереву. Сменой темы занимается
/// SettingsService — здесь только доставка цветов.
class AuroraTheme extends InheritedWidget {
  final AuroraColors colors;

  const AuroraTheme({
    super.key,
    required this.colors,
    required super.child,
  });

  static AuroraTheme of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AuroraTheme>();
    assert(t != null, 'AuroraTheme не найден в дереве виджетов');
    return t!;
  }

  @override
  bool updateShouldNotify(AuroraTheme oldWidget) =>
      oldWidget.colors.id != colors.id;
}
