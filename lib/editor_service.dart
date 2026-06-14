import 'dart:io';
import 'package:flutter/material.dart';

/// Найденный в системе графический редактор.
@immutable
class EditorApp {
  final String name; // «Krita», «Photoshop», …
  final String exePath; // полный путь к исполняемому файлу
  final String badge; // короткая метка для плашки («Kr», «Ps», …)
  final Color color; // фирменный цвет плашки
  const EditorApp({
    required this.name,
    required this.exePath,
    required this.badge,
    required this.color,
  });
}

/// Описание редактора, который ищем (имена exe + где искать).
class _Known {
  final String name;
  final String badge;
  final int color;
  final List<String> exeNames; // ключи App Paths / имена exe
  final List<String> fixedPaths; // конкретные пути-кандидаты
  final List<List<String>> globs; // [базовая папка, префикс подпапки, exe]
  const _Known(this.name, this.badge, this.color, this.exeNames,
      {this.fixedPaths = const [], this.globs = const []});
}

/// Обнаружение установленных редакторов и запуск файла в них.
class EditorService {
  static List<EditorApp>? _cache;

  static const _pf = r'C:\Program Files';
  static const _pf86 = r'C:\Program Files (x86)';

  static const List<_Known> _known = [
    _Known('Paint', 'Pnt', 0xFF2A7DE1, ['mspaint.exe'],
        fixedPaths: [r'C:\Windows\System32\mspaint.exe']),
    _Known('Krita', 'Kr', 0xFF3DAEE9, ['krita.exe'], fixedPaths: [
      '$_pf\\Krita (x64)\\bin\\krita.exe',
      '$_pf\\Krita\\bin\\krita.exe',
    ]),
    _Known('Photoshop', 'Ps', 0xFF31A8FF, ['Photoshop.exe'], globs: [
      ['$_pf\\Adobe', 'Adobe Photoshop', 'Photoshop.exe'],
    ]),
    _Known('GIMP', 'G', 0xFF5C5543, ['gimp-2.10.exe', 'gimp.exe'], globs: [
      ['$_pf\\GIMP 2\\bin', 'gimp', ''],
    ]),
    _Known('Paint.NET', 'PN', 0xFFB4151A, ['PaintDotNet.exe'],
        fixedPaths: ['$_pf\\paint.net\\paintdotnet.exe']),
    _Known('IrfanView', 'IV', 0xFF1C6FB8, ['i_view64.exe', 'i_view32.exe'],
        fixedPaths: [
          '$_pf\\IrfanView\\i_view64.exe',
          '$_pf86\\IrfanView\\i_view32.exe',
        ]),
    _Known('Affinity Photo', 'Af', 0xFF7E4DD2, ['Photo.exe'], globs: [
      ['$_pf\\Affinity', 'Photo', 'Photo.exe'],
    ]),
    _Known('Clip Studio', 'CSP', 0xFF1E1E1E, ['CLIPStudioPaint.exe'], globs: [
      ['$_pf\\CELSYS', 'CLIP STUDIO', 'CLIPStudioPaint.exe'],
    ]),
  ];

  /// Список найденных редакторов (кэшируется на сессию).
  static Future<List<EditorApp>> available() async {
    if (_cache != null) return _cache!;
    final found = <EditorApp>[];
    if (Platform.isWindows) {
      final appPaths = await _readAppPaths();
      for (final k in _known) {
        final path = _resolveWindows(k, appPaths);
        if (path != null) {
          found.add(EditorApp(
              name: k.name,
              exePath: path,
              badge: k.badge,
              color: Color(k.color)));
        }
      }
    } else if (Platform.isLinux) {
      const lin = [
        ('Krita', 'Kr', 0xFF3DAEE9, 'krita'),
        ('GIMP', 'G', 0xFF5C5543, 'gimp'),
        ('Inkscape', 'Ink', 0xFF000000, 'inkscape'),
        ('Pinta', 'Pt', 0xFF3465A4, 'pinta'),
      ];
      for (final (name, badge, color, cmd) in lin) {
        final p = await _which(cmd);
        if (p != null) {
          found.add(EditorApp(
              name: name, exePath: p, badge: badge, color: Color(color)));
        }
      }
    }
    _cache = found;
    return found;
  }

  /// Открыть [imagePath] в конкретном редакторе.
  static Future<void> openIn(EditorApp app, String imagePath) async {
    try {
      await Process.start(app.exePath, [imagePath], runInShell: false);
    } catch (_) {}
  }

  /// Системный диалог «Открыть с помощью…» (Windows).
  static Future<void> openWithDialog(String imagePath) async {
    try {
      if (Platform.isWindows) {
        await Process.start(
            'rundll32', ['shell32.dll,OpenAs_RunDLL', imagePath],
            runInShell: false);
      }
    } catch (_) {}
  }

  // ───────────────────────── Windows-обнаружение ─────────────────────────

  static String? _resolveWindows(_Known k, Map<String, String> appPaths) {
    // 1) реестр App Paths (по имени exe)
    for (final exe in k.exeNames) {
      final p = appPaths[exe.toLowerCase()];
      if (p != null && File(p).existsSync()) return p;
    }
    // 2) фиксированные пути
    for (final p in k.fixedPaths) {
      if (File(p).existsSync()) return p;
    }
    // 3) глоб: [базовая папка, префикс подпапки, exe]
    for (final g in k.globs) {
      final base = Directory(g[0]);
      if (!base.existsSync()) continue;
      // если базовая папка сразу содержит exe по префиксу (GIMP bin)
      if (g[2].isEmpty) {
        try {
          for (final e in base.listSync()) {
            if (e is File) {
              final n = e.path.split(Platform.pathSeparator).last.toLowerCase();
              if (n.startsWith(g[1].toLowerCase()) && n.endsWith('.exe')) {
                return e.path;
              }
            }
          }
        } catch (_) {}
        continue;
      }
      try {
        for (final e in base.listSync()) {
          if (e is Directory) {
            final n = e.path.split(Platform.pathSeparator).last;
            if (n.toLowerCase().startsWith(g[1].toLowerCase())) {
              final exe = '${e.path}${Platform.pathSeparator}${g[2]}';
              if (File(exe).existsSync()) return exe;
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Прочитать реестр App Paths → карта «имя_exe(lower) → полный путь».
  static Future<Map<String, String>> _readAppPaths() async {
    final out = <String, String>{};
    const root =
        r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';
    for (final hive in [
      root,
      r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
    ]) {
      try {
        final r = await Process.run('reg', ['query', hive, '/s'],
            runInShell: false);
        final text = (r.stdout ?? '').toString();
        String? curExe;
        for (final raw in text.split('\n')) {
          final line = raw.trimRight();
          final ki = line.toLowerCase().lastIndexOf('app paths\\');
          if (ki >= 0) {
            curExe = line.substring(ki + 'app paths\\'.length).trim().toLowerCase();
            continue;
          }
          if (curExe != null && line.contains('(Default)') &&
              line.contains('REG_SZ')) {
            final idx = line.indexOf('REG_SZ');
            var val = line.substring(idx + 'REG_SZ'.length).trim();
            val = val.replaceAll('"', '');
            if (val.isNotEmpty) out[curExe] = val;
          }
        }
      } catch (_) {}
    }
    return out;
  }

  static Future<String?> _which(String cmd) async {
    try {
      final r = await Process.run('which', [cmd]);
      final p = (r.stdout ?? '').toString().trim();
      return p.isNotEmpty ? p : null;
    } catch (_) {
      return null;
    }
  }
}
