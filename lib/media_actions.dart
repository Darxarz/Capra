import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'model.dart';
import 'theme.dart';
import 'trash_service.dart';
import 'tag_service.dart';
import 'i18n.dart';

/// Действия над фото (одиночные и массовые): удаление, копирование,
/// перемещение, отправка, добавление тегов. Используются и из контекстных
/// действий, и из режима массового выделения.
class MediaActions {
  /// Открыть файл в ассоциированном редакторе (KRA → Krita, PSD → Photoshop
  /// и т.п. — что назначено в системе). На ПК через системный «открыть».
  static Future<void> openInEditor(
      BuildContext context, PhotoItem photo) async {
    if (photo.isRemote) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', photo.path],
            runInShell: false);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [photo.path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [photo.path]);
      } else {
        messenger.showSnackBar(SnackBar(
            content: Text(tr('Открытие в редакторе доступно на ПК',
                'Opening in an editor is available on desktop',
                'Abrir en un editor está disponible en el escritorio'))));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr('Не удалось открыть', 'Could not open',
              'No se pudo abrir'))));
    }
  }

  /// Отправить файлы системным «Поделиться». Удалённые (по сети) пропускаются.
  static Future<int> share(List<PhotoItem> photos) async {
    final files = <XFile>[];
    for (final ph in photos) {
      if (ph.isRemote) continue;
      // на Android путь может быть недоступен — берём читаемый файл через ассет
      final f = await ph.resolveFile();
      if (f != null) files.add(XFile(f.path));
    }
    if (files.isEmpty) return 0;
    await SharePlus.instance.share(ShareParams(files: files));
    return files.length;
  }

  /// Удалить с подтверждением. Android — в системную корзину (MediaStore по
  /// assetId), ПК — в корзину GOAT. Возвращает число удалённых (−1 = отмена).
  static Future<int> delete(BuildContext context, List<PhotoItem> photos) async {
    if (photos.isEmpty) return 0;
    final c = AuroraTheme.of(context).colors;
    final n = photos.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
            n == 1
                ? tr('Удалить фото?', 'Delete photo?', '¿Eliminar la foto?')
                : tr('Удалить $n фото?', 'Delete $n photos?',
                    '¿Eliminar $n fotos?'),
            style: TextStyle(color: c.text)),
        content: Text(
          Platform.isAndroid
              ? tr(
                  'Уйдут в системную корзину — можно вернуть из «Недавно удалённых».',
                  'They go to the system trash — recoverable from “Recently deleted”.',
                  'Irán a la papelera del sistema — recuperables en «Eliminados recientemente».')
              : tr('Переедут в корзину GOAT — их можно вернуть.',
                  'They move to the GOAT trash — recoverable.',
                  'Se mueven a la papelera de GOAT — recuperables.'),
          style: TextStyle(color: c.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
                style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Удалить', 'Delete', 'Eliminar')),
          ),
        ],
      ),
    );
    if (ok != true) return -1;

    final local = photos.where((ph) => !ph.isRemote).toList();
    var moved = 0;
    if (Platform.isAndroid) {
      final entities = <AssetEntity>[];
      final noId = <String>[];
      for (final ph in local) {
        final id = ph.assetId;
        if (id != null) {
          final e = await AssetEntity.fromId(id);
          if (e != null) entities.add(e);
        } else {
          noId.add(ph.path);
        }
      }
      if (entities.isNotEmpty) {
        final res = await PhotoManager.editor.android.moveToTrash(entities);
        moved += res.length;
      }
      if (noId.isNotEmpty) moved += await TrashService.instance.trash(noId);
    } else {
      moved = await TrashService.instance.trash([for (final ph in local) ph.path]);
    }
    for (final ph in local) {
      TagService.instance.forgetPath(ph.path);
    }
    return moved;
  }

  /// Скопировать/переместить в выбранную папку (на ПК). Возвращает (ok, fail)
  /// или null, если платформа не поддерживается / папка не выбрана.
  static Future<({int ok, int fail})?> copyOrMove(
    BuildContext context,
    List<PhotoItem> photos, {
    required bool move,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    // на Android произвольное перемещение файлов ограничено (scoped storage)
    if (Platform.isAndroid || Platform.isIOS) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr(
              'Копирование/перемещение пока доступно только на ПК',
              'Copy/move is currently available on desktop only',
              'Copiar/mover está disponible solo en el escritorio por ahora'))));
      return null;
    }
    final dest = await FilePicker.platform.getDirectoryPath(
        dialogTitle: move
            ? tr('Переместить в папку', 'Move to folder', 'Mover a la carpeta')
            : tr('Скопировать в папку', 'Copy to folder',
                'Copiar a la carpeta'));
    if (dest == null) return null;

    var ok = 0, fail = 0;
    for (final ph in photos) {
      if (ph.isRemote) {
        fail++;
        continue;
      }
      try {
        if (p.equals(p.dirname(ph.path), dest)) continue; // уже здесь
        final target = _uniquePath(p.join(dest, p.basename(ph.path)));
        if (move) {
          try {
            File(ph.path).renameSync(target);
          } on FileSystemException {
            // другой диск — копируем и удаляем оригинал
            File(ph.path).copySync(target);
            File(ph.path).deleteSync();
          }
          TagService.instance.movePath(ph.path, target);
        } else {
          File(ph.path).copySync(target);
        }
        ok++;
      } catch (_) {
        fail++;
      }
    }
    return (ok: ok, fail: fail);
  }

  /// Диалог ввода тегов и применение их ко всем фото. Возвращает число фото.
  static Future<int> addTags(BuildContext context, List<PhotoItem> photos) async {
    final c = AuroraTheme.of(context).colors;
    final ctl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(tr('Добавить теги', 'Add tags', 'Añadir etiquetas'),
            style: TextStyle(color: c.text)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              tr(
                  'Через запятую или пробел. Применится ко всем выбранным (${photos.length}).',
                  'Comma- or space-separated. Applies to all selected (${photos.length}).',
                  'Separadas por comas o espacios. Se aplica a todas las seleccionadas (${photos.length}).'),
              style: TextStyle(color: c.muted, fontSize: 12.5)),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            autofocus: true,
            cursorColor: c.accent,
            style: TextStyle(color: c.text),
            decoration: InputDecoration(
                hintText: tr('например: лес, закат', 'e.g. forest, sunset',
                    'p. ej. bosque, atardecer')),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
                style: TextStyle(color: c.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.accent),
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: Text(tr('Добавить', 'Add', 'Añadir')),
          ),
        ],
      ),
    );
    if (raw == null) return 0;
    final tags = raw
        .split(RegExp(r'[,\s]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (tags.isEmpty) return 0;
    for (final ph in photos) {
      for (final t in tags) {
        TagService.instance.addTag(ph.path, t);
      }
    }
    return photos.length;
  }

  /// Путь, не затирающий существующий файл: добавляет « (1)», « (2)» …
  static String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final base = p.basenameWithoutExtension(path);
    for (var i = 1; i < 1000; i++) {
      final cand = p.join(dir, '$base ($i)$ext');
      if (!File(cand).existsSync()) return cand;
    }
    return path;
  }
}
