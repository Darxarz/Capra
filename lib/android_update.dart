import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:goat_update/goat_update.dart';

import 'error_log.dart';
import 'i18n.dart';
import 'theme.dart';
import 'update_download.dart';
import 'update_service.dart';

/// Self-update on the tablet: GOAT.apk from the release goes to files/goat_update/,
/// then to the system installer, which asks the owner to confirm and refuses
/// anything not signed with the same key.
class AndroidUpdater {
  final GoatUpdateApi api;
  AndroidUpdater(this.api);

  static final AndroidUpdater instance = AndroidUpdater(MethodChannelGoatUpdate());

  Future<Directory> dir() async => Directory(await api.updateDir());

  /// Tidies the download folder after a check: the installed build's APK and
  /// stale releases go; an unfinished newer one stays when the check failed.
  Future<void> tidy(UpdateCheck check) async {
    try {
      final known = check.status == UpdateCheckStatus.available ||
          check.status == UpdateCheckStatus.upToDate;
      await cleanUpdateDir(
          await dir(),
          (b) => keepUpdateFile(b,
              current: kBuildNumber,
              offered: check.info?.build,
              latestKnown: known));
    } catch (e, s) {
      ErrorLog.recordError(e, s);
    }
  }
}

String _mb(int bytes) => (bytes / (1024 * 1024)).ceil().toString();

/// Plain words for a stopped download.
String downloadFailureText(DownloadFailure f) {
  switch (f.kind) {
    case DownloadFailureKind.offline:
    case DownloadFailureKind.timeout:
      return tr(
          'Нет связи с интернетом. Скачанное сохранится — в следующий раз продолжим с того же места.',
          'No internet connection. What has been downloaded is kept and will continue next time.',
          'Sin conexión a internet. Lo descargado se guarda y continuará la próxima vez.');
    case DownloadFailureKind.server:
      return tr(
          'GitHub сейчас не отдаёт файл${f.status == null ? '' : ' (код ${f.status})'}. Попробуйте позже.',
          'GitHub is not serving the file right now${f.status == null ? '' : ' (code ${f.status})'}. Try again later.',
          'GitHub no entrega el archivo ahora${f.status == null ? '' : ' (código ${f.status})'}. Inténtalo más tarde.');
    case DownloadFailureKind.noSpace:
      return tr(
          'На планшете закончилось место. Освободите место и попробуйте снова.',
          'The device ran out of space. Free some space and try again.',
          'El dispositivo se quedó sin espacio. Libera espacio e inténtalo de nuevo.');
    case DownloadFailureKind.corrupt:
      return tr(
          'Файл пришёл с ошибкой. В следующий раз он скачается заново.',
          'The file arrived damaged. It will be downloaded again next time.',
          'El archivo llegó dañado. Se descargará de nuevo la próxima vez.');
    case DownloadFailureKind.insecure:
      return tr(
          'Ссылка на обновление не защищена (не HTTPS) — скачивать не будем.',
          'The update link is not secure (not HTTPS), so it was not downloaded.',
          'El enlace de la actualización no es seguro (no es HTTPS); no se descargó.');
    case DownloadFailureKind.canceled:
      return tr('Скачивание остановлено.', 'Download stopped.', 'Descarga detenida.');
  }
}

/// Why the downloaded APK will not go to the installer; null when it may.
String? apkProblem(ApkFacts f) {
  if (!f.readable) {
    return tr('Android не смог прочитать скачанный файл.',
        'Android could not read the downloaded file.',
        'Android no pudo leer el archivo descargado.');
  }
  if (f.package != f.ownPackage) {
    return tr('Скачанный файл — не обновление GOAT, ставить его не будем.',
        'The downloaded file is not a GOAT update, so it will not be installed.',
        'El archivo descargado no es una actualización de GOAT; no se instalará.');
  }
  if (f.versionCode < f.installedVersionCode) {
    return tr(
        'В скачанном файле версия старее установленной — Android её не примет.',
        'The downloaded file is older than the installed version, so Android will not accept it.',
        'El archivo descargado es más antiguo que la versión instalada; Android no lo aceptará.');
  }
  if (f.sameSigner == false) {
    return tr(
        'Обновление подписано другим ключом, и Android его не установит.',
        'The update is signed with a different key, so Android will not install it.',
        'La actualización está firmada con otra clave; Android no la instalará.');
  }
  return null;
}

enum _Phase { permission, preparing, downloading, checking, installer, finished }

/// The whole tablet update in one dialog: permission, download with progress
/// and Cancel, then the system installer.
class AndroidUpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  final AndroidUpdater updater;

  /// Tests serve the file from a local http server. The app never sets this;
  /// outside tests only the debug/profile override ([updateTestOverride]) allows http.
  @visibleForTesting
  final bool allowPlainHttp;
  const AndroidUpdateDialog(
      {super.key, required this.info, required this.updater, this.allowPlainHttp = false});

  @override
  State<AndroidUpdateDialog> createState() => _AndroidUpdateDialogState();
}

class _AndroidUpdateDialogState extends State<AndroidUpdateDialog>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.preparing;
  bool _askedOnce = false; // the settings page was opened and the switch is still off
  int _done = 0;
  int _total = 0;
  String? _message; // final words for [_Phase.finished]
  bool _failed = false;
  bool _running = false;
  DownloadCancel? _cancel;

  GoatUpdateApi get _api => widget.updater.api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _total = widget.info.size;
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel();
    super.dispose();
  }

  /// Back from the settings page by any route: carry on if the switch is on now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _phase != _Phase.permission) return;
    unawaited(() async {
      if (await _api.canInstall() && mounted && _phase == _Phase.permission) {
        unawaited(_download());
      }
    }());
  }

  void _finish(String message, {bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.finished;
      _message = message;
      _failed = failed;
    });
  }

  Future<void> _start() async {
    try {
      if (!await _api.canInstall()) {
        if (mounted) setState(() => _phase = _Phase.permission);
        return;
      }
    } catch (e, s) {
      ErrorLog.recordError(e, s);
    }
    await _download();
  }

  Future<void> _openSettings() async {
    bool granted;
    try {
      granted = await _api.openInstallSettings();
    } catch (e, s) {
      ErrorLog.recordError(e, s);
      _finish(
          tr('Не получилось открыть настройки Android.',
              'Could not open Android settings.',
              'No se pudieron abrir los ajustes de Android.'),
          failed: true);
      return;
    }
    if (!mounted || _phase != _Phase.permission) return;
    if (granted) {
      await _download();
    } else {
      setState(() => _askedOnce = true);
    }
  }

  Future<void> _download() async {
    if (_running) return;
    _running = true;
    final info = widget.info;
    setState(() => _phase = _Phase.preparing);
    try {
      final dir = await widget.updater.dir();
      final have = updateBytesOnDisk(dir, info.build, info.size);
      final need = updateSpaceNeeded(info.size, have);
      final free = await _api.freeSpace();
      if (need > 0 && free > 0 && free < need) {
        _finish(
            tr(
                'Не хватает места: освободите ещё около ${_mb(need - free)} МБ и нажмите «Обновить» снова.',
                'Not enough space: free about ${_mb(need - free)} MB more and tap Update again.',
                'No hay espacio: libera unos ${_mb(need - free)} MB más y pulsa Actualizar de nuevo.'),
            failed: true);
        return;
      }
      if (!mounted) return;
      final cancel = _cancel = DownloadCancel();
      setState(() {
        _phase = _Phase.downloading;
        _done = have;
      });
      final file = await ResumableDownload.fetch(
        url: Uri.parse(info.downloadUrl),
        dir: dir,
        build: info.build,
        size: info.size,
        sha256: info.sha256,
        allowHttp: updateTestOverride || widget.allowPlainHttp,
        cancel: cancel,
        onProgress: (d, t) {
          if (mounted) {
            setState(() {
              _done = d;
              if (t > 0) _total = t;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.checking);
      final facts = await _api.inspect(file.path);
      final problem = apkProblem(facts);
      if (problem != null) {
        await file.delete().catchError((_) => file);
        _finish(problem, failed: true);
        return;
      }
      if (!mounted) return;
      setState(() => _phase = _Phase.installer);
      final outcome = await _api.install(file.path);
      switch (outcome) {
        case InstallOutcome.installed:
          _finish(tr('Обновление установлено.', 'Update installed.',
              'Actualización instalada.'));
        case InstallOutcome.opened:
          _finish(tr(
              'Подтвердите установку в окне Android.',
              'Confirm the installation in the Android window.',
              'Confirma la instalación en la ventana de Android.'));
        case InstallOutcome.canceled:
          _finish(tr(
              'Установка отменена. Обновление уже скачано — нажмите «Обновить», когда будете готовы.',
              'Installation canceled. The update is already downloaded — tap Update when you are ready.',
              'Instalación cancelada. La actualización ya está descargada: pulsa Actualizar cuando quieras.'));
        case InstallOutcome.failed:
          await file.delete().catchError((_) => file);
          _finish(
              tr('Android не установил обновление.',
                  'Android did not install the update.',
                  'Android no instaló la actualización.'),
              failed: true);
      }
    } on DownloadFailure catch (f) {
      if (f.kind == DownloadFailureKind.canceled) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      _finish(downloadFailureText(f), failed: true);
    } catch (e, s) {
      ErrorLog.recordError(e, s);
      _finish(
          tr('Не удалось обновить: $e', 'Could not update: $e',
              'No se pudo actualizar: $e'),
          failed: true);
    } finally {
      _running = false;
      _cancel = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final muted = TextStyle(color: c.muted);
    final small = TextStyle(color: c.muted, fontSize: 12);

    String title;
    Widget body;
    List<Widget> actions;
    switch (_phase) {
      case _Phase.permission:
        title = tr('Нужно одно разрешение', 'One permission needed',
            'Hace falta un permiso');
        body = Text(
          _askedOnce
              ? tr(
                  'Переключатель «Разрешить установку» для GOAT пока выключен — без него Android не даст обновиться.',
                  'The “Allow from this source” switch for GOAT is still off — Android will not update without it.',
                  'El interruptor «Permitir de esta fuente» de GOAT sigue apagado; sin él Android no actualizará.')
              : tr(
                  'Android попросит разрешить GOAT устанавливать обновления: включите переключатель и вернитесь назад.',
                  'Android will ask you to let GOAT install updates: turn the switch on and come back.',
                  'Android pedirá permitir que GOAT instale actualizaciones: activa el interruptor y vuelve.'),
          style: muted,
        );
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Позже', 'Later', 'Más tarde'), style: muted),
          ),
          FilledButton(
            onPressed: _openSettings,
            child: Text(tr('Открыть настройки', 'Open settings', 'Abrir ajustes')),
          ),
        ];
      case _Phase.preparing:
      case _Phase.downloading:
      case _Phase.checking:
      case _Phase.installer:
        title = tr('Обновление…', 'Updating…', 'Actualizando…');
        final fraction = _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null;
        final String line;
        switch (_phase) {
          case _Phase.downloading:
            line = fraction == null
                ? tr('Скачивание…', 'Downloading…', 'Descargando…')
                : '${tr('Скачивание', 'Downloading', 'Descargando')} ${(fraction * 100).floor()}% · '
                    '${tr('${_mb(_done)} из ${_mb(_total)} МБ', '${_mb(_done)} of ${_mb(_total)} MB', '${_mb(_done)} de ${_mb(_total)} MB')}';
          case _Phase.checking:
            line = tr('Проверка файла…', 'Checking the file…', 'Comprobando el archivo…');
          case _Phase.installer:
            line = tr('Открываю установщик Android…', 'Opening the Android installer…',
                'Abriendo el instalador de Android…');
          default:
            line = tr('Подготовка…', 'Preparing…', 'Preparando…');
        }
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: _phase == _Phase.downloading ? fraction : null,
              color: c.accent,
              backgroundColor: c.surface2,
            ),
            const SizedBox(height: 12),
            Text(line, style: TextStyle(color: c.muted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
                tr(
                    'Android попросит подтвердить установку. Фото, теги и настройки сохранятся.',
                    'Android will ask you to confirm the installation. Photos, tags and settings stay.',
                    'Android pedirá confirmar la instalación. Fotos, etiquetas y ajustes se conservan.'),
                style: small),
          ],
        );
        actions = _phase == _Phase.downloading
            ? [
                TextButton(
                  onPressed: () => _cancel?.cancel(),
                  child: Text(tr('Отмена', 'Cancel', 'Cancelar'), style: muted),
                ),
              ]
            : const [];
      case _Phase.finished:
        title = _failed
            ? tr('Не удалось обновить', 'Could not update', 'No se pudo actualizar')
            : tr('Обновление', 'Update', 'Actualización');
        body = Text(_message ?? '', style: muted);
        actions = [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Закрыть', 'Close', 'Cerrar')),
          ),
        ];
    }
    return PopScope(
      canPop: _phase == _Phase.permission || _phase == _Phase.finished,
      child: AlertDialog(
        backgroundColor: c.surface,
        title: Text(title, style: TextStyle(color: c.text)),
        content: body,
        actions: actions.isEmpty ? null : actions,
      ),
    );
  }
}
