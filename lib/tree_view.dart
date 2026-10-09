import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'theme.dart';
import 'gx.dart';
import 'folder_tree.dart';
import 'i18n.dart';

// Свои значки дерева — в том же начертании, что и в gx.dart.
const _gPlay = GxGlyph('M8 5.5v13l10.5-6.5z', true);
const _gMinus = GxGlyph('M5 12h14');
const _gLayoutV = GxGlyph(
    'M9 3.5h6v4H9zM12 7.5v3M6 10.5h12M6 10.5v3M18 10.5v3M3.5 13.5h5v4h-5zM15.5 13.5h5v4h-5z');
const _gLayoutH = GxGlyph(
    'M3.5 9h4v6h-4zM7.5 12h3M10.5 6v12M10.5 6h3M10.5 18h3M13.5 3.5h6v5h-6zM13.5 15.5h6v5h-6z');
const _gCompact = GxGlyph(
    'M12 12V6.500M12 12l5.500 3.200M12 12l-5.500 3.200M13.500 4.500a1.500 1.500 0 1 1-3 0a1.500 1.500 0 0 1 3 0M20.500 16.500a1.500 1.500 0 1 1-3 0a1.500 1.500 0 0 1 3 0M6.500 16.500a1.500 1.500 0 1 1-3 0a1.500 1.500 0 0 1 3 0');
const _gExpandAll = GxGlyph('M7 9l5-4 5 4M7 15l5 4 5-4');
const _gOnTap = GxGlyph('M7 4.500l10.500 6.500-4.800 1.300L10.500 17.500z', true);

enum TreeLayout { vertical, horizontal, compact }

enum TreeMode { all, progressive }

/// Визуальное древо папок: вертикальное/горизонтальное/радиальное,
/// с раскрытием ветвей и входом в папку.
class TreeView extends StatefulWidget {
  final FolderNode root;
  final void Function(FolderNode node) onOpenFolder;
  const TreeView({super.key, required this.root, required this.onOpenFolder});

  @override
  State<TreeView> createState() => _TreeViewState();
}

class _TreeViewState extends State<TreeView> {
  TreeLayout _layout = TreeLayout.vertical;
  TreeMode _mode = TreeMode.progressive;
  final Set<String> _expanded = {};
  final TransformationController _tc = TransformationController();
  bool _centered = false;

  @override
  void initState() {
    super.initState();
    _expanded.add(widget.root.path); // корень раскрыт → виден первый уровень
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  bool _isExpanded(FolderNode n) =>
      _mode == TreeMode.all || _expanded.contains(n.path);

  void _onTapNode(FolderNode n) {
    if (n.hasChildren && !_isExpanded(n)) {
      setState(() => _expanded.add(n.path));
    } else {
      widget.onOpenFolder(n);
    }
  }

  void _toggle(FolderNode n) {
    setState(() {
      if (_expanded.contains(n.path)) {
        _collapse(n);
      } else {
        _expanded.add(n.path);
      }
    });
  }

  void _collapse(FolderNode n) {
    _expanded.remove(n.path);
    for (final ch in n.children) {
      _collapse(ch);
    }
  }

  void _setLayout(TreeLayout l) => setState(() {
        _layout = l;
        _centered = false;
      });

  void _setMode(TreeMode m) => setState(() {
        _mode = m;
        _centered = false;
      });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;

    final grid = <FolderNode, _GP>{};
    final edges = <List<FolderNode>>[];
    int leaf = 0;
    int maxDepth = 0;

    void rec(FolderNode n, int depth) {
      if (depth > maxDepth) maxDepth = depth;
      final kids = _isExpanded(n) ? n.children : const <FolderNode>[];
      if (kids.isEmpty) {
        grid[n] = _GP(leaf.toDouble(), depth);
        leaf += 1;
      } else {
        for (final ch in kids) {
          edges.add([n, ch]);
          rec(ch, depth + 1);
        }
        grid[n] = _GP((grid[kids.first]!.x + grid[kids.last]!.x) / 2, depth);
      }
    }

    rec(widget.root, 0);
    final leafCount = math.max(1, leaf);

    // размеры узла: квадратная обложка сверху + подпись снизу
    final compact = _layout == TreeLayout.compact;
    final nw = compact ? 78.0 : 92.0;
    final nh = nw + (compact ? 40.0 : 44.0);

    final pos = <FolderNode, Offset>{};
    double w, h;
    if (_layout == TreeLayout.vertical) {
      final xGap = nw + 24, yGap = nh + 58, m = nw / 2 + 24;
      grid.forEach((n, gp) {
        pos[n] = Offset(m + gp.x * xGap, nh / 2 + 26 + gp.depth * yGap);
      });
      w = m + (leafCount - 1) * xGap + nw / 2 + 24;
      h = nh + 52 + maxDepth * yGap;
    } else if (_layout == TreeLayout.horizontal) {
      final xGap = nw + 70, yGap = nh + 20, m = nh / 2 + 24;
      grid.forEach((n, gp) {
        pos[n] = Offset(nw / 2 + 24 + gp.depth * xGap, m + gp.x * yGap);
      });
      w = nw + 52 + maxDepth * xGap;
      h = m + (leafCount - 1) * yGap + nh / 2 + 24;
    } else {
      // компактная упаковка: каждое поддерево — плотный блок. Дети узла
      // укладываются тесной сеткой прямо под ним, поэтому папки с кучей
      // подпапок собираются в компактную кучку, а не разлетаются.
      const padX = 14.0, padY = 18.0;
      final sizeOf = <FolderNode, Size>{}; // размер блока поддерева

      // целевая ширина строки для упаковки детей (≈ квадратный блок)
      double targetWidth(List<FolderNode> kids) {
        var maxW = 0.0, area = 0.0;
        for (final k in kids) {
          final s = sizeOf[k]!;
          if (s.width > maxW) maxW = s.width;
          area += s.width * s.height;
        }
        return math.max(maxW, math.sqrt(area) * 1.3);
      }

      Size measure(FolderNode n) {
        final kids = _isExpanded(n) ? n.children : const <FolderNode>[];
        if (kids.isEmpty) return sizeOf[n] = Size(nw, nh);
        for (final k in kids) {
          measure(k);
        }
        // упаковка «полками»: каждый блок берёт свою ширину, перенос по targetW
        final targetW = targetWidth(kids);
        var x = 0.0, y = 0.0, rowH = 0.0, usedW = 0.0;
        for (final k in kids) {
          final s = sizeOf[k]!;
          if (x > 0 && x + s.width > targetW + 0.01) {
            x = 0;
            y += rowH + padY;
            rowH = 0;
          }
          x += s.width + padX;
          if (x - padX > usedW) usedW = x - padX;
          if (s.height > rowH) rowH = s.height;
        }
        return sizeOf[n] = Size(math.max(usedW, nw), nh + padY + y + rowH);
      }

      void layoutBlock(FolderNode n, Offset origin) {
        final block = sizeOf[n]!;
        // собственная плитка — по центру сверху блока
        pos[n] = Offset(origin.dx + block.width / 2, origin.dy + nh / 2);
        final kids = _isExpanded(n) ? n.children : const <FolderNode>[];
        if (kids.isEmpty) return;
        final targetW = targetWidth(kids);
        // прогон для ширины сетки (центрирование)
        var x = 0.0, y = 0.0, rowH = 0.0, usedW = 0.0;
        for (final k in kids) {
          final s = sizeOf[k]!;
          if (x > 0 && x + s.width > targetW + 0.01) {
            x = 0;
            y += rowH + padY;
            rowH = 0;
          }
          x += s.width + padX;
          if (x - padX > usedW) usedW = x - padX;
          if (s.height > rowH) rowH = s.height;
        }
        final startX = origin.dx + (block.width - usedW) / 2;
        final startY = origin.dy + nh + padY;
        // расстановка детей теми же полками
        x = 0;
        y = 0;
        rowH = 0;
        for (final k in kids) {
          final s = sizeOf[k]!;
          if (x > 0 && x + s.width > targetW + 0.01) {
            x = 0;
            y += rowH + padY;
            rowH = 0;
          }
          layoutBlock(k, Offset(startX + x, startY + y));
          x += s.width + padX;
          if (s.height > rowH) rowH = s.height;
        }
      }

      measure(widget.root);
      layoutBlock(widget.root, const Offset(40, 40));
      w = sizeOf[widget.root]!.width + 80;
      h = sizeOf[widget.root]!.height + 80;
    }

    final connByParent = <FolderNode, List<Offset>>{};
    for (final e in edges) {
      connByParent.putIfAbsent(e[0], () => []).add(pos[e[1]]!);
    }
    final conns = connByParent.entries
        .map((en) => _Conn(pos[en.key]!, en.value))
        .toList(growable: false);

    final rootPos = pos[widget.root] ?? Offset(w / 2, h / 2);

    return Column(
      children: [
        _controls(c),
        Expanded(
          child: LayoutBuilder(builder: (ctx, cns) {
            if (!_centered) {
              _centered = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _tc.value = Matrix4.identity()
                  ..translateByDouble(
                    cns.maxWidth / 2 - rootPos.dx,
                    cns.maxHeight * 0.18 - rootPos.dy,
                    0,
                    1,
                  );
              });
            }
            return InteractiveViewer(
              transformationController: _tc,
              constrained: false,
              minScale: 0.25,
              maxScale: 3,
              boundaryMargin: const EdgeInsets.all(600),
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _BranchPainter(
                          conns,
                          _layout,
                          c.dim,
                        ),
                      ),
                    ),
                    for (final entry in pos.entries)
                      Positioned(
                        left: entry.value.dx - nw / 2,
                        top: entry.value.dy - nh / 2,
                        width: nw,
                        height: nh,
                        child: _NodeCard(
                          node: entry.key,
                          colors: c,
                          isRoot: entry.key == widget.root,
                          expanded: _expanded.contains(entry.key.path),
                          showToggle: _mode == TreeMode.progressive &&
                              entry.key.hasChildren,
                          coverSide: nw,
                          onTap: () => _onTapNode(entry.key),
                          onToggle: () => _toggle(entry.key),
                          onMenu: () => _openMenu(entry.key),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _controls(AuroraColors c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              GxSegments<TreeLayout>(
                value: _layout,
                onChanged: _setLayout,
                items: [
                  (
                    TreeLayout.vertical,
                    _gLayoutV,
                    tr('Вертикальное', 'Vertical', 'Vertical')
                  ),
                  (
                    TreeLayout.horizontal,
                    _gLayoutH,
                    tr('Горизонтальное', 'Horizontal', 'Horizontal')
                  ),
                  (
                    TreeLayout.compact,
                    _gCompact,
                    tr('Компактное', 'Compact', 'Compacto')
                  ),
                ],
              ),
              const SizedBox(width: 10),
              GxSegments<TreeMode>(
                value: _mode,
                onChanged: _setMode,
                items: [
                  (
                    TreeMode.all,
                    _gExpandAll,
                    tr('Развернуть всё', 'Expand all', 'Expandir todo')
                  ),
                  (
                    TreeMode.progressive,
                    _gOnTap,
                    tr('По нажатию', 'On tap', 'Al tocar')
                  ),
                ],
              ),
              const Spacer(),
              Text('${widget.root.totalCount} ${tr('фото', 'photos', 'fotos')}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
            ],
          ),
        ),
        const GxHLine(),
      ],
    );
  }

  void _openMenu(FolderNode n) {
    final c = AuroraTheme.of(context).colors;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget tile(GxGlyph glyph, String label, VoidCallback onTap,
            {bool danger = false}) {
          final col = danger ? c.danger : c.text;
          return InkWell(
            onTap: () {
              Navigator.pop(ctx);
              onTap();
            },
            child: SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  GxIcon(glyph, color: danger ? c.danger : c.muted, size: 18),
                  const SizedBox(width: 12),
                  Text(label, style: TextStyle(color: col, fontSize: 14)),
                ]),
              ),
            ),
          );
        }

        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  GxIcon(GxGlyph.folder, color: c.accent, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(n.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ),
                  Text('${n.totalCount} ${tr('фото', 'photos', 'fotos')}',
                      style: TextStyle(color: c.muted, fontSize: 12)),
                ]),
              ),
            ),
            const GxHLine(),
            tile(GxGlyph.folder, tr('Открыть', 'Open', 'Abrir'),
                () => widget.onOpenFolder(n)),
            tile(
                GxGlyph.pencil,
                tr('Переименовать', 'Rename', 'Renombrar'),
                () => _soon(tr('Переименование', 'Renaming', 'Renombrar'))),
            tile(
                GxGlyph.moveTo,
                tr('Переместить', 'Move', 'Mover'),
                () => _soon(tr('Перемещение', 'Moving', 'Mover'))),
            tile(GxGlyph.copy, tr('Копировать', 'Copy', 'Copiar'),
                () => _soon(tr('Копирование', 'Copying', 'Copiar'))),
            tile(
                GxGlyph.bin,
                tr('Удалить в корзину', 'Move to trash', 'Mover a la papelera'),
                () => _soon(tr('Удаление', 'Deleting', 'Eliminar')),
                danger: true),
            const SizedBox(height: 4),
          ]),
        );
      },
    );
  }

  void _soon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              '$what ${tr('папок — добавим следующим шагом', 'folders — coming in the next step', 'carpetas: llegará en el siguiente paso')}')),
    );
  }
}

class _GP {
  final double x;
  final int depth;
  const _GP(this.x, this.depth);
}

class _Conn {
  final Offset parent; // центр родителя
  final List<Offset> children; // центры детей (все на одной глубине)
  const _Conn(this.parent, this.children);
}

/// Рисует ветви тонкими линиями с прямыми углами (как генеалогическое древо):
/// от родителя вниз к «шине», по ней — к каждому ребёнку под углом 90°.
/// В радиальном режиме — прямые лучи наружу.
class _BranchPainter extends CustomPainter {
  final List<_Conn> conns;
  final TreeLayout layout;
  final Color color;
  _BranchPainter(this.conns, this.layout, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    for (final conn in conns) {
      final p = conn.parent;
      final kids = conn.children;
      if (kids.isEmpty) continue;

      if (layout == TreeLayout.vertical) {
        final busY = (p.dy + kids.first.dy) / 2;
        for (final k in kids) {
          final path = Path()
            ..moveTo(p.dx, p.dy)
            ..lineTo(p.dx, busY)
            ..lineTo(k.dx, busY)
            ..lineTo(k.dx, k.dy);
          canvas.drawPath(path, paint);
        }
      } else if (layout == TreeLayout.horizontal) {
        final busX = (p.dx + kids.first.dx) / 2;
        for (final k in kids) {
          final path = Path()
            ..moveTo(p.dx, p.dy)
            ..lineTo(busX, p.dy)
            ..lineTo(busX, k.dy)
            ..lineTo(k.dx, k.dy);
          canvas.drawPath(path, paint);
        }
      } else {
        for (final k in kids) {
          canvas.drawLine(p, k, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BranchPainter old) =>
      old.conns != conns || old.layout != layout || old.color != color;
}

class _NodeCard extends StatelessWidget {
  final FolderNode node;
  final AuroraColors colors;
  final bool isRoot;
  final bool expanded;
  final bool showToggle;
  final double coverSide;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onMenu;
  const _NodeCard({
    required this.node,
    required this.colors,
    required this.isRoot,
    required this.expanded,
    required this.showToggle,
    required this.coverSide,
    required this.onTap,
    required this.onToggle,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cover = node.cover;
    final small = coverSide < 80;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onMenu,
      onSecondaryTap: onMenu,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // квадратная обложка
          SizedBox(
            width: coverSide,
            height: coverSide,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: c.active,
                    borderRadius: gxCorner,
                    border: Border.all(color: isRoot ? c.accent : c.field),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: cover != null && cover.isVideo
                      ? Center(
                          child: Container(
                            width: 32,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: gxCorner,
                            ),
                            child: const GxIcon(_gPlay,
                                color: Colors.white, size: 18),
                          ),
                        )
                      : cover != null
                          ? Image(
                              image: cover.thumb(
                                  (coverSide * dpr).round().clamp(64, 512)),
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.low,
                              errorBuilder: (ctx, e, s) => Center(
                                  child: GxIcon(GxGlyph.folder,
                                      color: c.muted, size: 24)),
                            )
                          : Center(
                              child: GxIcon(GxGlyph.folder,
                                  color: c.muted, size: 24)),
                ),
                // счётчик фото в углу
                Positioned(
                  left: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text('${node.totalCount}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                // кнопка раскрыть/свернуть ветви
                if (showToggle)
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: GestureDetector(
                      onTap: onToggle,
                      child: Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: c.field),
                        ),
                        child: GxIcon(expanded ? _gMinus : GxGlyph.plus,
                            color: c.text, size: 14),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          // название под плиткой
          SizedBox(
            width: coverSide,
            child: Text(
              node.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: c.text,
                  fontSize: small ? 12 : 13,
                  fontWeight: FontWeight.w500),
            ),
          ),
          if (!small && node.hasChildren)
            SizedBox(
              width: coverSide,
              child: Text(
                '${node.children.length} ${tr('папок', 'folders', 'carpetas')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
