import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'theme.dart';
import 'settings_service.dart';
import 'tag_service.dart';
import 'update_service.dart';
import 'library_service.dart';
import 'error_log.dart';
import 'i18n.dart';

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
          tooltip: tr('Назад', 'Back', 'Atrás'),
        ),
        const SizedBox(width: 4),
        Text(tr('Настройки', 'Settings', 'Ajustes'),
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
        _SectionTitle(tr('Язык', 'Language', 'Idioma')),
        _Card(c: c, child: const _LangPicker()),
        const SizedBox(height: 22),
        _SectionTitle(tr('Внешний вид', 'Appearance', 'Apariencia')),
        _Card(
            c: c,
            child: Column(children: [
              _RowLabel(tr('Режим', 'Mode', 'Modo'), c: c),
              const SizedBox(height: 8),
              const _ModePicker(),
              const SizedBox(height: 18),
              if (s.themeMode != ThemeModeChoice.dark) ...[
                _RowLabel(
                    tr('Светлая палитра', 'Light palette', 'Paleta clara'),
                    c: c),
                const SizedBox(height: 8),
                _BasePicker(
                    bases: kLightBases,
                    currentId: s.lightBaseId,
                    onPick: s.setLightBase),
                const SizedBox(height: 18),
              ],
              if (s.themeMode != ThemeModeChoice.light) ...[
                _RowLabel(tr('Тёмная палитра', 'Dark palette', 'Paleta oscura'),
                    c: c),
                const SizedBox(height: 8),
                _BasePicker(
                    bases: kDarkBases,
                    currentId: s.darkBaseId,
                    onPick: s.setDarkBase),
                const SizedBox(height: 18),
              ],
              _RowLabel(tr('Акцент', 'Accent', 'Acento'), c: c),
              const SizedBox(height: 8),
              _AccentPicker(currentId: s.accentId, onPick: s.setAccent),
              const SizedBox(height: 18),
              _RowLabel(tr('Интерфейс', 'Interface', 'Interfaz'), c: c),
              const SizedBox(height: 8),
              const _DensityPicker(),
              const SizedBox(height: 18),
              _RowLabel(
                  tr('Кнопки разделов', 'Section buttons',
                      'Botones de secciones'),
                  c: c),
              const SizedBox(height: 8),
              const _SectionNavPicker(),
            ])),
        const SizedBox(height: 22),
        _SectionTitle(tr('Сетка', 'Grid', 'Cuadrícula')),
        _Card(
            c: c,
            child: Column(children: [
              _SliderRow(
                label: tr('Размер плиток по умолчанию', 'Default tile size',
                    'Tamaño predeterminado de las miniaturas'),
                value: s.cellSize,
                min: 70,
                max: 240,
                valueLabel: '${s.cellSize.round()} px',
                onChanged: s.setCellSize,
                c: c,
              ),
              const SizedBox(height: 16),
              _SliderRow(
                label: tr('Скругление углов', 'Corner rounding',
                    'Esquinas redondeadas'),
                value: s.gridRadius,
                min: 0,
                max: 18,
                valueLabel: s.gridRadius < 0.5
                    ? tr('острые', 'sharp', 'sin redondeo')
                    : '${s.gridRadius.round()} px',
                onChanged: s.setGridRadius,
                c: c,
              ),
              const SizedBox(height: 16),
              _SliderRow(
                label: tr('Зазор между плитками', 'Gap between tiles',
                    'Espacio entre miniaturas'),
                value: s.tileSpacing,
                min: 0,
                max: 10,
                valueLabel: s.tileSpacing < 0.5
                    ? tr('без зазора', 'no gap', 'sin espacio')
                    : '${s.tileSpacing.round()} px',
                onChanged: s.setTileSpacing,
                c: c,
              ),
              const SizedBox(height: 18),
              _RowLabel(tr('Раскладка', 'Layout', 'Diseño'), c: c),
              const SizedBox(height: 8),
              const _LayoutPicker(),
              const SizedBox(height: 18),
              _RowLabel(tr('Зазоры', 'Gaps', 'Separación'), c: c),
              const SizedBox(height: 8),
              const _GapStylePicker(),
              const SizedBox(height: 12),
              _SwitchRow(
                title: tr('Квадратные миниатюры', 'Square thumbnails',
                    'Miniaturas cuadradas'),
                subtitle: tr(
                    'Если выключить — плитка показывает фото целиком, без обрезки',
                    'Off — tiles show the whole photo without cropping',
                    'Desactivado: las miniaturas muestran la foto completa, sin recorte'),
                value: s.squareThumbs,
                onChanged: s.setSquareThumbs,
                c: c,
              ),
              _SwitchRow(
                title: tr(
                    'Не скачивать облако ради сетки',
                    'Do not download cloud files for the grid',
                    'No descargar archivos en la nube para la cuadrícula'),
                subtitle: tr(
                    'GOAT сначала берёт свой кэш и готовые миниатюры системы',
                    'GOAT uses its own cache and existing system thumbnails first',
                    'GOAT usa primero su caché y las miniaturas listas del sistema'),
                value: s.avoidCloudThumbnailDownloads,
                onChanged: s.setAvoidCloudThumbnailDownloads,
                c: c,
              ),
              _SwitchRow(
                title: tr('Уменьшить анимации', 'Reduce motion',
                    'Reducir animaciones'),
                subtitle: tr(
                    'Меньше плавных переходов — быстрее ощущается интерфейс',
                    'Fewer transitions — the UI feels snappier',
                    'Menos transiciones: la interfaz se siente más ágil'),
                value: s.reduceMotion,
                onChanged: s.setReduceMotion,
                c: c,
              ),
              _SwitchRow(
                title: tr('Метка GIF на анимациях', 'GIF badge on animations',
                    'Insignia GIF en animaciones'),
                subtitle: tr(
                    'Маленький значок «GIF» в углу миниатюры',
                    'Small "GIF" mark in the tile corner',
                    'Pequeña etiqueta "GIF" en la esquina de la miniatura'),
                value: s.showGifBadge,
                onChanged: s.setShowGifBadge,
                c: c,
              ),
              _SwitchRow(
                title: tr('Сердечко на избранных', 'Heart on favorites',
                    'Corazón en favoritos'),
                subtitle: tr(
                    'Метка избранного в углу миниатюры',
                    'Favorite mark in the tile corner',
                    'Marca de favorito en la esquina de la miniatura'),
                value: s.showFavBadge,
                onChanged: s.setShowFavBadge,
                c: c,
              ),
            ])),
        const SizedBox(height: 22),
        _SectionTitle(tr('Производительность', 'Performance', 'Rendimiento')),
        _Card(
            c: c,
            child: Column(children: [
              _RowLabel(
                  tr('Режим слабого устройства', 'Low-end device mode',
                      'Modo de dispositivo lento'),
                  c: c),
              const SizedBox(height: 4),
              Text(
                  tr(
                      '«Авто» сам включит экономию, если устройство не тянет '
                          'плавность. Отключает анимации и ограничивает фоновую '
                          'обработку миниатюр.',
                      '“Auto” enables it automatically if the device can’t keep '
                          'up. Disables animations and limits background '
                          'thumbnail work.',
                      '«Auto» lo activa solo si el dispositivo no va fluido. '
                          'Desactiva animaciones y limita las miniaturas en '
                          'segundo plano.'),
                  style: TextStyle(color: c.muted, fontSize: 12)),
              const SizedBox(height: 10),
              const _PerfPicker(),
            ])),
        const SizedBox(height: 22),
        _SectionTitle(tr('Запуск', 'Startup', 'Inicio')),
        _Card(
            c: c,
            child: Column(children: [
              _RowLabel(
                  tr('Стартовый раздел', 'Start section', 'Sección inicial'),
                  c: c),
              const SizedBox(height: 8),
              const _StartPicker(),
            ])),
        const SizedBox(height: 22),
        _SectionTitle(tr('Приватность', 'Privacy', 'Privacidad')),
        _Card(
            c: c,
            child: Column(children: [
              _SwitchRow(
                title: tr('Показывать скрытые папки', 'Show hidden folders',
                    'Mostrar carpetas ocultas'),
                subtitle: tr(
                    'Секретные альбомы (помеченные .nomedia) станут видны '
                        'в галерее. Долгий тап / ПКМ по папке — скрыть или показать.',
                    'Secret albums (marked with .nomedia) become visible. '
                        'Long-press / right-click a folder to hide or show it.',
                    'Los álbumes secretos (marcados con .nomedia) se mostrarán en la galería. Mantén pulsado / clic derecho en una carpeta para ocultarla o mostrarla.'),
                value: s.showHidden,
                onChanged: s.setShowHidden,
                c: c,
              ),
              if (s.hiddenFolders.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        '${tr('Скрыто папок', 'Hidden folders', 'Carpetas ocultas')}: ${s.hiddenFolders.length}',
                        style: TextStyle(color: c.muted, fontSize: 12.5)),
                  ),
                ),
              // на Android секретные .nomedia-папки видны только с «доступом ко
              // всем файлам» (их прячет MediaStore) — отдельный опт-ин
              if (Platform.isAndroid) ...[
                const SizedBox(height: 10),
                const _AllFilesTile(),
              ],
            ])),
        const SizedBox(height: 22),
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
          _SectionTitle(tr(
              'Поиск по компьютеру', 'Search the computer', 'Buscar en el PC')),
          _Card(
              c: c,
              child: Column(children: [
                _SliderRow(
                  label: tr(
                      'Игнорировать картинки меньше',
                      'Ignore images smaller than',
                      'Ignorar imágenes menores que'),
                  value: s.pcScanMinDim.toDouble(),
                  min: 0,
                  max: 1024,
                  valueLabel: s.pcScanMinDim == 0
                      ? tr('не отсеивать', 'no filter', 'sin filtro')
                      : '${s.pcScanMinDim} px',
                  onChanged: (v) => s.setPcScanMinDim((v / 32).round() * 32),
                  c: c,
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      tr(
                          'При «найти все картинки на ПК» отсеивает иконки и текстуры '
                              '(мелкие картинки, файлы < 20 КБ и служебные папки).',
                          'When using "find all images on PC" it filters out icons '
                              'and textures (small images, files < 20 KB, system folders).',
                          'Al usar "buscar todas las imágenes en el PC", filtra iconos y texturas (imágenes pequeñas, archivos < 20 KB y carpetas del sistema).'),
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ),
              ])),
          const SizedBox(height: 22),
        ],
        _SectionTitle(tr('Теги', 'Tags', 'Etiquetas')),
        _Card(
            c: c,
            child: Column(children: [
              _ActionRow(
                icon: Icons.upload_file_outlined,
                title: tr('Экспорт тегов', 'Export tags', 'Exportar etiquetas'),
                subtitle: tr(
                    'Сохранить базу тегов в JSON (бэкап/перенос)',
                    'Save the tag database to JSON (backup/transfer)',
                    'Guardar la base de etiquetas en JSON (copia de seguridad/traslado)'),
                onTap: () => _exportTags(context),
                c: c,
              ),
              _ActionRow(
                icon: Icons.download_outlined,
                title: tr('Импорт тегов', 'Import tags', 'Importar etiquetas'),
                subtitle: tr(
                    'Загрузить теги из ранее сохранённого JSON',
                    'Load tags from a previously saved JSON',
                    'Cargar etiquetas desde un JSON guardado'),
                onTap: () => _importTags(context),
                c: c,
              ),
              _ActionRow(
                icon: Icons.link_outlined,
                title: tr('Перепривязать теги', 'Relink tags',
                    'Revincular etiquetas'),
                subtitle: tr(
                    'Найти теги переименованных/перемещённых файлов по содержимому',
                    'Find tags of renamed/moved files by their content',
                    'Encontrar etiquetas de archivos renombrados o movidos por su contenido'),
                onTap: () => _relinkTags(context),
                c: c,
              ),
            ])),
        const SizedBox(height: 22),
        _SectionTitle(tr('Диагностика', 'Diagnostics', 'Diagnóstico')),
        _Card(
            c: c,
            child: _ActionRow(
              icon: Icons.bug_report_outlined,
              title:
                  tr('Поделиться журналом', 'Share log', 'Compartir registro'),
              subtitle: tr(
                  'Отправить файл журнала ошибок — поможет найти причину сбоев',
                  'Send the error log file — helps diagnose crashes',
                  'Enviar el registro de errores; ayuda a diagnosticar fallos'),
              onTap: () => _shareLog(context),
              c: c,
            )),
        const SizedBox(height: 22),
        _SectionTitle(tr('О приложении', 'About', 'Acerca de')),
        _Card(c: c, child: const _About()),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _shareLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final content = await ErrorLog.readAll();
    final path = ErrorLog.path;
    if (Platform.isAndroid && path != null) {
      await SharePlus.instance
          .share(ShareParams(files: [XFile(path)], text: 'GOAT log'));
    } else {
      await Clipboard.setData(ClipboardData(text: content));
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Журнал скопирован в буфер обмена',
              'Log copied to clipboard', 'Registro copiado al portapapeles'))));
    }
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
            dialogTitle: tr('Сохранить теги', 'Save tags', 'Guardar etiquetas'),
            fileName: name);
      }
      dest ??= p.join((await getApplicationDocumentsDirectory()).path, name);
      await File(dest).writeAsString(json);
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Теги сохранены', 'Tags saved', 'Etiquetas guardadas')}: $dest')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Не удалось сохранить', 'Could not save', 'No se pudo guardar')}: $e')));
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
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Импортировано тегов', 'Tags imported', 'Etiquetas importadas')}: $n')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Не удалось импортировать', 'Could not import', 'No se pudo importar')}: $e')));
    }
  }

  void _relinkTags(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    final cb = parent.widget.onRelinkRequested;
    if (cb == null) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr(
              'Перепривязка недоступна — нет активной библиотеки',
              'Relinking is unavailable — no active library',
              'No se puede revincular: no hay una biblioteca activa'))));
      return;
    }
    final n = cb();
    messenger.showSnackBar(SnackBar(
        content: Text(n == 0
            ? tr(
                'Сейчас перепривязывать нечего — все теги на месте',
                'Nothing to relink right now — all tags are in place',
                'No hay nada que revincular ahora: todas las etiquetas están en su sitio')
            : '${tr('Перепривязано файлов', 'Files relinked', 'Archivos revinculados')}: $n')));
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
        Text(valueLabel, style: TextStyle(color: c.muted, fontSize: 12.5)),
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
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: c.muted, fontSize: 12.5)),
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
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: c.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: c.muted, fontSize: 12.5)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: c.muted, size: 22),
        ]),
      ),
    );
  }
}

// ── доступ ко всем файлам (Android) — для секретных .nomedia-папок ──
class _AllFilesTile extends StatefulWidget {
  const _AllFilesTile();
  @override
  State<_AllFilesTile> createState() => _AllFilesTileState();
}

class _AllFilesTileState extends State<_AllFilesTile> {
  bool _granted = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    LibraryService.hasAllFilesAccess().then((v) {
      if (mounted) setState(() => _granted = v);
    });
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    final ok = await LibraryService.requestAllFilesAccess();
    if (mounted) {
      setState(() {
        _granted = ok;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              tr(
                  'Доступ ко всем файлам (секретные папки)',
                  'All files access (secret folders)',
                  'Acceso a todos los archivos (carpetas secretas)'),
              style: TextStyle(
                  color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
              _granted
                  ? tr(
                      'Включён — GOAT видит скрытые .nomedia-папки, другие галереи нет.',
                      'On — GOAT can see hidden .nomedia folders; other galleries cannot.',
                      'Activado: GOAT ve las carpetas .nomedia ocultas; otras galerías no.')
                  : tr(
                      'Нужен, чтобы видеть в GOAT секретные папки, скрытые от других галерей через .nomedia.',
                      'Needed so GOAT can see secret folders hidden from other galleries with .nomedia.',
                      'Hace falta para que GOAT vea carpetas secretas ocultas a otras galerías con .nomedia.'),
              style: TextStyle(color: c.muted, fontSize: 12.5)),
        ]),
      ),
      const SizedBox(width: 10),
      if (_granted)
        Icon(Icons.check_circle_rounded, color: c.accent, size: 22)
      else
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.accent),
          onPressed: _busy ? null : _request,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(tr('Включить', 'Enable', 'Activar')),
        ),
    ]);
  }
}

// ───────────────────────── выбор языка ─────────────────────────
class _LangPicker extends StatelessWidget {
  const _LangPicker();
  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    Widget chip(String label, IconData icon, AppLang v) {
      final on = s.appLang == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setAppLang(v),
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
      chip(tr('Система', 'System', 'Sistema'), Icons.translate_rounded,
          AppLang.system),
      chip('Русский', Icons.abc, AppLang.ru),
      chip('English', Icons.abc, AppLang.en),
      chip('Español', Icons.abc, AppLang.es),
    ]);
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
      chip(tr('Как в системе', 'System', 'Sistema'),
          Icons.brightness_auto_rounded, ThemeModeChoice.system),
      chip(tr('Светлая', 'Light', 'Claro'), Icons.light_mode_rounded,
          ThemeModeChoice.light),
      chip(tr('Тёмная', 'Dark', 'Oscuro'), Icons.dark_mode_rounded,
          ThemeModeChoice.dark),
    ]);
  }
}

// ───────────────────────── режим производительности ─────────────────────────
class _PerfPicker extends StatelessWidget {
  const _PerfPicker();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    final auto = s.perfMode == PerfMode.auto && s.autoWeakDetected;
    Widget chip(String label, IconData icon, PerfMode v) {
      final on = s.perfMode == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setPerfMode(v),
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
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        chip(
            tr('Авто', 'Auto', 'Auto'), Icons.auto_mode_rounded, PerfMode.auto),
        chip(tr('Включить', 'On', 'Activado'), Icons.battery_saver_rounded,
            PerfMode.on),
        chip(tr('Выключить', 'Off', 'Desactivado'), Icons.flash_on_rounded,
            PerfMode.off),
      ]),
      if (auto) ...[
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.check_circle_rounded, size: 15, color: c.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                tr(
                    'Авто-режим определил слабое устройство — экономия включена.',
                    'Auto detected a slow device — saving is on.',
                    'Auto detectó un dispositivo lento — el ahorro está activo.'),
                style: TextStyle(color: c.muted, fontSize: 11.5)),
          ),
        ]),
      ],
    ]);
  }
}

// ───────────────────────── плотность интерфейса ─────────────────────────
class _DensityPicker extends StatelessWidget {
  const _DensityPicker();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    Widget chip(String label, String sub, IconData icon, UiDensity v) {
      final on = s.uiDensity == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setUiDensity(v),
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
      chip(
          tr('Авто', 'Auto', 'Auto'),
          tr('телефон компактнее', 'compact on phone', 'compacto en teléfono'),
          Icons.auto_awesome_rounded,
          UiDensity.auto),
      chip(
          tr('Компактно', 'Compact', 'Compacto'),
          tr('больше места фото', 'more room for photos',
              'más espacio para fotos'),
          Icons.fit_screen_rounded,
          UiDensity.compact),
      chip(
          tr('Просторно', 'Roomy', 'Espacioso'),
          tr('как на ПК/планшете', 'desktop/tablet style', 'estilo PC/tablet'),
          Icons.space_dashboard_rounded,
          UiDensity.comfortable),
    ]);
  }
}

class _SectionNavPicker extends StatelessWidget {
  const _SectionNavPicker();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    Widget chip(
        String label, String sub, IconData icon, SectionNavPlacement v) {
      final on = s.sectionNavPlacement == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => s.setSectionNavPlacement(v),
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
      chip(
          tr('Везде', 'Both', 'En ambos'),
          tr('как сейчас', 'as now', 'como ahora'),
          Icons.space_bar_rounded,
          SectionNavPlacement.both),
      chip(
          tr('Сбоку', 'Side', 'Lateral'),
          tr('снизу на телефоне', 'bottom on phone', 'abajo en teléfono'),
          Icons.dock_rounded,
          SectionNavPlacement.side),
      chip(
          tr('Сверху', 'Top', 'Arriba'),
          tr('только верх', 'top only', 'solo arriba'),
          Icons.vertical_align_top_rounded,
          SectionNavPlacement.top),
    ]);
  }
}

// ───────────────────────── выбор стиля зазоров ─────────────────────────
class _GapStylePicker extends StatelessWidget {
  const _GapStylePicker();

  static const _items = [
    GapStyle.none,
    GapStyle.color,
    GapStyle.silver,
    GapStyle.gold,
    GapStyle.holographic,
    GapStyle.polaroid,
  ];

  static const _palette = [
    0xFFC96442,
    0xFFD08F3A,
    0xFF3F7D54,
    0xFF3E8C8C,
    0xFF3D7AB8,
    0xFF8C5FB8,
    0xFFC7508B,
    0xFF2B2620,
    0xFFFAFAF7,
  ];

  BoxDecoration _swatch(GapStyle st, int colorValue) {
    switch (st) {
      case GapStyle.none:
        return BoxDecoration(
          color: const Color(0x00000000),
          border: Border.all(color: const Color(0x55888888)),
          borderRadius: BorderRadius.circular(8),
        );
      case GapStyle.color:
        return BoxDecoration(
            color: Color(colorValue), borderRadius: BorderRadius.circular(8));
      case GapStyle.polaroid:
        return BoxDecoration(
            color: const Color(0xFFFAFAF7),
            border: Border.all(color: const Color(0x33000000)),
            borderRadius: BorderRadius.circular(8));
      case GapStyle.silver:
        return _grad(
            const [Color(0xFF8E8E8E), Color(0xFFFFFFFF), Color(0xFF9C9C9C)]);
      case GapStyle.gold:
        return _grad(
            const [Color(0xFF7C5A1E), Color(0xFFFFF0C0), Color(0xFF8A6A24)]);
      case GapStyle.holographic:
        return _grad(const [
          Color(0xFFFF5D8F),
          Color(0xFFFFF35D),
          Color(0xFF5DD8FF),
          Color(0xFF8A5DFF)
        ]);
    }
  }

  BoxDecoration _grad(List<Color> colors) => BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors),
        borderRadius: BorderRadius.circular(8),
      );

  String _label(GapStyle st) => switch (st) {
        GapStyle.none => tr('Нет', 'None', 'Ninguno'),
        GapStyle.color => tr('Цвет', 'Color', 'Color'),
        GapStyle.silver => tr('Серебро', 'Silver', 'Plata'),
        GapStyle.gold => tr('Золото', 'Gold', 'Oro'),
        GapStyle.holographic => tr('Голография', 'Holographic', 'Holográfico'),
        GapStyle.polaroid => tr('Полароид', 'Polaroid', 'Polaroid'),
      };

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final s = SettingsService.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final st in _items)
          GestureDetector(
            onTap: () => s.setGapStyle(st),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 54,
                height: 40,
                decoration: _swatch(st, s.gapColorValue).copyWith(
                  border: Border.all(
                    color: s.gapStyle == st ? c.accent : c.line,
                    width: s.gapStyle == st ? 2.5 : 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(_label(st),
                  style: TextStyle(
                      color: s.gapStyle == st ? c.accentInk : c.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
      ]),
      // палитра цветов для стиля «Цвет»
      if (s.gapStyle == GapStyle.color) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in _palette)
            GestureDetector(
              onTap: () => s.setGapColor(v),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Color(v),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: s.gapColorValue == v ? c.text : c.line,
                    width: s.gapColorValue == v ? 3 : 1,
                  ),
                ),
              ),
            ),
        ]),
      ],
      if (s.gapStyle != GapStyle.none) ...[
        const SizedBox(height: 8),
        Text(
            tr(
                'Зазоры видны лучше при ненулевом «зазоре между плитками» выше.',
                'Gaps are easier to see when “gap between tiles” above is not zero.',
                'La separación se ve mejor si “espacio entre miniaturas” no está en cero.'),
            style: TextStyle(color: c.muted, fontSize: 11.5)),
      ],
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
      chip(
          tr('Квадраты', 'Squares', 'Cuadrados'),
          tr('ровная сетка', 'even grid', 'cuadrícula uniforme'),
          Icons.grid_view_rounded,
          GridLayout.square),
      chip(
          tr('Мозаика', 'Mosaic', 'Mosaico'),
          tr('разные формы, видно больше', 'varied shapes, see more',
              'formas variadas, se ve más'),
          Icons.dashboard_rounded,
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
      chip(tr('Все', 'All', 'Todo'), Icons.grid_view_rounded, StartSection.all),
      chip(tr('По датам', 'By date', 'Por fecha'), Icons.calendar_today_rounded,
          StartSection.dates),
      chip(tr('Альбомы', 'Albums', 'Álbumes'), Icons.folder_rounded,
          StartSection.albums),
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

  String _label(AuroraBase b) => switch (b.id) {
        'paper' => tr('Бумага', 'Paper', 'Papel'),
        'sand' => tr('Песок', 'Sand', 'Arena'),
        'cream' => tr('Крем', 'Cream', 'Crema'),
        'mist' => tr('Туман', 'Mist', 'Niebla'),
        'charcoal' => tr('Уголь', 'Charcoal', 'Carbón'),
        'slate' => tr('Графит', 'Graphite', 'Grafito'),
        'midnight' => tr('Полночь', 'Midnight', 'Medianoche'),
        'oled' => tr('OLED-чёрный', 'OLED black', 'Negro OLED'),
        'sepia' => tr('Сепия', 'Sepia', 'Sepia'),
        _ => b.name,
      };

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
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                        width: 18,
                        height: 22,
                        decoration: BoxDecoration(
                          color: b.surface,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 18,
                        height: 14,
                        decoration: BoxDecoration(
                          color: b.surface2,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        width: 16,
                        height: 4,
                        decoration: BoxDecoration(
                          color: b.text,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Text(_label(b),
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

  String _label(AuroraAccent a) => switch (a.id) {
        'coral' => tr('Коралл', 'Coral', 'Coral'),
        'amber' => tr('Янтарь', 'Amber', 'Ámbar'),
        'olive' => tr('Олива', 'Olive', 'Oliva'),
        'sage' => tr('Шалфей', 'Sage', 'Salvia'),
        'forest' => tr('Хвоя', 'Forest', 'Bosque'),
        'teal' => tr('Бирюза', 'Teal', 'Verde azulado'),
        'ocean' => tr('Океан', 'Ocean', 'Océano'),
        'indigo' => tr('Индиго', 'Indigo', 'Índigo'),
        'violet' => tr('Фиалка', 'Violet', 'Violeta'),
        'plum' => tr('Слива', 'Plum', 'Ciruela'),
        'magenta' => tr('Маджента', 'Magenta', 'Magenta'),
        'crimson' => tr('Алый', 'Crimson', 'Carmesí'),
        _ => a.name,
      };

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final a in kAccents)
        Tooltip(
          message: _label(a),
          child: GestureDetector(
            onTap: () => onPick(a.id),
            child: Container(
              width: 36,
              height: 36,
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
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.auto_awesome_mosaic,
              color: Colors.white, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              ? tr('Сборка: локальная разработка', 'Build: local development',
                  'Compilación: desarrollo local')
              : tr('Сборка №$kBuildNumber', 'Build #$kBuildNumber',
                  'Compilación n.º $kBuildNumber'),
          style: TextStyle(color: c.muted, fontSize: 13)),
    ]);
  }
}
