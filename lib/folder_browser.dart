import 'dart:io';
import 'package:flutter/material.dart';
import 'theme.dart';

/// Простой обозреватель папок на dart:io (для Android, где системный диалог
/// отдаёт URI, а не путь). Возвращает выбранный путь к папке.
class FolderBrowserPage extends StatefulWidget {
  final String initialPath;
  const FolderBrowserPage({super.key, required this.initialPath});

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  late String _path = widget.initialPath;
  List<Directory> _dirs = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = <Directory>[];
      await for (final e in Directory(_path).list(followLinks: false)) {
        if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue; // скрытые пропускаем
          entries.add(e);
        }
      }
      entries.sort((a, b) =>
          a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _dirs = entries;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _error = 'Нет доступа к этой папке';
      });
    }
  }

  void _open(String p) {
    setState(() => _path = p);
    _load();
  }

  void _up() {
    final parent = Directory(_path).parent.path;
    if (parent != _path) _open(parent);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final name = _path.split(Platform.pathSeparator).last;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 14, 6),
              child: Row(children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close, color: c.text),
                  tooltip: 'Отмена',
                ),
                Expanded(
                  child: Text(name.isEmpty ? _path : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  onPressed: _up,
                  icon: Icon(Icons.arrow_upward, color: c.muted),
                  tooltip: 'Вверх',
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.muted, fontSize: 12)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: () => Navigator.pop(context, _path),
                icon: const Icon(Icons.check),
                label: const Text('Выбрать эту папку'),
              ),
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Text(_error!,
                          style: TextStyle(color: c.muted)))
                  : ListView.builder(
                      itemCount: _dirs.length,
                      itemBuilder: (ctx, i) {
                        final d = _dirs[i];
                        final n = d.path.split(Platform.pathSeparator).last;
                        return ListTile(
                          leading:
                              Icon(Icons.folder_rounded, color: c.accent),
                          title: Text(n, style: TextStyle(color: c.text)),
                          trailing: Icon(Icons.chevron_right, color: c.muted),
                          onTap: () => _open(d.path),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
