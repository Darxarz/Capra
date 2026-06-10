import 'package:flutter/material.dart';
import 'theme.dart';
import 'model.dart';

/// Открыть просмотрщик на конкретном фото.
void openViewer(BuildContext context, List<PhotoItem> photos, int index) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ViewerPage(photos: photos, initialIndex: index),
  ));
}

class ViewerPage extends StatefulWidget {
  final List<PhotoItem> photos;
  final int initialIndex;
  const ViewerPage({super.key, required this.photos, required this.initialIndex});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final photo = widget.photos[_index];

    final stage = Stack(
      children: [
        Positioned.fill(
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (ctx, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: Image(
                  image: widget.photos[i].full,
                  fit: BoxFit.contain,
                  errorBuilder: (c2, e, s) =>
                      const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 14,
          left: 14,
          child: _RoundBtn(icon: Icons.close, onTap: () => Navigator.pop(context)),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: const Color(0xFF100D0B),
      body: SafeArea(
        child: LayoutBuilder(builder: (ctx, cns) {
          final wide = cns.maxWidth > 720;
          if (!wide) return stage;
          return Row(
            children: [
              Expanded(child: stage),
              SizedBox(width: 320, child: _InfoPanel(photo: photo, colors: c)),
            ],
          );
        }),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _InfoPanel({required this.photo, required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(k, style: TextStyle(color: c.muted, fontSize: 13)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ]),
        );

    Widget action(IconData icon, String label) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.line),
            ),
            child: Column(children: [
              Icon(icon, size: 19, color: c.text),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: c.text)),
            ]),
          ),
        );

    return Container(
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      child: ListView(children: [
        Text(photo.fileName,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.text)),
        const SizedBox(height: 4),
        Text(prettyDate(photo.modified), style: TextStyle(fontSize: 13, color: c.muted)),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: c.accentSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('Теги появятся после авто-тегирования (следующий шаг)',
              style: TextStyle(color: c.accentInk, fontSize: 12)),
        ),
        const SizedBox(height: 20),
        Row(children: [
          action(Icons.favorite_border, 'В избранное'),
          action(Icons.folder_outlined, 'В альбом'),
          action(Icons.ios_share, 'Поделиться'),
        ]),
        const SizedBox(height: 22)