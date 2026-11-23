import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'archive_bridge.dart';
import 'collections_service.dart';
import 'tag_service.dart';
import 'gx.dart';
import 'i18n.dart';
import 'theme.dart';

// Общие для всех экранов кусочки связки с Goat Archive: значок библиотеки,
// предупреждение перед изменением библиотеки, «Влить в коллекцию», «Открыть
// Goat Archive», открытие страницы-источника. Слова — те же, что в сортировщике.

/// Сколько файлов из [paths] лежит в библиотеке Goat Archive (0 — ни одного).
int archiveCount(Iterable<String> paths) =>
    ArchiveBridge.instance.countInLibrary(paths);

/// Фраза-предупреждение: изменение затронет библиотеку, сортировщик заметит.
/// [inLibrary] из [total] файлов лежат в библиотеке.
String archiveNotice({int inLibrary = 0, int total = 0}) {
  final tail = tr(
      'Goat Archive заметит изменение при следующей проверке библиотеки.',
      'Goat Archive will notice the change at its next library check.',
      'Goat Archive notará el cambio en su próxima comprobación de la biblioteca.');
  if (total > 1 && inLibrary > 0 && inLibrary < total) {
    return '${tr('Из них в библиотеке Goat Archive: $inLibrary.', 'Of these, $inLibrary are in the Goat Archive library.', 'De ellos, $inLibrary están en la biblioteca de Goat Archive.')} $tail';
  }
  return '${tr('Это библиотека Goat Archive.', 'This is a Goat Archive library.', 'Esta es una biblioteca de Goat Archive.')} $tail';
}

/// Блок предупреждения внутри диалога — тот же вид, что у «нужно решение» в
/// сортировщике (цвет warn).
class ArchiveNoticeBox extends StatelessWidget {
  final String text;
  const ArchiveNoticeBox(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        borderRadius: gxCorner,
        border: Border.all(color: c.warn.withValues(alpha: 0.6)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: GxIcon(GxGlyph.archive, color: c.warn, size: 16),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(color: c.text, fontSize: 13, height: 1.3)),
        ),
      ]),
    );
  }
}

/// Одно ясное подтверждение перед действием. [notice] — предупреждение про
/// библиотеку Goat Archive (если действие её затрагивает). true — «да».
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? body,
  String? notice,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (body != null) Text(body),
              if (body != null && notice != null) const SizedBox(height: 12),
              if (notice != null) ArchiveNoticeBox(notice),
            ]),
      ),
      actions: [
        GxTextBtn(tr('Отмена', 'Cancel', 'Cancelar'),
            onTap: () => Navigator.pop(ctx, false)),
        GxTextBtn(action, primary: true, onTap: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return ok == true;
}

/// Маленькая метка «Goat Archive» — у корня библиотеки в панели папок.
class ArchiveBadge extends StatelessWidget {
  const ArchiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Tooltip(
      message: tr(
          'Библиотека Goat Archive: её собирает и проверяет сортировщик',
          'Goat Archive library: built and verified by the sorter',
          'Biblioteca de Goat Archive: la crea y verifica el clasificador'),
      child: GxIcon(GxGlyph.archive, color: c.current, size: 14),
    );
  }
}

String get mergeIntoArchiveLabel => tr('Влить в коллекцию (Goat Archive)',
    'Merge into collection (Goat Archive)', 'Unir a la colección (Goat Archive)');

String get openArchiveLabel =>
    tr('Открыть Goat Archive', 'Open Goat Archive', 'Abrir Goat Archive');

String get refreshFromArchiveLabel => tr('Обновить из Goat Archive',
    'Refresh from Goat Archive', 'Actualizar desde Goat Archive');

String _notInstalledText() => tr(
    'Goat Archive на этом компьютере ещё не запускали — откройте его один раз, и приложения найдут друг друга.',
    'Goat Archive has not been started on this PC yet — open it once so the apps can find each other.',
    'Goat Archive aún no se ha iniciado en este PC: ábrelo una vez para que las apps se encuentren.');

/// Можно ли предложить «Влить в коллекцию» для папки: только Windows, папка не
/// внутри библиотеки и сама не содержит библиотеку.
bool canMergeIntoArchive(String folder) {
  if (!Platform.isWindows || folder.isEmpty) return false;
  final b = ArchiveBridge.instance;
  if (b.inLibrary(folder)) return false;
  return !b.libraries.any((root) => isSameOrUnder(root, folder));
}

/// «Влить в коллекцию (Goat Archive)»: передать папку сортировщику. Он только
/// добавит её в свой список; само слияние начинает владелец кнопкой «Начать».
/// [selected] — действие вызвано из выделения: тогда сначала объясняем, что
/// уйдёт вся папка целиком.
Future<void> mergeFolderIntoArchive(BuildContext context, String folder,
    {int? selected}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  if (GoatApps.archiveExe() == null) {
    say(_notInstalledText());
    return;
  }
  if (selected != null) {
    final ok = await confirmAction(
      context,
      title: tr('Влить папку в коллекцию?', 'Merge the folder into the collection?',
          '¿Unir la carpeta a la colección?'),
      body: tr(
          'Goat Archive принимает папки целиком. В его список попадёт вся папка, а не только выбранные файлы ($selected):\n$folder',
          'Goat Archive takes whole folders. The entire folder goes on its list, not only the selected files ($selected):\n$folder',
          'Goat Archive acepta carpetas enteras. Toda la carpeta irá a su lista, no solo los archivos seleccionados ($selected):\n$folder'),
      action: tr('Влить', 'Merge', 'Unir'),
    );
    if (!ok) return;
  }
  final name = p.basename(folder).isEmpty ? folder : p.basename(folder);
  switch (await GoatApps.mergeFolder(folder)) {
    case HandoffResult.sent:
      say(tr(
          'Папка «$name» передана в Goat Archive. Там её можно оставить «Как есть» или разложить по темам; слияние начнётся, только когда вы нажмёте «Начать».',
          'Folder “$name” was handed to Goat Archive. There you can keep it “As is” or have it sorted; merging starts only when you press “Start”.',
          'La carpeta «$name» se pasó a Goat Archive. Allí puedes dejarla «Tal cual» o clasificarla; la unión empieza solo cuando pulses «Empezar».'));
    case HandoffResult.notInstalled:
      say(_notInstalledText());
    case HandoffResult.failed:
      say(tr('Не удалось передать папку в Goat Archive.',
          'Could not hand the folder to Goat Archive.',
          'No se pudo pasar la carpeta a Goat Archive.'));
  }
}

/// «Открыть Goat Archive».
Future<void> openGoatArchive(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final r = await GoatApps.openArchive();
  if (r == HandoffResult.sent) return;
  messenger.showSnackBar(SnackBar(
      content: Text(r == HandoffResult.notInstalled
          ? _notInstalledText()
          : tr('Не удалось открыть Goat Archive.', 'Could not open Goat Archive.',
              'No se pudo abrir Goat Archive.'))));
}

/// Итог импорта индекса — одной строкой для строки состояния/всплывашки.
String archiveReportText(ArchiveImportReport r) {
  if (r.ok) {
    final parts = [
      tr('файлов — ${r.files}', '${r.files} files', '${r.files} archivos'),
      tr('с тегами — ${r.taggedFiles}', '${r.taggedFiles} tagged',
          '${r.taggedFiles} con etiquetas'),
      if (r.withArtist > 0)
        tr('с автором — ${r.withArtist}', '${r.withArtist} with an artist',
            '${r.withArtist} con autor'),
      tr('серий — ${r.series}', '${r.series} series', '${r.series} series'),
    ];
    return '${tr('Из Goat Archive получено', 'Received from Goat Archive', 'Recibido de Goat Archive')}: ${parts.join(', ')}.';
  }
  switch (r.error) {
    case 'no-index':
      return tr(
          'Goat Archive ещё не передал галерее теги, авторов и серии — это произойдёт после первого слияния.',
          'Goat Archive has not handed over tags, artists and series yet — it will after the first merge.',
          'Goat Archive aún no ha pasado etiquetas, autores y series: lo hará tras la primera unión.');
    case 'busy':
      return tr(
          'Goat Archive сейчас обновляет данные библиотеки — попробуйте чуть позже.',
          'Goat Archive is updating the library data right now — try again shortly.',
          'Goat Archive está actualizando los datos de la biblioteca: inténtalo en un momento.');
    case 'bad-index':
      return tr(
          'Данные библиотеки записаны более новым Goat Archive — обновите галерею.',
          'The library data was written by a newer Goat Archive — update the gallery.',
          'Los datos de la biblioteca son de un Goat Archive más nuevo: actualiza la galería.');
    default:
      return tr('Не удалось получить данные из Goat Archive.',
          'Could not get the data from Goat Archive.',
          'No se pudieron obtener los datos de Goat Archive.');
  }
}

/// Открыть страницу-источник картинки в браузере. Только http/https — адрес
/// приходит из файла индекса, ничего другого по нему не запускаем.
Future<bool> openSourceUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return false;
  }
  if (uri.host.isEmpty) return false;
  final text = uri.toString();
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', text]);
    } else if (Platform.isAndroid) {
      await AndroidIntent(action: 'action_view', data: text).launch();
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [text]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [text]);
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Можно ли открыть [url] как страницу-источник.
bool isOpenableSourceUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// Что Goat Archive знает о файле — для панели сведений в просмотрщике: автор,
/// страница-источник (ссылкой), серия и номер страницы. Пусто, если файл не из
/// библиотеки или сортировщик ничего о нём не сообщил.
class ArchiveInfoSection extends StatelessWidget {
  final String path;
  const ArchiveInfoSection({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    final info = TagService.instance.archiveInfo(path);
    if (info == null) return const SizedBox.shrink();
    final series = info.seriesId == null
        ? null
        : CollectionsService.instance.archiveSeriesOf(path);
    final url = info.sourceUrl;
    final canOpen = url != null && isOpenableSourceUrl(url);
    final hasAny = (info.artist != null && info.artist!.isNotEmpty) ||
        url != null ||
        series != null;
    if (!hasAny) return const SizedBox.shrink();
    final c = AuroraTheme.of(context).colors;
    Widget row(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 78,
                child: Text(k,
                    style: TextStyle(color: c.muted, fontSize: 13))),
            Expanded(child: v),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 6),
      Row(children: [
        GxIcon(GxGlyph.archive, color: c.current, size: 14),
        const SizedBox(width: 6),
        Text('Goat Archive',
            style: TextStyle(
                color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
      if (info.artist != null && info.artist!.isNotEmpty)
        row(
            tr('Автор', 'Artist', 'Autor'),
            Text(info.artist!,
                style: TextStyle(
                    color: c.text, fontSize: 13, fontWeight: FontWeight.w500))),
      if (url != null)
        row(
            tr('Источник', 'Source', 'Origen'),
            InkWell(
              onTap: canOpen ? () => openSourceUrl(url) : null,
              child: Row(children: [
                Expanded(
                  child: Text(url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: canOpen ? c.accent : c.text,
                          fontSize: 12.5,
                          decoration: canOpen
                              ? TextDecoration.underline
                              : TextDecoration.none)),
                ),
                if (canOpen) ...[
                  const SizedBox(width: 6),
                  GxIcon(GxGlyph.openExt, color: c.accent, size: 14),
                ],
              ]),
            )),
      if (series != null)
        row(
            tr('Серия', 'Series', 'Serie'),
            Text(
                '${series.name} · ${tr('стр.', 'page', 'pág.')} ${series.page} ${tr('из', 'of', 'de')} ${series.pages}',
                style: TextStyle(color: c.text, fontSize: 13))),
      const SizedBox(height: 4),
      GxHLine(color: c.rowLine),
    ]);
  }
}
