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

    // размеры узла: квадратная обложка сверху + подпись снизу
    final radial = _layout == TreeLayout.radial;
    final nw = radial ? 74.0 : 92.0;
    final nh = nw + (radial ? 40.0 : 44.0);

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
      // радиальная «гроздь» (balloon-раскладка): каждое поддерево — компактный
      // пузырь; плотные ветви собираются в кучки, как листья/виноград, без наложений
      final half = nw / 2;
      const gap = 16.0;
      final subR = <FolderNode, double>{}; // радиус пузыря поддерева
      final ringR = <FolderNode, double>{}; // на каком радиусе сидят дети

      double computeR(FolderNode n) {
        final kids = _isExpanded(n) ? n.children : const <FolderNode>[];
        if (kids.isEmpty) return subR[n] = half;
        var maxKid = 0.0;
        var circumference = 0.0;
        for (final k in kids) {
          final r = computeR(k);
          if (r > maxKid) maxKid = r;
          circumference += 2 * r + gap;
        }
        var rr = circumference / (2 * math.pi);
        final minRR = half + maxKid + gap;
        if (rr < minRR) rr = minRR;
        ringR[n] = rr;
        return subR[n] = rr + maxKid;
      }

      computeR(widget.root);

      void place(FolderNode n, Offset at, double awayAngle, bool isRoot) {
        pos[n] = at;
        final kids = _isExpanded(n) ? n.children : const <FolderNode>[];
        if (kids.isEmpty) return;
        final rr = ringR[n]!;
        var totalSpan = 0.0;
        for (final k in kids) {
          totalSpan += 2 * subR[k]! + gap;
        }
        // дети корня — по всему кругу; остальные — дугой на внешней стороне
        final arc = isRoot ? 2 * math.pi : math.pi * 1.5;
        final start = isRoot ? -math.pi / 2 : awayAngle - arc / 2;
        var acc = 0.0;
        for (final k in kids) {
          final span = 2 * subR[k]! + gap;
          final a = start + (acc + span / 2) / totalSpan * arc;
          acc += span;
          final kpos = at + Offset(rr * math.cos(a), rr * math.sin(a));
          place(k, kpos, a, false);
        }
      }

      place(widget.root, Offset.zero, -math.pi / 2, true);

      // сдвигаем всё в положительные координаты и считаем размер холста
      var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0;
      pos.forEach((n, o) {
        final r = subR[n]!;
        if (o.dx - r < minX) minX = o.dx - r;
        if (o.dy - r < minY) minY = o.dy - r;
        if (o.dx + r > maxX) maxX = o.dx + r;
        if (o.dy + r > maxY) maxY = o.dy + r;
      });
      final shift = Offset(-minX + 40, -minY + 40);
      for (final k in pos.keys.toList()) {
        pos[k] = pos[k]! + shift;
      }
      w = maxX - minX + 80;
      h = maxY - minY + 80;
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
                        painter: _BranchPainter(
                          conns,
                          _layout,
                          c.muted.withValues(alpha: 0.55),
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
      ..strokeWidth = 1.8
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
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                        color: isRoot ? c.accent : c.line,
                        width: isRoot ? 2.5 : 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: cover != null
                      ? Image(
                          image: cover
                              .thumb((coverSide * dpr).round().clamp(64, 512)),
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (ctx, e, s) =>
                              Icon(Icons.folder_rounded, color: c.muted, size: 26),
                        )
                      : Icon(Icons.folder_rounded, color: c.muted, size: 26),
                ),
                // счётчик фото в углу
                Positioned(
                  left: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
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
                        width: 25,
                        height: 25,
                        decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Icon(expanded ? Icons.remove : Icons.add,
                            color: Colors.white, size: 17),
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
                  fontSize: small ? 11.5 : 12.5,
                  fontWeight: FontWeight.w600),
            ),
          ),
          if (!small && node.hasChildren)
            SizedBox(
              width: coverSide,
              child: Text(
                '${node.children.length} папок',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, fontSize: 10.5),
              ),
            ),
        ],
      ),
    );
  }
}
