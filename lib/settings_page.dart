import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'theme.dart';
import 'gx.dart';
import 'settings_service.dart';
import 'tag_service.dart';
import 'update_service.dart';
import 'library_service.dart';
import 'error_log.dart';
import 'i18n.dart';
import 'backup_service.dart';
import 'pin_lock.dart';

// ── свои значки раздела (сетка 24×24, тот же штрих, что у GxGlyph) ──
const _gGlobe = GxGlyph(
    'M20.5 12a8.5 8.5 0 1 1-17 0a8.5 8.5 0 0 1 17 0M3.5 12h17M12 3.5c-2.4 2.4-3.6 5.2-3.6 8.5s1.2 6.1 3.6 8.5c2.4-2.4 3.6-5.2 3.6-8.5s-1.2-6.1-3.6-8.5z');
const _gSun = GxGlyph(
    'M16 12a4 4 0 1 1-8 0a4 4 0 0 1 8 0M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6L18 18M6 18l1.4-1.4M16.6 7.4L18 6');
const _gMoon = GxGlyph('M19.5 14.5A7.5 7.5 0 0 1 9.5 4.5a7.5 7.5 0 1 0 10 10z');
const _gBattery = GxGlyph('M3.5 8h14v8h-14zM20.5 11v2M10.5 10.5v3M9 12h3');
const _gSpark = GxGlyph(
    'M12 4l1.8 4.7L18.5 10.5l-4.7 1.8L12 17l-1.8-4.7L5.5 10.5l4.7-1.8z');
const _gDense = GxGlyph('M4 8.5h16M4 12h16M4 15.5h16');
const _gBoth = GxGlyph('M4.5 4.5h15v15h-15zM4.5 9.5h15M9.5 9.5v10');
const _gTopBar = GxGlyph('M4.5 4.5h15v15h-15zM4.5 9.5h15');
const _gLock = GxGlyph('M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3');
const _gUnlock = GxGlyph('M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 6.8-1.2');
const _gKey = GxGlyph(
    'M11.5 15.5a3.5 3.5 0 1 1-7 0a3.5 3.5 0 0 1 7 0M11 13l8.5-8.5M16.5 7l2.5 2.5');
const _gSave = GxGlyph('M5 4.5h11l3.5 3.5v11.5H5zM8 4.5v4h7v-4M8 19.5v-6h8v6');
const _gRestore = GxGlyph('M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v4h4');
const _gUpload = GxGlyph('M12 15V4.5M7.5 9L12 4.5 16.5 9M5 19.5h14');
const _gDownload = GxGlyph('M12 4.5V15M7.5 10.5L12 15l4.5-4.5M5 19.5h14');
const _gLink = GxGlyph(
    'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1');

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
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 52,
        child: Row(children: [
          const SizedBox(width: 4),
          GxIconBtn(GxGlyph.back, tr('Назад', 'Back', 'Atrás'), onTap: onBack),
          const SizedBox(width: 6),
          Text(tr('Настройки', 'Settings', 'Ajustes'),
              style: TextStyle(
                  color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
      ),
      const GxHLine(),
    ]);
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
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      children: [
        _SectionTitle(tr('Язык', 'Language', 'Idioma')),
        const _Group(children: [
          _Block(child: _LangPicker()),
        ]),
        _SectionTitle(tr('Внешний вид', 'Appearance', 'Apariencia')),
        _Group(children: [
          _Block(label: tr('Режим', 'Mode', 'Modo'), child: const _ModePicker()),
          if (s.themeMode != ThemeModeChoice.dark)
            _Block(
                label: tr('Светлая палитра', 'Light palette', 'Paleta clara'),
                child: _BasePicker(
                    bases: kLightBases,
                    currentId: s.lightBaseId,
                    onPick: s.setLightBase)),
          if (s.themeMode != ThemeModeChoice.light)
            _Block(
                label: tr('Тёмная палитра', 'Dark palette', 'Paleta oscura'),
                child: _BasePicker(
                    bases: kDarkBases,
                    currentId: s.darkBaseId,
                    onPick: s.setDarkBase)),
          if (kAccents.length >= 2)
            _Block(
                label: tr('Акцент', 'Accent', 'Acento'),
                child: _AccentPicker(
                    currentId: s.accentId, onPick: s.setAccent)),
          _Block(
              label: tr('Интерфейс', 'Interface', 'Interfaz'),
              child: const _DensityPicker()),
          _Block(
              label: tr('Кнопки разделов', 'Section buttons',
                  'Botones de secciones'),
              child: const _SectionNavPicker()),
        ]),
        _SectionTitle(tr('Сетка', 'Grid', 'Cuadrícula')),
        _Group(children: [
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
          _SliderRow(
            label: tr(
                'Скругление углов', 'Corner rounding', 'Esquinas redondeadas'),
            value: s.gridRadius,
            min: 0,
            max: 18,
            valueLabel: s.gridRadius < 0.5
                ? tr('острые', 'sharp', 'sin redondeo')
                : '${s.gridRadius.round()} px',
            onChanged: s.setGridRadius,
            c: c,
          ),
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
          _Block(
              label: tr('Раскладка', 'Layout', 'Diseño'),
              child: const _LayoutPicker()),
          _Block(
              label: tr('Зазоры', 'Gaps', 'Separación'),
              child: const _GapStylePicker()),
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
            title: tr(
                'Уменьшить анимации', 'Reduce motion', 'Reducir animaciones'),
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
        ]),
        _SectionTitle(tr('Производительность', 'Performance', 'Rendimiento')),
        _Group(children: [
          _Block(
            label: tr('Режим слабого устройства', 'Low-end device mode',
                'Modo de dispositivo lento'),
            note: tr(
                '«Авто» сам включит экономию, если устройство не тянет '
                    'плавность. Отключает анимации и ограничивает фоновую '
                    'обработку миниатюр.',
                '“Auto” enables it automatically if the device can’t keep '
                    'up. Disables animations and limits background '
                    'thumbnail work.',
                '«Auto» lo activa solo si el dispositivo no va fluido. '
                    'Desactiva animaciones y limita las miniaturas en '
                    'segundo plano.'),
            child: const _PerfPicker(),
          ),
        ]),
        _SectionTitle(tr('Запуск', 'Startup', 'Inicio')),
        _Group(children: [
          _Block(
              label: tr('Стартовый раздел', 'Start section', 'Sección inicial'),
              child: const _StartPicker()),
        ]),
        _SectionTitle(tr('Приватность', 'Privacy', 'Privacidad')),
        _Group(children: [
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
            onChanged: (v) => _onToggleShowHidden(context, s, v),
            c: c,
          ),
          if (!s.hasPin)
            _ActionRow(
              glyph: _gLock,
              title: tr('Задать PIN', 'Set a PIN', 'Establecer PIN'),
              subtitle: tr(
                  'Защитить показ скрытых папок PIN-кодом',
                  'Protect showing hidden folders with a PIN',
                  'Proteger la visualización de carpetas ocultas con un PIN'),
              onTap: () => _onSetPin(context),
              c: c,
            )
          else ...[
            _ActionRow(
              glyph: _gKey,
              title: tr('Сменить PIN', 'Change PIN', 'Cambiar PIN'),
              subtitle: tr(
                  'Задать новый код взамен текущего',
                  'Set a new code instead of the current one',
                  'Establecer un nuevo código en lugar del actual'),
              onTap: () => _onChangePin(context),
              c: c,
            ),
            _ActionRow(
              glyph: _gUnlock,
              title: tr(
                  'Снять защиту', 'Remove protection', 'Quitar protección'),
              subtitle: tr(
                  'Убрать PIN — скрытые папки перестанут быть защищены',
                  'Remove the PIN — hidden folders will no longer be protected',
                  'Quitar el PIN: las carpetas ocultas dejarán de estar protegidas'),
              onTap: () => _onRemovePin(context),
              c: c,
            ),
          ],
          if (s.hiddenFolders.isNotEmpty)
            _NoteRow(
                '${tr('Скрыто папок', 'Hidden folders', 'Carpetas ocultas')}: ${s.hiddenFolders.length}'),
          // на Android секретные .nomedia-папки видны только с «доступом ко
          // всем файлам» (их прячет MediaStore) — отдельный опт-ин
          if (Platform.isAndroid) const _AllFilesTile(),
        ]),
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
          _SectionTitle(tr(
              'Поиск по компьютеру', 'Search the computer', 'Buscar en el PC')),
          _Group(children: [
            _SliderRow(
              label: tr('Игнорировать картинки меньше',
                  'Ignore images smaller than', 'Ignorar imágenes menores que'),
              value: s.pcScanMinDim.toDouble(),
              min: 0,
              max: 1024,
              valueLabel: s.pcScanMinDim == 0
                  ? tr('не отсеивать', 'no filter', 'sin filtro')
                  : '${s.pcScanMinDim} px',
              onChanged: (v) => s.setPcScanMinDim((v / 32).round() * 32),
              note: tr(
                  'При «найти все картинки на ПК» отсеивает иконки и текстуры '
                      '(мелкие картинки, файлы < 20 КБ и служебные папки).',
                  'When using "find all images on PC" it filters out icons '
                      'and textures (small images, files < 20 KB, system folders).',
                  'Al usar "buscar todas las imágenes en el PC", filtra iconos y texturas (imágenes pequeñas, archivos < 20 KB y carpetas del sistema).'),
              c: c,
            ),
          ]),
        ],
        _SectionTitle(tr('Резервная копия', 'Backup', 'Copia de seguridad')),
        _Group(children: [
          _ActionRow(
            glyph: _gSave,
            title: tr('Сохранить резервную копию', 'Save a backup',
                'Guardar copia de seguridad'),
            subtitle: tr(
                'Избранное, настройки, скрытые папки, коллекции, папки '
                    'библиотеки и теги — одним файлом',
                'Favorites, settings, hidden folders, collections, '
                    'library folders and tags — in one file',
                'Favoritos, ajustes, carpetas ocultas, colecciones, '
                    'carpetas de la biblioteca y etiquetas en un solo archivo'),
            onTap: () => _exportBackup(context),
            c: c,
          ),
          _ActionRow(
            glyph: _gRestore,
            title: tr('Восстановить из копии', 'Restore from backup',
                'Restaurar desde una copia'),
            subtitle: tr(
                'Загрузить ранее сохранённый файл резервной копии',
                'Load a previously saved backup file',
                'Cargar un archivo de copia de seguridad guardado antes'),
            onTap: () => _importBackup(context),
            c: c,
          ),
        ]),
        _SectionTitle(tr('Теги', 'Tags', 'Etiquetas')),
        _Group(children: [
          _ActionRow(
            glyph: _gUpload,
            title: tr('Экспорт тегов', 'Export tags', 'Exportar etiquetas'),
            subtitle: tr(
                'Сохранить базу тегов в JSON (бэкап/перенос)',
                'Save the tag database to JSON (backup/transfer)',
                'Guardar la base de etiquetas en JSON (copia de seguridad/traslado)'),
            onTap: () => _exportTags(context),
            c: c,
          ),
          _ActionRow(
            glyph: _gDownload,
            title: tr('Импорт тегов', 'Import tags', 'Importar etiquetas'),
            subtitle: tr(
                'Загрузить теги из ранее сохранённого JSON',
                'Load tags from a previously saved JSON',
                'Cargar etiquetas desde un JSON guardado'),
            onTap: () => _importTags(context),
            c: c,
          ),
          _ActionRow(
            glyph: _gLink,
            title: tr(
                'Перепривязать теги', 'Relink tags', 'Revincular etiquetas'),
            subtitle: tr(
                'Найти теги переименованных/перемещённых файлов по содержимому',
                'Find tags of renamed/moved files by their content',
                'Encontrar etiquetas de archivos renombrados o movidos por su contenido'),
            onTap: () => _relinkTags(context),
            c: c,
          ),
        ]),
        _SectionTitle(tr('Диагностика', 'Diagnostics', 'Diagnóstico')),
        _Group(children: [
          _ActionRow(
            glyph: GxGlyph.share,
            title: tr('Поделиться журналом', 'Share log', 'Compartir registro'),
            subtitle: tr(
                'Отправить файл журнала ошибок — поможет найти причину сбоев',
                'Send the error log file — helps diagnose crashes',
                'Enviar el registro de errores; ayuda a diagnosticar fallos'),
            onTap: () => _shareLog(context),
            c: c,
          ),
        ]),
        _SectionTitle(tr('О приложении', 'About', 'Acerca de')),
        const _Group(children: [_About()]),
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

  Future<void> _exportBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = await BackupService.exportAll();
      final name =
          'goat-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';
      String? dest;
      if (!Platform.isAndroid) {
        dest = await FilePicker.platform.saveFile(
            dialogTitle: tr('Сохранить резервную копию', 'Save backup',
                'Guardar copia de seguridad'),
            fileName: name);
      }
      dest ??= p.join((await getApplicationDocumentsDirectory()).path, name);
      await File(dest).writeAsString(json);
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Резервная копия сохранена', 'Backup saved', 'Copia de seguridad guardada')}: $dest')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Не удалось сохранить', 'Could not save', 'No se pudo guardar')}: $e')));
    }
  }

  Future<void> _importBackup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final path = res?.files.single.path;
      if (path == null) return;
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
              tr('Восстановить из копии?', 'Restore from backup?',
                  '¿Restaurar desde la copia?')),
          content: Text(
            tr(
                'Избранное, настройки внешнего вида, скрытые папки, папки '
                    'библиотеки и коллекции будут заменены содержимым файла. '
                    'Теги — добавлены/обновлены, ничего не удаляя.',
                'Favorites, appearance settings, hidden folders, library '
                    'folders and collections will be replaced with the '
                    'file\'s contents. Tags are merged in, nothing is deleted.',
                'Los favoritos, ajustes de apariencia, carpetas ocultas, '
                    'carpetas de la biblioteca y colecciones se reemplazarán '
                    'con el contenido del archivo. Las etiquetas se combinan, '
                    'sin borrar nada.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена', 'Cancel', 'Cancelar')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Восстановить', 'Restore', 'Restaurar')),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final json = await File(path).readAsString();
      final result = await BackupService.importAll(json);
      parent.widget.onTagsImported?.call();
      if (result.isEmpty) {
        messenger.showSnackBar(SnackBar(
            content: Text(tr(
                'Не удалось распознать файл резервной копии',
                'Could not recognize the backup file',
                'No se pudo reconocer el archivo de copia de seguridad'))));
        return;
      }
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Восстановлено', 'Restored', 'Restaurado')}: '
              '${tr('избранное', 'favorites', 'favoritos')} ${result.favorites}, '
              '${tr('коллекции', 'collections', 'colecciones')} ${result.collections}, '
              '${tr('папки библиотеки', 'library folders', 'carpetas de biblioteca')} ${result.libraryFolders}, '
              '${tr('теги', 'tags', 'etiquetas')} ${result.tags}. '
              '${tr('Часть изменений применится после перезапуска приложения.', 'Some changes take effect after restarting the app.', 'Algunos cambios se aplicarán tras reiniciar la aplicación.')}'),
          duration: const Duration(seconds: 6)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr('Не удалось восстановить', 'Could not restore', 'No se pudo restaurar')}: $e')));
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

  Future<void> _onToggleShowHidden(
      BuildContext context, SettingsService s, bool v) async {
    if (!v) {
      // выключение не требует PIN
      s.setShowHidden(false);
      return;
    }
    if (!s.hasPin) {
      // PIN ещё не задан — сперва предлагаем его задать
      final created = await setNewPin(context);
      if (!created) return;
      if (!context.mounted) return;
      s.setShowHidden(true);
      return;
    }
    final ok = await requestPin(context);
    if (ok) s.setShowHidden(true);
  }

  Future<void> _onSetPin(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await setNewPin(context);
    if (ok) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('PIN задан', 'PIN set', 'PIN establecido'))));
    }
  }

  Future<void> _onChangePin(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await changePin(context);
    if (ok) {
      messenger.showSnackBar(SnackBar(
          content:
              Text(tr('PIN изменён', 'PIN changed', 'PIN modificado'))));
    }
  }

  Future<void> _onRemovePin(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await removePin(context);
    if (ok) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Защита PIN-ом снята', 'PIN protection removed',
              'Protección por PIN eliminada'))));
    }
  }
}

// ───────────────────────── переиспользуемые блоки ─────────────────────────

/// Подпись секции: мелкая, приглушённая, без капса.
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Text(text,
          style: TextStyle(
              color: c.muted, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// Группа строк в одной рамке (1px, скругление 7); строки разделены тонкой
/// линией.
class _Group extends StatelessWidget {
  final List<Widget> children;
  const _Group({required this.children});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Material(
      color: c.panel,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: gxCorner,
        side: BorderSide(color: c.line),
      ),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) GxHLine(color: c.rowLine),
          children[i],
        ],
      ]),
    );
  }
}

/// Строка-блок: необязательная подпись (14) и пояснение (12), под ними — элемент
/// управления на всю ширину.
class _Block extends StatelessWidget {
  final String? label;
  final String? note;
  final Widget child;
  const _Block({this.label, this.note, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (label != null)
          Text(label!,
              style: TextStyle(
                  color: c.text, fontSize: 14, fontWeight: FontWeight.w500)),
        if (note != null) ...[
          const SizedBox(height: 2),
          Text(note!, style: TextStyle(color: c.muted, fontSize: 12)),
        ],
        if (label != null || note != null) const SizedBox(height: 10),
        child,
      ]),
    );
  }
}

/// Строка-примечание (мелкий приглушённый текст) внутри группы.
class _NoteRow extends StatelessWidget {
  final String text;
  const _NoteRow(this.text);

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text, style: TextStyle(color: c.muted, fontSize: 12)),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String? note;
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final AuroraColors c;
  const _SliderRow({
    required this.label,
    this.note,
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: c.text, fontSize: 14, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 8),
          Text(valueLabel, style: TextStyle(color: c.muted, fontSize: 12)),
        ]),
        SizedBox(
          height: 32,
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
        if (note != null) ...[
          const SizedBox(height: 2),
          Text(note!, style: TextStyle(color: c.muted, fontSize: 12)),
        ],
      ]),
    );
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: c.text, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: c.muted, fontSize: 12)),
                ]),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ]),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final GxGlyph glyph;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final AuroraColors c;
  const _ActionRow({
    required this.glyph,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            GxIcon(glyph, color: c.muted, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: c.text, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(color: c.muted, fontSize: 12)),
                  ]),
            ),
            const SizedBox(width: 8),
            GxIcon(GxGlyph.forward, color: c.dim, size: 18),
          ]),
        ),
      ),
    );
  }
}

/// Плитка выбора в ряду переключателей: значок, подпись, необязательное пояснение.
/// Выбранная — с рамкой акцента и фоном «выбранного».
class _ChoiceTile extends StatelessWidget {
  final String label;
  final String? sub;
  final GxGlyph? glyph;
  final bool on;
  final VoidCallback onTap;
  const _ChoiceTile({
    required this.label,
    this.sub,
    this.glyph,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Material(
      color: on ? c.selected : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: gxCorner,
        side: BorderSide(color: on ? c.accent : c.field),
      ),
      child: InkWell(
        borderRadius: gxCorner,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (glyph != null) ...[
                  GxIcon(glyph!, color: on ? c.accent : c.muted, size: 18),
                  const SizedBox(height: 4),
                ],
                Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: on ? c.strong : c.text,
                        fontSize: 13,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w500)),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(sub!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ],
              ]),
        ),
      ),
    );
  }
}

/// Ряд плиток равной ширины и высоты.
class _TileRow extends StatelessWidget {
  final List<Widget> tiles;
  const _TileRow(this.tiles);

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: tiles[i]),
        ],
      ]),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                tr(
                    'Доступ ко всем файлам (секретные папки)',
                    'All files access (secret folders)',
                    'Acceso a todos los archivos (carpetas secretas)'),
                style: TextStyle(color: c.text, fontSize: 14)),
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
                style: TextStyle(color: c.muted, fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 10),
        if (_granted)
          GxIcon(GxGlyph.check, color: c.accent, size: 20)
        else if (_busy)
          const SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else
          GxTextBtn(tr('Включить', 'Enable', 'Activar'),
              primary: true, onTap: _request),
      ]),
    );
  }
}

// ───────────────────────── выбор языка ─────────────────────────
class _LangPicker extends StatelessWidget {
  const _LangPicker();
  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    Widget chip(String label, GxGlyph? glyph, AppLang v) => _ChoiceTile(
          label: label,
          glyph: glyph,
          on: s.appLang == v,
          onTap: () => s.setAppLang(v),
        );

    return _TileRow([
      chip(tr('Система', 'System', 'Sistema'), _gGlobe, AppLang.system),
      chip('Русский', null, AppLang.ru),
      chip('English', null, AppLang.en),
      chip('Español', null, AppLang.es),
    ]);
  }
}

// ───────────────────────── выбор режима ─────────────────────────
class _ModePicker extends StatelessWidget {
  const _ModePicker();

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    Widget chip(String label, GxGlyph glyph, ThemeModeChoice v) => _ChoiceTile(
          label: label,
          glyph: glyph,
          on: s.themeMode == v,
          onTap: () => s.setThemeMode(v),
        );

    return _TileRow([
      chip(tr('Как в системе', 'System', 'Sistema'), GxGlyph.monitor,
          ThemeModeChoice.system),
      chip(tr('Светлая', 'Light', 'Claro'), _gSun, ThemeModeChoice.light),
      chip(tr('Тёмная', 'Dark', 'Oscuro'), _gMoon, ThemeModeChoice.dark),
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
    Widget chip(String label, GxGlyph glyph, PerfMode v) => _ChoiceTile(
          label: label,
          glyph: glyph,
          on: s.perfMode == v,
          onTap: () => s.setPerfMode(v),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _TileRow([
        chip(tr('Авто', 'Auto', 'Auto'), _gSpark, PerfMode.auto),
        chip(tr('Включить', 'On', 'Activado'), _gBattery, PerfMode.on),
        chip(tr('Выключить', 'Off', 'Desactivado'), GxGlyph.bolt, PerfMode.off),
      ]),
      if (auto) ...[
        const SizedBox(height: 8),
        Row(children: [
          GxIcon(GxGlyph.check, size: 15, color: c.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                tr(
                    'Авто-режим определил слабое устройство — экономия включена.',
                    'Auto detected a slow device — saving is on.',
                    'Auto detectó un dispositivo lento — el ahorro está activo.'),
                style: TextStyle(color: c.muted, fontSize: 12)),
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
    final s = SettingsService.instance;
    Widget chip(String label, String sub, GxGlyph glyph, UiDensity v) =>
        _ChoiceTile(
          label: label,
          sub: sub,
          glyph: glyph,
          on: s.uiDensity == v,
          onTap: () => s.setUiDensity(v),
        );

    return _TileRow([
      chip(
          tr('Авто', 'Auto', 'Auto'),
          tr('телефон компактнее', 'compact on phone', 'compacto en teléfono'),
          _gSpark,
          UiDensity.auto),
      chip(
          tr('Компактно', 'Compact', 'Compacto'),
          tr('больше места фото', 'more room for photos',
              'más espacio para fotos'),
          _gDense,
          UiDensity.compact),
      chip(
          tr('Просторно', 'Roomy', 'Espacioso'),
          tr('как на ПК/планшете', 'desktop/tablet style', 'estilo PC/tablet'),
          GxGlyph.list,
          UiDensity.comfortable),
    ]);
  }
}

class _SectionNavPicker extends StatelessWidget {
  const _SectionNavPicker();

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    Widget chip(
            String label, String sub, GxGlyph glyph, SectionNavPlacement v) =>
        _ChoiceTile(
          label: label,
          sub: sub,
          glyph: glyph,
          on: s.sectionNavPlacement == v,
          onTap: () => s.setSectionNavPlacement(v),
        );

    return _TileRow([
      chip(
          tr('Везде', 'Both', 'En ambos'),
          tr('как сейчас', 'as now', 'como ahora'),
          _gBoth,
          SectionNavPlacement.both),
      chip(
          tr('Сбоку', 'Side', 'Lateral'),
          tr('снизу на телефоне', 'bottom on phone', 'abajo en teléfono'),
          GxGlyph.sidebar,
          SectionNavPlacement.side),
      chip(
          tr('Сверху', 'Top', 'Arriba'),
          tr('только верх', 'top only', 'solo arriba'),
          _gTopBar,
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

  // Образцы стилей — это сами цвета/градиенты, их палитра не из темы.
  BoxDecoration _swatch(GapStyle st, int colorValue) {
    switch (st) {
      case GapStyle.none:
        return BoxDecoration(
          color: const Color(0x00000000),
          borderRadius: gxCorner,
        );
      case GapStyle.color:
        return BoxDecoration(color: Color(colorValue), borderRadius: gxCorner);
      case GapStyle.polaroid:
        return BoxDecoration(
            color: const Color(0xFFFAFAF7), borderRadius: gxCorner);
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
        borderRadius: gxCorner,
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
                    color: s.gapStyle == st ? c.accent : c.field,
                    width: s.gapStyle == st ? 2 : 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(_label(st),
                  style: TextStyle(
                      color: s.gapStyle == st ? c.strong : c.muted,
                      fontSize: 12,
                      fontWeight: s.gapStyle == st
                          ? FontWeight.w600
                          : FontWeight.w400)),
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
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Color(v),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: s.gapColorValue == v ? c.text : c.field,
                    width: s.gapColorValue == v ? 2 : 1,
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
            style: TextStyle(color: c.muted, fontSize: 12)),
      ],
    ]);
  }
}

// ───────────────────────── выбор раскладки сетки ─────────────────────────
class _LayoutPicker extends StatelessWidget {
  const _LayoutPicker();
  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    Widget chip(String label, String sub, GxGlyph glyph, GridLayout v) =>
        _ChoiceTile(
          label: label,
          sub: sub,
          glyph: glyph,
          on: s.gridLayout == v,
          onTap: () => s.setGridLayout(v),
        );

    return _TileRow([
      chip(
          tr('Квадраты', 'Squares', 'Cuadrados'),
          tr('ровная сетка', 'even grid', 'cuadrícula uniforme'),
          GxGlyph.grid,
          GridLayout.square),
      chip(
          tr('Мозаика', 'Mosaic', 'Mosaico'),
          tr('разные формы, видно больше', 'varied shapes, see more',
              'formas variadas, se ve más'),
          GxGlyph.mosaic,
          GridLayout.mosaic),
    ]);
  }
}

// ───────────────────────── выбор стартового раздела ─────────────────────────
class _StartPicker extends StatelessWidget {
  const _StartPicker();
  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    Widget chip(String label, GxGlyph glyph, StartSection v) => _ChoiceTile(
          label: label,
          glyph: glyph,
          on: s.startSection == v,
          onTap: () => s.setStartSection(v),
        );

    return _TileRow([
      chip(tr('Все', 'All', 'Todo'), GxGlyph.grid, StartSection.all),
      chip(tr('По датам', 'By date', 'Por fecha'), GxGlyph.calendar,
          StartSection.dates),
      chip(tr('Альбомы', 'Albums', 'Álbumes'), GxGlyph.folder,
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
        'night' => tr('Ночь', 'Night', 'Noche'),
        'oled' => tr('OLED-чёрный', 'OLED black', 'Negro OLED'),
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
            width: 92,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: b.id == currentId ? c.selected : Colors.transparent,
              borderRadius: gxCorner,
              border: Border.all(
                color: b.id == currentId ? c.accent : c.field,
              ),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // мини-превью палитры: фон + две панели + строка текста
                  Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: b.bg,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: b.line),
                    ),
                    child: Row(children: [
                      const SizedBox(width: 6),
                      Container(width: 18, height: 22, color: b.surface),
                      const SizedBox(width: 4),
                      Container(width: 18, height: 14, color: b.surface2),
                      const Spacer(),
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        width: 16,
                        height: 3,
                        color: b.text,
                      ),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Text(_label(b),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: b.id == currentId ? c.strong : c.text,
                          fontSize: 12,
                          fontWeight: b.id == currentId
                              ? FontWeight.w600
                              : FontWeight.w400)),
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
        'explorer' => tr('Как в проводнике', 'Like in Explorer',
            'Como en el Explorador'),
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
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: a.base,
                shape: BoxShape.circle,
                border: Border.all(
                  color: a.id == currentId ? c.text : Colors.transparent,
                  width: 2,
                ),
              ),
              child: a.id == currentId
                  ? Center(
                      child:
                          GxIcon(GxGlyph.check, color: c.onAccent, size: 16))
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: gxCorner,
            ),
            child: Center(
                child: GxIcon(GxGlyph.mosaic, color: c.onAccent, size: 22)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GOAT',
                      style: TextStyle(
                          color: c.strong,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1)),
                  const SizedBox(height: 2),
                  Text('Gallery Organizer & Auto-Tagger',
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text(
            kBuildNumber == 0
                ? tr('Сборка: локальная разработка', 'Build: local development',
                    'Compilación: desarrollo local')
                : tr('Сборка №$kBuildNumber', 'Build #$kBuildNumber',
                    'Compilación n.º $kBuildNumber'),
            style: TextStyle(color: c.muted, fontSize: 12)),
      ]),
    );
  }
}
