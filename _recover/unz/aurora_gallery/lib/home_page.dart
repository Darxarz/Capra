import 'package:flutter/material.dart';
import 'theme.dart';
import 'sample_data.dart';
import 'viewer_page.dart';

enum ViewMode { all, dates, albums }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ViewMode _mode = ViewMode.all;
  double _cell = 104; // плотность сетки: ширина плитки в пикселях

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Row(
          children: [
            _Rail(mode: _mode, onMode: (m) => setState(() => _mode = m)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    mode: _mode,
                    cell: _cell,
                    onMode: (m) => setState(() => _mode = m),
                    onCell: (v) => setState(() => _cell = v),
                  ),
                  _CountBar(mode: _mode),
                  Expanded(child: _body(c)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AuroraColors c) {
    switch (_mode) {
      case ViewMode.all:
        return _AllGrid(cell: _cell);
      case ViewMode.dates:
        return _DatesView(cell: _cell);
      case ViewMode.albums:
        return const _AlbumsView();
    }
  }
}

// ───────────────────────── боковая панель ─────────────────────────
class _Rail extends StatelessWidget {
  final ViewMode mode;
  final ValueChanged<ViewMode> onMode;
  const _Rail({required this.mode, required this.onMode});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget item(IconData icon, ViewMode? m, {VoidCallback? onTap}) {
      final on = m != null && m == mode;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Material(
          color: on ? c.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: onTap ?? (m == null ? null : () => onMode(m)),
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, size: 22, color: on ? c.accentInk : c.muted),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 74,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 14),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.auto_awesome_mosaic, size: 18, color: Colors.white),
          ),
          const SizedBox(height: 14),
          item(Icons.grid_view_rounded, ViewMode.all),
          item(Icons.calendar_today_rounded, ViewMode.dates),
          item(Icons.folder_rounded, ViewMode.albums),
          item(Icons.favorite_border_rounded, null, onTap: () {}),
          const Spacer(),
          item(Icons.settings_outlined, null, onTap: () {}),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// ───────────────────────── верхняя панель ─────────────────────────
class _TopBar extends StatelessWidget {
  final ViewMode mode;
  final double cell;
  final ValueChanged<ViewMode> onMode;
  final ValueChanged<double> onCell;
  const _TopBar({
    required this.mode,
    required this.cell,
    required this.onMode,
    required this.onCell,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: c.line),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 18, color: c.muted),
                  const SizedBox(width: 8),
                  Text('Поиск: теги, персонажи, авторы, цвета…',
                      style: TextStyle(color: c.muted, fontSize: 14)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _Tabs(mode: mode, onMode: onMode),
          const SizedBox(width: 12),
          Icon(Icons.grid_view, size: 16, color: c.muted),
          SizedBox(
            width: 110,
            child: Slider(
              value: cell,
              min: 60,
              max: 200,
              activeColor: c.accent,
              onChanged: onCell,
            ),
          ),
          const SizedBox(width: 4),
          const _ThemeDots(),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  final ViewMode mode;
  final ValueChanged<ViewMode> onMode;
  const _Tabs({required this.mode, required this.onMode});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget tab(String label, ViewMode m) {
      final on = m == mode;
      return GestureDetector(
        onTap: () => onMode(m),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: on ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: on ? c.text : c.muted,
              )),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.line),
      ),
      child: Row(children: [
        tab('Все', ViewMode.all),
        tab('По датам', ViewMode.dates),
        tab('Альбомы', ViewMode.albums),
      ]),
    );
  }
}

class _ThemeDots extends StatelessWidget {
  const _ThemeDots();

  @override
  Widget build(BuildContext context) {
    final theme = AuroraTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final t in kThemes)
          GestureDetector(
            onTap: () => theme.setTheme(t.id),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: t.accent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: t.id == theme.colors.id ? theme.colors.text : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CountBar extends StatelessWidget {
  final ViewMode mode;
  const _CountBar({required this.mode});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final right = switch (mode) {
      ViewMode.all => 'показаны 1–${kPhotos.length}',
      ViewMode.dates => 'сгруппировано по дате',
      ViewMode.albums => '${kAlbums.length} альбомов и папок',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(
                text: '102 480 ',
                style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 12)),
            TextSpan(
                text: 'изображений · 1 240 GIF',
                style: TextStyle(color: c.muted, fontSize: 12)),
          ])),
          Text(right, style: TextStyle(color: c.muted, fontSize: 12)),
        ],
      ),
    );
  }
}

// ───────────────────────── сетки ─────────────────────────
class PhotoTile extends StatelessWidget {
  final PhotoItem photo;
  final VoidCallback onTap;
  const PhotoTile({super.key, required this.photo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: c.surface2),
            Image.network(
              photo.url,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: (ctx, child, frame, wasSync) {
                if (wasSync || frame != null) return child;
                return Container(color: c.surface2);
              },
              errorBuilder: (ctx, e, s) =>
                  Icon(Icons.broken_image_outlined, color: c.muted, size: 18),
            ),
            if (photo.isGif)
              Positioned(
                right: 5,
                bottom: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('GIF',
                      style: TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AllGrid extends StatelessWidget {
  final double cell;
  const _AllGrid({required this.cell});

  @override
  Widget build(BuildContext context) {
    // GridView.builder создаёт только видимые плитки — поэтому сетка
    // одинаково лёгкая хоть на 300, хоть на 300 000 элементах.
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 18),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: cell,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: kPhotos.length,
      itemBuilder: (ctx, i) => PhotoTile(
        photo: kPhotos[i],
        onTap: () => _openViewer(ctx, i),
      ),
    );
  }
}

class _DatesView extends StatelessWidget {
  final double cell;
  const _DatesView({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    // группируем по дате с сохранением порядка
    final groups = <String, List<PhotoItem>>{};
    for (final p in kPhotos) {
      groups.putIfAbsent(p.dateGroup, () => []).add(p);
    }
    final slivers = <Widget>[];
    groups.forEach((date, items) {
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic, children: [
            Text(date,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(width: 10),
            Text('${items.length} фото', style: TextStyle(fontSize: 12, color: c.muted)),
          ]),
        ),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: cell,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => PhotoTile(
              photo: items[i],
              onTap: () => _openViewer(ctx, kPhotos.indexOf(items[i])),
            ),
            childCount: items.length,
          ),
        ),
      ));
    });
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    return CustomScrollView(slivers: slivers);
  }
}

class _AlbumsView extends StatelessWidget {
  const _AlbumsView();

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final groups = <String, List<AlbumItem>>{};
    for (final a in kAlbums) {
      groups.putIfAbsent(a.group, () => []).add(a);
    }
    final slivers = <Widget>[];
    groups.forEach((group, items) {
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text(group,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.muted)),
        ),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 190,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.82,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _AlbumCard(album: items[i]),
            childCount: items.length,
          ),
        ),
      ));
    });
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    return CustomScrollView(slivers: slivers);
  }
}

class _AlbumCard extends StatelessWidget {
  final AlbumItem album;
  const _AlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(fit: StackFit.expand, children: [
              Container(color: c.surface2),
              Image.network(albumCover(album.coverSeed), fit: BoxFit.cover),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.center,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${album.count}',
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Text(album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
        Text('${album.count} изображений',
            style: TextStyle(fontSize: 12, color: c.muted)),
      ],
    );
  }
}

void _openViewer(BuildContext context, int index) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ViewerPage(photos: kPhotos, initialIndex: index),
  ));
}
