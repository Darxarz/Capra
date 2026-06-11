import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'theme.dart';
import 'folder_tree.dart';

enum TreeLayout { vertical, horizontal, radial }

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
        grid[n] =
            _GP((grid[kids.first]!.x + grid[kids.last]!.x) / 2, depth);
      }
    }

    rec(widget.root, 0);
    final leafCount = math.max(1, leaf);

    // размеры узла
    final nw = _layout == TreeLayout.radial ? 132.0 : 168.0;
    final nh = _layout == TreeLayout.radial ? 50.0 : 58.0;

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
      final rStep = nh + 70;
      final maxR = maxDepth * rStep;
      final cxy = maxR + nw / 2 + 30;
      grid.forEach((n, gp) {
        final ang = (gp.x / leafCount) * 2 * math.pi - math.pi / 2;
        final r = gp.depth * rStep;
        pos[n] = Offset(cxy + r * math.cos(ang), cxy + r * math.sin(ang));
      });
      w = 2 * cxy;
      h = 2 * cxy;
    }

    final edgeOffsets =
        edges.map((e) => [pos[e[0]]!, pos[e[1]]!]).toList(growable: false);

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
                    (_layout == TreeLayout.radial
                            ? cns.maxHeight / 2
                            : cns.maxHeight * 0.18) -
                        rootPos.dy,
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
                        painter: _BranchPainter(edgeOffsets, _layout, c.line),
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
    Widget seg(IconData icon, String tip, bool on, VoidCallback onTap) {
      return Tooltip(
        message: tip,
        child: Material(
          color: on ? c.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              child: Icon(icon, size: 18, color: on ? Colors.white : c.muted),
            ),
          ),
        ),
      );
    }

    Widget group(List<Widget> items) => Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: items),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          group([
            seg(Icons.account_tree_outlined, 'Вертикальное',
                _layout == TreeLayout.vertical, () => _setLayout(TreeLayout.vertical)),
            seg(Icons.lan_outlined, 'Горизонтальное',
                _layout == TreeLayout.horizontal,
                () => _setLayout(TreeLayout.horizontal)),
            seg(Icons.hub_outlined, 'Радиальное', _layout == TreeLayout.radial,
                () => _setLayout(TreeLayout.radial)),
          ]),
          const SizedBox(width: 10),
          group([
            seg(Icons.unfold_more, 'Развернуть всё', _mode == TreeMode.all,
                () => _setMode(TreeMode.all)),
            seg(Icons.touch_app_outlined, 'По нажатию',
                _mode == TreeMode.progressive,
                () => _setMode(TreeMode.progressive)),
          ]),
          const Spacer(),
          Text('${widget.root.totalCount} фото',
              style: TextStyle(color: c.muted, fontSize: 12)),
        ],
      ),
    );
  }

  void _openMenu(FolderNode n) {
    final c = AuroraTheme.of(context).colors;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        Widget tile(IconData icon, String label, VoidCallback onTap,
            {bool danger = false}) {
          final col = danger ? const Color(0xFFD85A30) : c.text;
          return ListTile(
            leading: Icon(icon, color: col, size: 20),
            title: Text(label, style: TextStyle(color: col)),
            onTap: () {
              Navigator.pop(ctx);
              onTap();
            },
          );
        }

        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(children: [
                Icon(Icons.folder_rounded, color: c.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(n.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ),
                Text('${n.totalCount} фото',
                    style: TextStyle(color: c.muted, fontSize: 12)),
              ]),
            ),
            const Divider(height: 1),
            tile(Icons.open_in_full, 'Открыть', () => widget.onOpenFolder(n)),
            tile(Icons.drive_file_rename_outline, 'Переименовать',
                () => _soon('Переименование')),
            tile(Icons.drive_file_move_outline, 'Переместить',
                () => _soon('Перемещение')),
            tile(Icons.content_copy, 'Копировать', () => _soon('Копирование')),
            tile(Icons.delete_outline, 'Удалить в корзину',
                () => _soon('Удаление'),
                danger: true),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
  }

  void _soon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what папок — добавим следующим шагом')),
    );
  }
}

class _GP {
  final double x;
  final int depth;
  const _GP(this.x, this.depth);
}

class _BranchPainter extends CustomPainter {
  final List<List<Offset>> edges;
  final TreeLayout layout;
  final Color color;
  _BranchPainter(this.edges, this.layout, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (final e in edges) {
      final a = e[0], b = e[1];
      final path = Path()..moveTo(a.dx, a.dy);
      if (layout == TreeLayout.vertical) {
        final my = (a.dy + b.dy) / 2;
        path.cubicTo(a.dx, my, b.dx, my, b.dx, b.dy);
      } else if (layout == TreeLayout.horizontal) {
        final mx = (a.dx + b.dx) / 2;
        path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
      } else {
        path.lineTo(b.dx, b.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BranchPainter old) =>
      old.edges != edges || old.layout != layout || old.color != color;
}

class _NodeCard extends StatelessWidget {
  final FolderNode node;
  final AuroraColors colors;
  final bool isRoot;
  final bool expanded;
  final bool showToggle;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onMenu;
  const _NodeCard({
    required this.node,
    required this.colors,
    required this.isRoot,
    required this.expanded,
    required this.showToggle,
    required this.onTap,
    required this.onToggle,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cover = node.cover;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onMenu,
      onSecondaryTap: onMenu,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
              color: isRoot ? c.accent : c.line, width: isRoot ? 2 : 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 42,
                height: 42,
                child: cover != null
                    ? Image(
                        image: cover.thumb((42 * dpr).round().clamp(64, 256)),
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (ctx, e, s) => Container(
                            color: c.surface2,
                            child: Icon(Icons.folder_rounded,
                                color: c.muted, size: 18)),
                      )
                    : Container(
                        color: c.surface2,
                        child:
                            Icon(Icons.folder_rounded, color: c.muted, size: 18),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                      node.hasChildren
                          ? '${node.totalCount} фото · ${node.children.length} папок'
                          : '${node.directCount} фото',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 11)),
                ],
              ),
            ),
            if (showToggle)
              GestureDetector(
                onTap: onToggle,
                child: Container(
                  margin: const EdgeInsets.only(left: 2),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(expanded ? Icons.remove : Icons.add,
                      color: Colors.white, size: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
