import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'theme.dart';
import 'model.dart';
import 'embed_service.dart';
import 'embed_store.dart';
import 'batch_embedder.dart';
import 'viewer_page.dart';
import 'i18n.dart';

/// Экран «Похожие»: находит визуально близкие картинки через эмбеддинги CLIP.
/// Работает среди уже проиндексированных фото; кнопка запускает индексацию всей
/// библиотеки в фоне. Всё локально, ничего не уходит в сеть.
class SimilarPage extends StatefulWidget {
  final PhotoItem photo;
  final List<PhotoItem> pool; // среди чего искать (текущий список галереи)
  const SimilarPage({super.key, required this.photo, required this.pool});

  @override
  State<SimilarPage> createState() => _SimilarPageState();
}

class _SimilarPageState extends State<SimilarPage> {
  bool _loading = true;
  bool _needDownload = false;
  bool _downloading = false;
  double _dlProgress = 0;
  String? _error;
  List<PhotoItem> _results = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await EmbedStore.instance.init();
      if (!await EmbedService.instance.isDownloaded()) {
        setState(() {
          _needDownload = true;
          _loading = false;
        });
        return;
      }
      await EmbedService.instance.load();

      // вектор запроса: из базы, либо считаем прямо сейчас
      Float32List? query = EmbedStore.instance.vectorOf(widget.photo.path);
      if (query == null) {
        final rf = await widget.photo.resolveFile();
        if (rf != null) {
          final vec = await EmbedService.instance.embedBytes(await rf.readAsBytes());
          if (vec != null) {
            EmbedStore.instance.put(widget.photo.path, vec);
            query = vec;
          }
        }
      }
      if (query == null) {
        setState(() {
          _error = tr('Не удалось прочитать это фото', 'Could not read this photo',
              'No se pudo leer esta foto');
          _loading = false;
        });
        return;
      }

      final ranked =
          EmbedService.instance.searchSimilar(query, exclude: widget.photo.path);
      final byPath = {for (final p in widget.pool) p.path: p};
      final res = <PhotoItem>[];
      for (final path in ranked) {
        final p = byPath[path];
        if (p != null) res.add(p); // сохраняем порядок ранжирования
      }
      setState(() {
        _results = res;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _dlProgress = 0;
    });
    try {
      await EmbedService.instance.download(onProgress: (pr) {
        if (mounted) setState(() => _dlProgress = pr);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _needDownload = true;
          _error = '$e';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _needDownload = false;
    });
    // после скачивания сразу индексируем библиотеку в фоне + показываем это фото
    BatchEmbedder.instance.start(widget.pool);
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        foregroundColor: c.text,
        title: Text(tr('Похожие', 'Similar', 'Similares')),
        actions: [
          IconButton(
            tooltip: tr('Проиндексировать библиотеку', 'Index library',
                'Indexar biblioteca'),
            icon: const Icon(Icons.auto_awesome_rounded),
            onPressed: () => BatchEmbedder.instance.start(widget.pool),
          ),
        ],
      ),
      body: _body(c),
    );
  }

  Widget _body(AuroraColors c) {
    if (_needDownload) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.image_search_rounded, size: 54, color: c.accent),
            const SizedBox(height: 14),
            Text(
                tr('Для поиска похожих нужна ИИ-модель (CLIP), ~350 МБ. Скачивается один раз, дальше офлайн.',
                    'Similarity search needs the CLIP AI model, ~350 MB. Downloaded once, then offline.',
                    'La búsqueda de similares necesita el modelo CLIP, ~350 MB. Se descarga una vez.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted)),
            const SizedBox(height: 18),
            if (_downloading)
              Column(children: [
                LinearProgressIndicator(
                    value: _dlProgress, color: c.accent, backgroundColor: c.surface2),
                const SizedBox(height: 8),
                Text('${(_dlProgress * 100).round()}%',
                    style: TextStyle(color: c.muted)),
              ])
            else
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: c.accent),
                onPressed: _download,
                icon: const Icon(Icons.download_rounded),
                label: Text(tr('Скачать модель', 'Download model', 'Descargar modelo')),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: c.accent, fontSize: 12)),
            ],
          ]),
        ),
      );
    }
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: c.accent));
    }
    if (_error != null) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
      ));
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.travel_explore_rounded, size: 48, color: c.muted),
            const SizedBox(height: 12),
            Text(
                tr('Пока нечего сравнивать. Запусти индексацию библиотеки (кнопка сверху) — потом «Похожие» будут находиться.',
                    'Nothing to compare yet. Index the library (button above), then similar photos will show up.',
                    'Nada que comparar aún. Indexa la biblioteca (botón arriba).'),
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted)),
            const SizedBox(height: 8),
            AnimatedBuilder(
              animation: BatchEmbedder.instance,
              builder: (_, __) {
                final b = BatchEmbedder.instance;
                if (!b.running) return const SizedBox.shrink();
                return Text(
                    b.downloading
                        ? '${tr('Скачивание модели', 'Downloading model', 'Descargando')}: ${(b.downloadProgress * 100).round()}%'
                        : '${tr('Индексация', 'Indexing', 'Indexando')}: ${b.done}/${b.total}',
                    style: TextStyle(color: c.accent, fontSize: 12));
              },
            ),
          ]),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: _results.length,
      itemBuilder: (ctx, i) {
        final ph = _results[i];
        final dpr = MediaQuery.of(ctx).devicePixelRatio;
        final cw = (120 * dpr).round().clamp(64, 512);
        return GestureDetector(
          onTap: () => openViewer(ctx, _results, i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image(
              image: ph.thumb(cw),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (c2, e, s) => Container(
                  color: AuroraTheme.of(c2).colors.surface2,
                  child: Icon(Icons.broken_image_outlined,
                      size: 16, color: AuroraTheme.of(c2).colors.muted)),
            ),
          ),
        );
      },
    );
  }
}
