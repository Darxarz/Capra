import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'theme.dart';
import 'settings_service.dart';
import 'tag_service.dart';
import 'update_service.dart';

/// Полноэкранный раздел настроек: внешний вид, сетка, теги, о приложении.
class SettingsPage extends StatefulWidget {
  /// Вызывается после успешного импорта тегов — чтобы хозяин экрана
  /// перезагрузил панель тегов.
  final VoidCallback? onTagsImported;

  /// Запрос на перепривязку тегов — выполняется хозяином (у него есть
  /// актуальный список фото для сопоставления). Должен вернуть кол-во
  /// перепривязанных файлов, чтобы показать пользователю результат.
  final int Function()? onRelinkRequested;

  const SettingsPage({super.key, this.onTagsImported, this.onRelinkRequested});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return AnimatedBuilder(
      animation: SettingsService.instance,
      builder: (ctx, _) => Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Column(children: [
            _Header(c: c, onBack: () => Navigator.of(context).pop()),
            Expanded(child: _Sections(parent: this)),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── шапка ─────────────────────────
class _Header extends StatelessWidget {
  final AuroraColors c;
  final VoidCallback onBack;
  const _Header({required this.c, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 18, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(children: [
        IconButton(
          onPressed: onBack,
          icon: Icon(Icons.arrow_back, color: c.text),
          tooltip: 'Назад',
        ),
        const SizedBox(width: 4),
        Text('Настройки',
            style: TextStyle(
                color: c.text, fontSize: 18, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

// ───────────────────────── секции ─────────────────────────
class _Sections extends StatelessWidget {
  final _SettingsPageState parent;
  const _Sections({required this.parent});

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    final c = AuroraTheme.of(context).colors;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      children: [
        const _SectionTitle('Внешний вид'),
        _Card(c: c, child: Column(children: [
          _RowLabel('Режим', c: c),
          const SizedBox(height: 8),
          const _ModePicker(),
          const SizedBox(height: 18),
          if (s.themeMode != ThemeModeChoice.dark) ...[
            _RowLabel('Светлая палитра', c: c),
            const SizedBox(height: 8),
            _BasePicker(bases: kLightBases, currentId: s.lightBaseId,
                onPick: s.setLightBase),
            const SizedBox(height: 18),
          ],
          if (s.themeMode != ThemeModeChoice.light) ...[
            _RowLabel('Тёмная палитра', c: c),
            const SizedBox(height: 8),
            _BasePicker(bases: kDarkBases, currentId: s.darkBaseId,
                onPick: s.setDarkBase),
            const SizedBox(height: 18),
          ],
          _RowLabel('Акцент', c: c),
          const SizedBox(height: 8),
          _AccentPicker(currentId: s.accentId, onPick: s.setAccent),
        ])),
        const SizedBox(height: 22),

        const _SectionTitle('Сетка'),
        _Card(c: c, child: Column(children: [
          _SliderRow(
            label: 'Размер плиток по умолчанию',
            value: s.cellSize,
            min: 70, max: 240,
            valueLabel: '${s.cellSize.round()} px',
            onChanged: s.setCellSize,
            c: c,
          ),
          const SizedBox(height: 16),
          _SliderRow(
            label: 'Скругление углов',
            value: s.gridRadius,
            min: 0, max: 18,
            valueLabel: s.gridRadius < 0.5
                ? 'острые'
                : '${s.gridRadius.round()} px',
            onChanged: s.setGridRadius,
            c: c,
          ),
          const SizedBox(height: 16),
          _SliderRow(
            label: 'Зазор между плитками',
            value: s.tileSpacing,
            min: 0, max: 10,
            valueLabel: s.tileSpacing < 0.5
                ? 'без зазора'
                : '${s.tileSpacing.round()} px',
            onChanged: s.setTileSpacing,
            c: c,
          ),
          const SizedBox(height: 18),
          _RowLabel('Раскладка', c: c),
          const SizedBox(height: 8),
          const _LayoutPicker(),
          const SizedBox(height: 12),
          _SwitchRow(
            title: 'Квадратные миниатюры',
            subtitle: 'Если выключить — плитка показывает фото целиком, без обрезки',
            value: s.squareThumbs,
            onChanged: s.setSquareThumbs,
            c: c,
          ),
          _SwitchRow(
            title: 'Уменьшить анимации',
            subtitle: 'Меньше плавных переходов — быстрее ощущается интерфейс',
            value: s.reduceMotion,
            onChanged: s.setReduceMotion,
            c: c,
          ),
          _SwitchRow(
            title: 'Метка GIF на анимациях',
            subtitle: 'Маленький значок «GIF» в углу миниатюры',
            value: s.showGifBadge,
            onChanged: s.setShowGifBadge,
            c: c,
          ),
          _SwitchRow(
            title: 'Сердечко на избранных',
            subtitle: 'Метка избранного в углу миниатюры',
            value: s.showFavBadge,
            onChanged: s.setShowFavBadge,
            c: c,
          ),
        ])),
        const SizedBox(height: 22),

        const _SectionTitle('Запуск'),
        _Card(c: c, child: Column(children: [
          _RowLabel('Стартовый раздел', c: c),
          const SizedBox(height: 8),
          const _StartPicker(),
        ])),
        const SizedBox(height: 22),

        const _SectionTitle('Теги'),
        _Card(c: c, child: Column(children: [
          _ActionRow(
            icon: Icons.upload_file_outlined,
            title: 'Экспорт тегов',
            subtitle: 'Сохранить базу тегов в JSON (бэкап/перенос)',
            onTap: () => _exportTags(context),
            c: c,
          ),
          _ActionRow(
            icon: Icons.download_outlined,
            title: 'Импорт тегов',
            subtitle: 'Загрузить теги из ранее сохранённого JSON',
            onTap: () => _importTags(context),
            c: c,
          ),
          _ActionRow(
            icon: Icons.link_outlined,
            title: 'Перепривязать теги',
            subtitle: 'Найти теги переименованных/перемещённых файлов по содержимому',
            onTap: () => _relinkTags(context),
            c: c,
          ),
        ])),
        const SizedBox(height: 22),

        const _SectionTitle('О приложении'),
        _Card(c: c, child: const _About()),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _exportTags(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = TagService.instance.exportJson();
      final name =
          'goat-tags-${DateTime.now().toIso8601String().substring(0, 10)}.json';
      String? dest;
      if (!Platform.isAndroid) {
        dest = await FilePicker.platform.saveFile(
            dialogTitle: 'Сохранить теги', fileName: name);
      }
      dest ??= p.join((await getApplicationDocumentsDirectory()).path, name);
      await File(dest).writeAsString(json);
      messenger.showSnackBar(SnackBar(content: Text('Теги сохранены: $dest')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
    }
  }

  Future<void> _importTags(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final path = res?.files.single.path;
      if (path == null) return;
      final n = TagService.instance.importJson(await File(path).readAsString());
      parent.widget.onTagsImported?.call();
      messenger.showSnackBar(SnackBar(content: Text('Импортировано тегов: $n')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось импортировать: $e')));
    }
  }

  void _relinkTags(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    final cb = parent.widget.onRelinkRequested;
    if (cb == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Перепривязка недоступна — нет активной библиотеки')));
      return;
    }
    final n = cb();
    messenger.showSnackBar(SnackBar(
        content: Text(n == 0
            ? 'Сейчас перепривязывать нечего — все теги на месте'
            : 'Перепривязано файлов: $n')));
  }
}

// ───────────────────────── переиспользуемые блоки ─────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: c.muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
    );
  }
}

class _Card extends StatelessWidget {
  final AuroraColors c;
  final Widget child;
  const _Card({required this.c, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.line),
      ),
      child: child,
    );
  }
}

class _RowLabel extends StatelessWidget {
  final String text;
  final AuroraColors c;
  const _RowLabel(this.text, {required this.c});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(text,
          style: TextStyle(
              color: c.text, fontSize: 14, fontWeight: FontWeight.w700)),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final AuroraColors c;
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        Text(valueLabel,
            style: TextStyle(color: c.muted, fontSize: 12.5)),
      ]),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: c.accent,
          thumbColor: c.accent,
          inactiveTrackColor: c.surface2,
        ),
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
    ]);
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final AuroraColors c;
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: TextStyle(color: c.muted, fontSize: 12.5)),
          ]),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: c.accent,
        ),
      ]),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final AuroraColors c;
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Icon(icon, color: c.text, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: TextStyle(color: c.muted, fontSize: 12.5)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: c.muted, size: 22),
        ]),
      ),
    );
  }
}

// ───────────────────────── выбор режима ─────────────────────────
class _ModePicker extends StatelessWidget {
  const _ModePicker();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    Widget chip(String label, IconData icon, ThemeModeChoice v) {
      final on = s.themeMode == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setThemeMode(v),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? c.accentSoft : c.surface2,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: on ? c.accent : c.line),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: on ? c.accentInk : c.muted),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      color: on ? c.accentInk : c.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return Row(children: [
      chip('Как в системе', Icons.brightness_auto_rounded, ThemeModeChoice.system),
      chip('Светлая', Icons.light_mode_rounded, ThemeModeChoice.light),
      chip('Тёмная', Icons.dark_mode_rounded, ThemeModeChoice.dark),
    ]);
  }
}

// ───────────────────────── выбор раскладки сетки ─────────────────────────
class _LayoutPicker extends StatelessWidget {
  const _LayoutPicker();
  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    Widget chip(String label, String sub, IconData icon, GridLayout v) {
      final on = s.gridLayout == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setGridLayout(v),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            decoration: BoxDecoration(
              color: on ? c.accentSoft : c.surface2,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: on ? c.accent : c.line),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: on ? c.accentInk : c.muted),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      color: on ? c.accentInk : c.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 10.5)),
            ]),
          ),
        ),
      );
    }
    return Row(children: [
      chip('Квадраты', 'ровная сетка', Icons.grid_view_rounded,
          GridLayout.square),
      chip('Мозаика', 'разные формы, видно больше', Icons.dashboard_rounded,
          GridLayout.mosaic),
    ]);
  }
}

// ───────────────────────── выбор стартового раздела ─────────────────────────
class _StartPicker extends StatelessWidget {
  const _StartPicker();
  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    Widget chip(String label, IconData icon, StartSection v) {
      final on = s.startSection == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setStartSection(v),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? c.accentSoft : c.surface2,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: on ? c.accent : c.line),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: on ? c.accentInk : c.muted),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      color: on ? c.accentInk : c.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }
    return Row(children: [
      chip('Все', Icons.grid_view_rounded, StartSection.all),
      chip('По датам', Icons.calendar_today_rounded, StartSection.dates),
      chip('Альбомы', Icons.folder_rounded, StartSection.albums),
    ]);
  }
}

// ───────────────────────── выбор базы ─────────────────────────
class _BasePicker extends StatelessWidget {
  final List<AuroraBase> bases;
  final String currentId;
  final ValueChanged<String> onPick;
  const _BasePicker({
    required this.bases,
    required this.currentId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final b in bases)
        GestureDetector(
          onTap: () => onPick(b.id),
          child: Container(
            width: 86,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: b.id == currentId ? c.accent : c.line,
                width: b.id == currentId ? 2 : 1,
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // мини-превью базы: bg + два surface уровня
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: b.bg,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: b.line),
                ),
                child: Row(children: [
                  const SizedBox(width: 6),
                  Container(
                    width: 18, height: 22,
                    decoration: BoxDecoration(
                      color: b.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 18, height: 14,
                    decoration: BoxDecoration(
                      color: b.surface2,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    width: 16, height: 4,
                    decoration: BoxDecoration(
                      color: b.text,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
              Text(b.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: c.text,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
    ]);
  }
}

// ───────────────────────── выбор акцента ─────────────────────────
class _AccentPicker extends StatelessWidget {
  final String currentId;
  final ValueChanged<String> onPick;
  const _AccentPicker({required this.currentId, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final a in kAccents)
        Tooltip(
          message: a.name,
          child: GestureDetector(
            onTap: () => onPick(a.id),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: a.base,
                shape: BoxShape.circle,
                border: Border.all(
                  color: a.id == currentId ? c.text : Colors.transparent,
                  width: 3,
                ),
              ),
              child: a.id == currentId
                  ? const Icon(Icons.check, color: Colors.white, size: 18)
                  : null,
            ),
          ),
        ),
    ]);
  }
}

// ───────────────────────── о приложении ─────────────────────────
class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(12),
          ),
          child:
              const Icon(Icons.auto_awesome_mosaic, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GOAT',
                style: TextStyle(
                    color: c.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5)),
            Text('Gallery Organizer & Auto-Tagger',
                style: TextStyle(color: c.muted, fontSize: 12.5)),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Text(
          kBuildNumber == 0
              ? 'Сборка: локальная разработка'
              : 'Сборка №$kBuildNumber',
          style: TextStyle(color: c.muted, fontSize: 13)),
    ]);
  }
}
