import 'dart:io';
import 'model.dart';

/// Узел древа папок: сама папка + её подпапки + фото, лежащие прямо в ней.
class FolderNode {
  final String name; // имя папки (последний сегмент пути)
  final String path; // полный путь
  final List<FolderNode> children = [];
  final List<PhotoItem> directPhotos = []; // фото прямо в этой папке

  int directCount = 0; // сколько фото лежит прямо здесь
  int totalCount = 0; // сколько фото здесь и во всех вложенных
  PhotoItem? cover; // обложка (первое фото — своё или из вложенных)

  FolderNode({required this.name, required this.path});

  bool get hasChildren => children.isNotEmpty;
}

String _lastSegment(String path, String sep) {
  final trimmed =
      path.endsWith(sep) ? path.substring(0, path.length - 1) : path;
  final i = trimmed.lastIndexOf(sep);
  return i >= 0 ? trimmed.substring(i + 1) : trimmed;
}

/// Строит древо папок из плоского списка фото и пути корневой папки.
/// Промежуточные папки (без своих фото, но с вложенными) тоже становятся узлами.
FolderNode buildFolderTree(List<PhotoItem> photos, String rootPath) {
  final sep = Platform.pathSeparator;
  final root = rootPath.endsWith(sep)
      ? rootPath.substring(0, rootPath.length - 1)
      : rootPath;

  final rootNode = FolderNode(name: _lastSegment(root, sep), path: root);
  final map = <String, FolderNode>{root: rootNode};

  FolderNode ensure(String path) {
    final existing = map[path];
    if (existing != null) return existing;
    final cut = path.lastIndexOf(sep);
    final parentPath = cut > 0 ? path.substring(0, cut) : root;
    final parent = ensure(parentPath);
    final node = FolderNode(name: _lastSegment(path, sep), path: path);
    map[path] = node;
    parent.children.add(node);
    return node;
  }

  for (final p in photos) {
    var fp = p.folderPath;
    if (fp.endsWith(sep)) fp = fp.substring(0, fp.length - 1);
    if (fp != root && !fp.startsWith(root + sep)) continue; // вне корня — пропуск
    final node = fp == root ? rootNode : ensure(fp);
    node.directPhotos.add(p);
  }

  _aggregate(rootNode);
  return rootNode;
}

void _aggregate(FolderNode n) {
  n.directCount = n.directPhotos.length;
  var total = n.directCount;
  for (final ch in n.children) {
    _aggregate(ch);
    total += ch.totalCount;
  }
  n.totalCount = total;
  n.cover = n.directPhotos.isNotEmpty
      ? n.directPhotos.first
      : (n.children.isNotEmpty ? n.children.first.cover : null);
  // крупные ветви — выше
  n.children.sort((a, b) => b.totalCount.compareTo(a.totalCount));
}

/// Все фото папки и её вложенных (для входа в папку, когда своих фото нет).
List<PhotoItem> collectPhotos(FolderNode n) {
  final out = <PhotoItem>[...n.directPhotos];
  for (final ch in n.children) {
    out.addAll(collectPhotos(ch));
  }
  return out;
}
