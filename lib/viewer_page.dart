import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'theme.dart';
import 'gx.dart';
import 'model.dart';
import 'editor_service.dart';
import 'i18n.dart';
import 'favorites.dart';
import 'tag_service.dart';
import 'tagger_service.dart';
import 'metadata_service.dart';
import 'settings_service.dart';
import 'media_actions.dart';
import 'similar_page.dart';
import 'collections_page.dart';

// Свои значки просмотрщика — в том же начертании, что и в gx.dart.
const _gPlay = GxGlyph('M8 5.5v13l10.5-6.5z', true);
const _gPause = GxGlyph('M8.5 5.5v13M15.5 5.5v13');
const _gShuffle = GxGlyph(
    'M4 7h3c5 0 5 10 10 10h3M17.5 14.5L20 17l-2.5 2.5M4 17h3c1.5 0 2.600-.700 3.500-1.800M13.500 8.300C14.300 7.500 15.300 7 17 7h3M17.500 4.500L20 7l-2.500 2.500');
const _gSparkle = GxGlyph(
    'M12 4l1.800 4.700 4.700 1.800-4.700 1.800L12 17l-1.800-4.700L5.500 10.500l4.700-1.800zM18 4.500v3M16.500 6h3');
const _gOpenExt = GxGlyph(
    'M14 4.500h5.500V10M19.500 4.500L11 13M17.500 13.500V18a1.500 1.500 0 0 1-1.500 1.500H6A1.500 1.500 0 0 1 4.500 18V8A1.500 1.500 0 0 1 6 6.500h4.500');

/// Открыть просмотрщик на конкретном фото.
void openViewer(BuildContext context, List<PhotoItem> photos, int index) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ViewerPage(photos: photos, initialIndex: index),
  ));
}

/// Общий Hero-тег для миниатюры (`PhotoTile` в home_page.dart) и полноэкранного
/// фото в просмотрщике — по нему плитка плавно "вырастает" на весь экран.
String photoHeroTag(PhotoItem photo) => 'photo:${photo.path}';

/// "Полёт" Hero между плиткой (обычно BoxFit.cover) и просмотрщиком
/// (BoxFit.contain): на время перелёта всегда показываем полноразмерное фото
/// с BoxFit.contain, чтобы не было рывка при смене вида на середине анимации.
HeroFlightShuttleBuilder photoHeroShuttle(PhotoItem photo) {
  return (flightContext, animation, direction, fromHeroContext, toHeroContext) {
    return Image(
      image: photo.full,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (c, e, s) => const SizedBox.shrink(),
    );
  };
}

class ViewerPage extends StatefulWidget {
  final List<PhotoItem> photos;
  final int initialIndex;
  const ViewerPage(
      {super.key, required this.photos, required this.initialIndex});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage>
    with SingleTickerProviderStateMixin {
  late final PageController _controller;
  late int _index;
  bool _infoOpen = false; // боковая панель свёрнута по умолчанию
  bool _zoomed = false; // текущее фото увеличено
  bool _chrome = true; // показывать кнопки/счётчик (тап по фото переключает)
  int _fingers = 0; // активных касаний на экране
  Timer? _slideTimer; // авто-перелистывание (слайдшоу)

  bool get _slideshow => _slideTimer != null;

  // ── свайп вниз закрывает просмотрщик (как в Google Фото) ──
  // Следим за пальцем через сырые Listener-события (как и счётчик _fingers
  // ниже), а не через GestureDetector.onVerticalDrag* — иначе жест конкурирует
  // за арену жестов с внутренним ScaleGestureRecognizer у InteractiveViewer
  // (он «съедает» одиночный палец ещё до нашего распознавателя) и не срабатывает.
  late final AnimationController _dismissCtrl = AnimationController(vsync: this);
  double _dismissDy = 0; // смещение фото вниз во время жеста (0 — на месте)
  bool _dismissDragging = false; // уже определили, что это жест закрытия
  int? _dismissPointer; // id пальца, за которым следим
  Offset _dismissStartPos = Offset.zero;
  Offset _dismissLastPos = Offset.zero;
  bool _dismissAxisDecided = false; // решили, вертикальный жест или нет
  bool _dismissClosing = false; // идёт анимация "улетело — сейчас закроемся"

  // тянуть вниз можно только когда фото не увеличено, одним пальцем и это не видео
  bool get _canDismissDrag =>
      !_zoomed && _fingers < 2 && !widget.photos[_index].isVideo;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _controller.dispose();
    _dismissCtrl.dispose();
    super.dispose();
  }

  void _dismissPointerDown(PointerDownEvent e) {
    // следим только за первым пальцем — если он уже есть, это не тот случай
    if (_dismissPointer != null) return;
    // новый палец лёг поверх ещё не доигравшего возврата на место — считаем,
    // что фото уже вернулось, и отдаём смещение под новый жест
    if (_dismissCtrl.isAnimating && !_dismissClosing) {
      _dismissCtrl.stop();
      setState(() => _dismissDy = 0);
    }
    _dismissPointer = e.pointer;
    _dismissStartPos = e.position;
    _dismissLastPos = e.position;
    _dismissAxisDecided = false;
  }

  void _dismissPointerMove(PointerMoveEvent e) {
    if (e.pointer != _dismissPointer) return;
    final delta = e.position - _dismissLastPos;
    _dismissLastPos = e.position;

    if (_dismissDragging) {
      if (!_canDismissDrag) {
        _dismissDragging = false;
        _dismissPointer = null;
        _settleDismiss(cancel: true);
        return;
      }
      setState(() => _dismissDy = math.max(0.0, _dismissDy + delta.dy));
      return;
    }

    if (_dismissAxisDecided) return; // уже поняли, что это не наш жест
    final total = e.position - _dismissStartPos;
    if (total.distance < 10) return; // ждём, пока наберётся заметное движение
    _dismissAxisDecided = true;
    final isVerticalDown = total.dy > 0 && total.dy.abs() > total.dx.abs() * 1.2;
    if (isVerticalDown && _canDismissDrag) {
      _dismissDragging = true;
      setState(() => _dismissDy = math.max(0.0, total.dy));
    }
  }

  void _dismissPointerUp(PointerEvent e, {bool cancelled = false}) {
    if (e.pointer != _dismissPointer) return;
    _dismissPointer = null;
    if (!_dismissDragging) return;
    _dismissDragging = false;
    final shouldClose = !cancelled && _dismissDy > 110;
    _settleDismiss(cancel: !shouldClose);
  }

  // cancel: true — вернуть фото на место; false — доиграть уход вниз и закрыть
  void _settleDismiss({required bool cancel}) {
    _dismissClosing = !cancel;
    final reduced = SettingsService.instance.motionReduced;
    final begin = _dismissDy;
    final end = cancel ? 0.0 : begin + 260;
    final tween = Tween<double>(begin: begin, end: end);
    void listener() {
      if (mounted) setState(() => _dismissDy = tween.evaluate(_dismissCtrl));
    }

    _dismissCtrl
      ..stop()
      ..value = 0
      ..duration = Duration(milliseconds: reduced ? 0 : (cancel ? 220 : 180))
      ..addListener(listener);
    _dismissCtrl.forward().whenCompleteOrCancel(() {
      _dismissCtrl.removeListener(listener);
      _dismissClosing = false;
      if (!cancel && mounted) Navigator.of(context).maybePop();
    });
  }

  /// Перейти на delta кадров (с зацикливанием). Плавно.
  void _go(int delta, {int ms = 260}) {
    final n = widget.photos.length;
    if (n <= 1) return;
    var next = (_index + delta) % n;
    if (next < 0) next += n;
    _controller.animateToPage(next,
        duration: Duration(milliseconds: ms), curve: Curves.easeOutCubic);
  }

  void _openAt(int index) {
    _controller.animateToPage(index,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  void _random() {
    final n = widget.photos.length;
    if (n <= 1) return;
    var r = math.Random().nextInt(n);
    if (r == _index) r = (r + 1) % n;
    _openAt(r);
  }

  void _toggleSlideshow() {
    setState(() {
      if (_slideTimer != null) {
        _slideTimer!.cancel();
        _slideTimer = null;
      } else {
        _slideTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          if (mounted) _go(1, ms: 600);
        });
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.pageDown) {
      _go(1);
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.pageUp) {
      _go(-1);
    } else if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.backspace) {
      Navigator.of(context).maybePop();
    } else if (k == LogicalKeyboardKey.space) {
      _toggleSlideshow();
    } else if (k == LogicalKeyboardKey.keyF) {
      Favorites.instance.toggle(widget.photos[_index].path);
    } else if (k == LogicalKeyboardKey.keyR) {
      _random();
    } else if (k == LogicalKeyboardKey.keyI) {
      setState(() => _infoOpen = !_infoOpen);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // пока на экране 2+ пальца (щипок) или фото увеличено — НЕ листаем,
  // чтобы жест зума/панорамы не превращался в перелистывание
  void _changeFingers(int delta) {
    final was = _fingers >= 2;
    _fingers = (_fingers + delta).clamp(0, 10);
    if (was != (_fingers >= 2)) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final photo = widget.photos[_index];
    // во время подтверждённого свайпа-закрытия листание тоже блокируем —
    // иначе фото ещё и уедет вбок, поверх вертикального жеста
    final locked = _zoomed || _fingers >= 2 || _dismissDragging;

    final stage = Stack(
      children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: (e) {
              _changeFingers(1);
              _dismissPointerDown(e);
            },
            onPointerMove: _dismissPointerMove,
            onPointerUp: (e) {
              _changeFingers(-1);
              _dismissPointerUp(e);
            },
            onPointerCancel: (e) {
              _changeFingers(-1);
              _dismissPointerUp(e, cancelled: true);
            },
            child: PageView.builder(
              controller: _controller,
              physics: locked
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() {
                _index = i;
                _zoomed = false;
                _dismissDy = 0;
              }),
              itemBuilder: (ctx, i) {
                final p = widget.photos[i];
                if (p.isVideo) return _VideoPlayerPane(photo: p);
                // Hero — только для текущей страницы, иначе PageView строит
                // соседние кадры заранее и получаются два героя с одним тегом
                final heroTag = (i == _index && !SettingsService.instance.motionReduced)
                    ? photoHeroTag(p)
                    : null;
                return _ZoomableImage(
                  key: ValueKey(p.path),
                  photo: p,
                  heroTag: heroTag,
                  onZoomChanged: (z) {
                    if (i == _index && z != _zoomed) {
                      setState(() => _zoomed = z);
                    }
                  },
                  onTap: () => setState(() => _chrome = !_chrome),
                );
              },
            ),
          ),
        ),
        // верхние кнопки и счётчик прячутся по тапу (иммерсивный режим)
        IgnorePointer(
          ignoring: !_chrome,
          child: AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Stack(children: [
              Positioned(
                top: 10,
                left: 10,
                child: _ViewerBtn(
                    glyph: GxGlyph.close,
                    tip: tr('Закрыть', 'Close', 'Cerrar'),
                    onTap: () => Navigator.pop(context)),
              ),
              if (widget.photos.length > 1)
                Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: gxCorner,
                      ),
                      child: Text('${_index + 1} / ${widget.photos.length}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              Positioned(
                top: 10,
                right: 10,
                child: Row(children: [
                  if (widget.photos.length > 1) ...[
                    _ViewerBtn(
                      glyph: _gShuffle,
                      tip: tr('Случайное', 'Random', 'Aleatorio'),
                      onTap: _random,
                    ),
                    const SizedBox(width: 6),
                    _ViewerBtn(
                      glyph: _slideshow ? _gPause : _gPlay,
                      tip: tr('Слайдшоу', 'Slideshow', 'Presentación'),
                      onTap: _toggleSlideshow,
                    ),
                    const SizedBox(width: 6),
                  ],
                  _ViewerBtn(
                    glyph: GxGlyph.info,
                    active: _infoOpen,
                    tip: tr('Сведения', 'Info', 'Información'),
                    onTap: () => setState(() => _infoOpen = !_infoOpen),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ],
    );

    // прогресс жеста «свайп вниз»: 0 — на месте, 1 — уже почти закрыто.
    // Само отслеживание пальца — в Listener внутри stage (см. выше), поэтому
    // тут только визуальный эффект: смещение/уменьшение/лёгкое затухание.
    final dismissT = (_dismissDy / 280).clamp(0.0, 1.0);
    final stageWithDismiss = Transform.translate(
      offset: Offset(0, _dismissDy),
      child: Transform.scale(
        scale: 1 - dismissT * 0.22,
        alignment: Alignment.center,
        // не гасим до нуля — иначе на миг будет "дыра" ещё до закрытия
        child: Opacity(opacity: 1 - dismissT * 0.55, child: stage),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: SafeArea(
        child: LayoutBuilder(builder: (ctx, cns) {
          final wide = cns.maxWidth > 720;
          final dur = SettingsService.instance.motionReduced
              ? Duration.zero
              : const Duration(milliseconds: 220);
          // на ПК панель шириной 360, на телефоне — лист на 78% высоты
          final panelW = wide ? 360.0 : cns.maxWidth;
          final panelH = wide ? cns.maxHeight : cns.maxHeight * 0.78;

          return Stack(children: [
            Positioned.fill(child: stageWithDismiss),

            // затемнение-подложка: тап мимо панели закрывает её
            if (_infoOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _infoOpen = false),
                  child: Container(color: Colors.black.withValues(alpha: 0.45)),
                ),
              ),

            // сама панель — выезжает справа (ПК) или снизу (телефон)
            if (wide)
              AnimatedPositioned(
                duration: dur,
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                right: _infoOpen ? 0 : -panelW,
                width: panelW,
                child: _InfoPanel(
                    photo: photo, colors: c, pool: widget.photos),
              )
            else
              AnimatedPositioned(
                duration: dur,
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                height: panelH,
                bottom: _infoOpen ? 0 : -panelH,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AuroraColors.radius)),
                  child: _InfoPanel(
                      photo: photo,
                      colors: c,
                      pool: widget.photos,
                      asSheet: true),
                ),
              ),
          ]);
        }),
        ),
      ),
    );
  }
}

/// Зум одного фото: щипок, панорама при увеличении и двойной тап для быстрого
/// зума в точку касания. Сообщает наружу, увеличено ли фото (чтобы родитель
/// заблокировал перелистывание).
class _ZoomableImage extends StatefulWidget {
  final PhotoItem photo;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onTap;
  // не null — фото на текущей странице просмотрщика: можно Hero-анимировать
  // из плитки; null — соседние (заранее построенные) страницы PageView, чтобы
  // не получить два героя с одинаковым тегом одновременно
  final String? heroTag;
  const _ZoomableImage(
      {super.key,
      required this.photo,
      required this.onZoomChanged,
      required this.onTap,
      this.heroTag});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _anim;
  Animation<Matrix4>? _animation;
  Offset _tapPos = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    final fast = SettingsService.instance.motionReduced;
    _anim = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: fast ? 0 : 220),
    )..addListener(() {
        final a = _animation;
        if (a != null) _tc.value = a.value;
      });
    _tc.addListener(_onMatrixChanged);
  }

  void _onMatrixChanged() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) {
      _zoomed = z;
      widget.onZoomChanged(z);
    }
  }

  void _animateTo(Matrix4 target) {
    _animation = Matrix4Tween(begin: _tc.value, end: target)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  void _handleDoubleTap() {
    if (_tc.value.getMaxScaleOnAxis() > 1.02) {
      _animateTo(Matrix4.identity()); // уже увеличено — сбрасываем
    } else {
      const scale = 2.8;
      // масштаб вокруг точки касания: M·v = scale·v + смещение
      _animateTo(Matrix4.identity()
        ..setEntry(0, 0, scale)
        ..setEntry(1, 1, scale)
        ..setEntry(0, 3, -_tapPos.dx * (scale - 1))
        ..setEntry(1, 3, -_tapPos.dy * (scale - 1)));
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: widget.photo.full,
      fit: BoxFit.contain,
      errorBuilder: (c2, e, s) =>
          const GxIcon(GxGlyph.gallery, color: Colors.white54, size: 40),
    );
    final heroTag = widget.heroTag;
    if (heroTag != null) {
      image = Hero(
        tag: heroTag,
        flightShuttleBuilder: photoHeroShuttle(widget.photo),
        child: image,
      );
    }
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapPos = d.localPosition,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 6,
        // панораму включаем только при увеличении: при scale==1 всё равно
        // некуда панорамировать, а так честнее отражаем реальное поведение
        panEnabled: _zoomed,
        child: Center(child: image),
      ),
    );
  }
}

class _VideoPlayerPane extends StatefulWidget {
  final PhotoItem photo;
  const _VideoPlayerPane({required this.photo});

  @override
  State<_VideoPlayerPane> createState() => _VideoPlayerPaneState();
}

class _VideoPlayerPaneState extends State<_VideoPlayerPane> {
  Player? _player;
  VideoController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_VideoPlayerPane old) {
    super.didUpdateWidget(old);
    if (old.photo.path != widget.photo.path) _load();
  }

  Future<void> _load() async {
    final old = _player;
    _player = null;
    _controller = null;
    _error = null;
    await old?.dispose();
    final player = Player();
    final controller = VideoController(player);
    final source = widget.photo.isRemote
        ? '${widget.photo.remoteBase}/file?token=${widget.photo.remoteToken}&id=${widget.photo.remoteId}'
        : widget.photo.path;
    try {
      await player.open(Media(source), play: false);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (e) {
      await player.dispose();
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = _controller;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
              '${tr('Не удалось открыть видео', 'Could not open video', 'No se pudo abrir el vídeo')}\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
      );
    }
    if (ctl == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Video(
        controller: ctl,
        controls: AdaptiveVideoControls,
      ),
    );
  }
}

/// Кнопка поверх фото: те же 44×40 и скругление 7, что у GxIconBtn, но белый
/// значок на тёмной подложке (под ней — произвольная фотография).
class _ViewerBtn extends StatelessWidget {
  final GxGlyph glyph;
  final VoidCallback onTap;
  final String? tip;
  final bool active;
  const _ViewerBtn(
      {required this.glyph,
      required this.onTap,
      this.tip,
      this.active = false});

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Colors.black.withValues(alpha: active ? 0.7 : 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: gxCorner,
        side: BorderSide(
            color: Colors.white.withValues(alpha: active ? 0.4 : 0.12)),
      ),
      child: InkWell(
        borderRadius: gxCorner,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 40,
          child: Center(child: GxIcon(glyph, color: Colors.white, size: 19)),
        ),
      ),
    );
    return tip == null ? btn : Tooltip(message: tip, child: btn);
  }
}

class _InfoPanel extends StatelessWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  final List<PhotoItem> pool; // среди чего искать «похожие»
  final bool asSheet; // лист снизу (телефон): линия сверху, а не слева
  const _InfoPanel(
      {required this.photo,
      required this.colors,
      required this.pool,
      this.asSheet = false});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(k, style: TextStyle(color: c.muted, fontSize: 13)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(v,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      color: c.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ),
          ]),
        );

    // кнопка действия: значок над подписью, ячейки делят общую рамку
    Widget action(GxGlyph glyph, String label,
            {VoidCallback? onTap, bool active = false}) =>
        Expanded(
          child: Material(
            color: active ? c.selected : Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                height: 54,
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GxIcon(glyph,
                          size: 19, color: active ? c.current : c.muted),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: active ? c.text : c.muted)),
                      ),
                    ]),
              ),
            ),
          ),
        );

    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(
          left: asSheet ? BorderSide.none : BorderSide(color: c.line),
          top: asSheet ? BorderSide(color: c.line) : BorderSide.none,
        ),
      ),
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 16), children: [
        Text(photo.fileName,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
        const SizedBox(height: 3),
        Text(prettyDate(photo.modified),
            style: TextStyle(fontSize: 12, color: c.muted)),
        if (photo.isProject) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => MediaActions.openInEditor(context, photo),
              icon: GxIcon(_gOpenExt, color: c.onAccent, size: 18),
              label: Text(() {
                final ext = photo.extension.replaceFirst('.', '').toUpperCase();
                return tr('Открыть $ext в редакторе', 'Open $ext in editor',
                    'Abrir $ext en el editor');
              }()),
            ),
          ),
        ],
        // «Открыть в…» — найденные в системе редакторы (ПК)
        if (!photo.isRemote && (Platform.isWindows || Platform.isLinux)) ...[
          const SizedBox(height: 14),
          _OpenInRow(photo: photo, colors: c),
        ],
        const SizedBox(height: 14),
        const GxHLine(),
        const SizedBox(height: 12),
        _TagsSection(photo: photo, colors: c),
        const SizedBox(height: 14),
        ValueListenableBuilder<Set<String>>(
          valueListenable: Favorites.instance.notifier,
          builder: (ctx, favs, _) {
            final fav = favs.contains(photo.path);
            return Container(
              decoration: BoxDecoration(
                borderRadius: gxCorner,
                border: Border.all(color: c.field),
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(children: [
                action(
                  GxGlyph.star,
                  fav
                      ? tr('В избранном', 'Favorited', 'En favoritos')
                      : tr('В избранное', 'Favorite', 'A favoritos'),
                  onTap: () => Favorites.instance.toggle(photo.path),
                  active: fav,
                ),
                const GxVLine(),
                action(GxGlyph.search, tr('Похожие', 'Similar', 'Similares'),
                    onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SimilarPage(photo: photo, pool: pool)));
                }),
                const GxVLine(),
                action(GxGlyph.share, tr('Поделиться', 'Share', 'Compartir'),
                    onTap: () => MediaActions.share([photo])),
                const GxVLine(),
                action(GxGlyph.library,
                    tr('В альбом', 'To album', 'A álbum'),
                    onTap: () => showAddToCollectionSheet(context, [photo.path])),
              ]),
            );
          },
        ),
        const SizedBox(height: 14),
        const GxHLine(),
        if (photo.sizeBytes > 0) ...[
          row(tr('Размер', 'Size', 'Tamaño'), prettySize(photo.sizeBytes)),
          GxHLine(color: c.rowLine),
        ],
        row(tr('Папка', 'Folder', 'Carpeta'), photo.folderName),
        GxHLine(color: c.rowLine),
        const SizedBox(height: 10),
        Text(tr('Путь', 'Path', 'Ruta'),
            style: TextStyle(color: c.muted, fontSize: 13)),
        const SizedBox(height: 4),
        SelectableText(photo.path,
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 14),
        const GxHLine(),
        const SizedBox(height: 12),
        _MetaSection(photo: photo, colors: c),
      ]),
    );
  }
}

// ───────────────────────── «Открыть в…» (редакторы) ─────────────────────────
class _OpenInRow extends StatefulWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _OpenInRow({required this.photo, required this.colors});

  @override
  State<_OpenInRow> createState() => _OpenInRowState();
}

class _OpenInRowState extends State<_OpenInRow> {
  List<EditorApp> _apps = const [];

  @override
  void initState() {
    super.initState();
    EditorService.available().then((a) {
      if (mounted) setState(() => _apps = a);
    });
  }

  Widget _chip(GxGlyph? glyph, String? badge, String label, Color color,
      VoidCallback onTap) {
    final c = widget.colors;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            // у «Другое…» нет фирменного цвета — рисуем его как рамочную кнопку
            color: glyph != null ? c.active : color,
            borderRadius: gxCorner,
            border: glyph != null ? Border.all(color: c.field) : null,
          ),
          alignment: Alignment.center,
          child: glyph != null
              ? GxIcon(glyph, color: c.muted, size: 19)
              : Text(badge ?? '',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 56,
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 11)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final path = widget.photo.path;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Открыть в…', 'Open in…', 'Abrir en…'),
          style: TextStyle(color: c.muted, fontSize: 12)),
      const SizedBox(height: 8),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final app in _apps)
          _chip(null, app.badge, app.name, app.color,
              () => EditorService.openIn(app, path)),
        if (Platform.isWindows)
          _chip(GxGlyph.more, null, tr('Другое…', 'Other…', 'Otra…'), c.active,
              () => EditorService.openWithDialog(path)),
      ]),
      if (_apps.isEmpty && !Platform.isWindows)
        Text(
            tr('Редакторы не найдены.', 'No editors found.',
                'No se encontraron editores.'),
            style: TextStyle(color: c.muted, fontSize: 12)),
    ]);
  }
}

// ───────────────────────── метаданные (EXIF / AI) ─────────────────────────
class _MetaSection extends StatefulWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _MetaSection({required this.photo, required this.colors});

  @override
  State<_MetaSection> createState() => _MetaSectionState();
}

class _MetaSectionState extends State<_MetaSection> {
  PhotoMeta? _meta;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_MetaSection old) {
    super.didUpdateWidget(old);
    if (old.photo.path != widget.photo.path) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rf = await widget.photo.resolveFile();
    final m = await readMetadata(rf?.path ?? widget.photo.path);
    if (mounted) {
      setState(() {
        _meta = m;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    if (_loading) {
      return Row(children: [
        const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 8),
        Text(tr('Читаю метаданные…', 'Reading metadata…', 'Leyendo metadatos…'),
            style: TextStyle(color: c.muted, fontSize: 12)),
      ]);
    }
    final m = _meta;
    if (m == null || !m.hasAnything) {
      return Text(
          tr('Метаданные не найдены.', 'No metadata found.',
              'No se encontraron metadatos.'),
          style: TextStyle(color: c.muted, fontSize: 12));
    }

    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(k, style: TextStyle(color: c.muted, fontSize: 12.5)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(v,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: c.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500)),
                ),
              ]),
        );

    Widget promptBox(String label, String value, Color bg) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: gxCorner,
            border: Border.all(color: c.field),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    color: c.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3)),
            const SizedBox(height: 4),
            SelectableText(value,
                style: TextStyle(color: c.text, fontSize: 12.5, height: 1.35)),
          ]),
        );

    final children = <Widget>[
      Row(children: [
        GxIcon(m.isAi ? _gSparkle : GxGlyph.info, size: 16, color: c.accent),
        const SizedBox(width: 8),
        Text(
            m.isAi
                ? tr('Параметры генерации', 'Generation parameters',
                    'Parámetros de generación')
                : tr('Метаданные', 'Metadata', 'Metadatos'),
            style: TextStyle(
                color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
        if (m.aiTool != null) ...[
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.selected,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: c.accent.withValues(alpha: 0.5)),
            ),
            child: Text(m.aiTool!,
                style: TextStyle(
                    color: c.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ]),
    ];

    if (m.width != null && m.height != null) {
      children.add(kv(tr('Разрешение', 'Resolution', 'Resolución'),
          '${m.width}×${m.height}'));
    }
    if (m.prompt != null && m.prompt!.isNotEmpty) {
      children.add(promptBox('PROMPT', m.prompt!, c.active));
    }
    if (m.negative != null && m.negative!.isNotEmpty) {
      children.add(promptBox('NEGATIVE', m.negative!, c.active));
    }
    if (m.aiParams.isNotEmpty) {
      children.add(const SizedBox(height: 4));
      for (final e in m.aiParams) {
        children.add(kv(e.key, e.value));
      }
    }
    if (m.exif.isNotEmpty) {
      if (m.isAi) children.add(const SizedBox(height: 4));
      for (final e in m.exif) {
        children.add(kv(e.key, e.value));
      }
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

// ───────────────────────── теги фото ─────────────────────────
class _TagsSection extends StatefulWidget {
  final PhotoItem photo;
  final AuroraColors colors;
  const _TagsSection({required this.photo, required this.colors});

  @override
  State<_TagsSection> createState() => _TagsSectionState();
}

class _TagsSectionState extends State<_TagsSection> {
  final _ctl = TextEditingController();
  List<String> _tags = const [];
  bool _busy = false;
  String _busyText = '';
  double? _busyProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _autoTag() async {
    if (_busy) return;
    final tagger = Tagger.instance;
    if (!await tagger.isDownloaded()) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Скачать ИИ-модель?', 'Download AI model?',
              '¿Descargar el modelo de IA?')),
          content: Text(
            tr(
                'Для авто-тегирования нужна модель WD (danbooru/аниме/арт), '
                    '~380 МБ. Скачивается один раз, дальше работает офлайн.',
                'Auto-tagging needs the WD model (danbooru/anime/art), '
                    '~380 MB. Downloaded once, then works offline.',
                'El auto-etiquetado necesita el modelo WD (danbooru/anime/arte), '
                    '~380 MB. Se descarga una vez y luego funciona sin conexión.'),
          ),
          actions: [
            GxTextBtn(tr('Отмена', 'Cancel', 'Cancelar'),
                onTap: () => Navigator.pop(ctx, false)),
            GxTextBtn(tr('Скачать', 'Download', 'Descargar'),
                primary: true, onTap: () => Navigator.pop(ctx, true)),
          ],
        ),
      );
      if (ok != true) return;
      setState(() {
        _busy = true;
        _busyText = tr(
            'Скачивание модели…', 'Downloading model…', 'Descargando modelo…');
        _busyProgress = 0;
      });
      try {
        await tagger.download(onProgress: (pr) {
          if (mounted) setState(() => _busyProgress = pr);
        });
      } catch (e) {
        if (mounted) setState(() => _busy = false);
        _snack(tr('Не удалось скачать модель', 'Could not download model',
            'No se pudo descargar el modelo'));
        return;
      }
    }
    setState(() {
      _busy = true;
      _busyText = tr('Распознаю…', 'Recognizing…', 'Reconociendo…');
      _busyProgress = null;
    });
    try {
      final rf = await widget.photo.resolveFile();
      final n =
          await tagger.tagAndStore(widget.photo.path, readFrom: rf?.path);
      _snack(tr(
          'Добавлено тегов: $n', 'Tags added: $n', 'Etiquetas añadidas: $n'));
    } catch (e) {
      _snack(tr('Ошибка тегирования', 'Tagging error', 'Error de etiquetado'));
    }
    if (mounted) {
      setState(() => _busy = false);
      _load();
    }
  }

  @override
  void didUpdateWidget(_TagsSection old) {
    super.didUpdateWidget(old);
    if (old.photo.path != widget.photo.path) _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _load() =>
      setState(() => _tags = TagService.instance.tagsFor(widget.photo.path));

  void _add() {
    final t = _ctl.text.trim();
    if (t.isEmpty) return;
    TagService.instance.addTag(widget.photo.path, t);
    _ctl.clear();
    _load();
  }

  void _remove(String t) {
    TagService.instance.removeTag(widget.photo.path, t);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 30,
          child: Row(children: [
            GxIcon(GxGlyph.tag, size: 16, color: c.muted),
            const SizedBox(width: 8),
            Text(tr('Теги', 'Tags', 'Etiquetas'),
                style: TextStyle(
                    color: c.text, fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (!_busy && !widget.photo.isVideo)
              Material(
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                    borderRadius: gxCorner, side: BorderSide(color: c.field)),
                child: InkWell(
                  borderRadius: gxCorner,
                  onTap: _autoTag,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(
                      height: 30,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        GxIcon(_gSparkle, size: 15, color: c.accent),
                        const SizedBox(width: 6),
                        Text(tr('Тегировать', 'Auto-tag', 'Auto-etiquetar'),
                            style: TextStyle(
                                color: c.text,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        if (_busy) ...[
          const SizedBox(height: 10),
          Row(children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
                _busyProgress != null
                    ? '$_busyText ${((_busyProgress ?? 0) * 100).round()}%'
                    : _busyText,
                style: TextStyle(color: c.muted, fontSize: 12)),
          ]),
          if (_busyProgress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: _busyProgress, minHeight: 3),
          ],
        ],
        const SizedBox(height: 10),
        if (_tags.isEmpty)
          Text(
              tr(
                  'Пока нет тегов. Добавь вручную или запусти авто-тегирование.',
                  'No tags yet. Add manually or run auto-tagging.',
                  'Aún no hay etiquetas. Añade manualmente o usa el auto-etiquetado.'),
              style: TextStyle(color: c.muted, fontSize: 12))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _tags)
                InkWell(
                  borderRadius: gxCorner,
                  onTap: () => _remove(t),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(9, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: c.selected,
                      borderRadius: gxCorner,
                      border:
                          Border.all(color: c.accent.withValues(alpha: 0.5)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(t, style: TextStyle(color: c.text, fontSize: 12.5)),
                      const SizedBox(width: 5),
                      GxIcon(GxGlyph.close, size: 11, color: c.muted),
                    ]),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: gxCorner,
                border: Border.all(color: c.field),
              ),
              child: TextField(
                controller: _ctl,
                onSubmitted: (_) => _add(),
                style: TextStyle(color: c.text, fontSize: 13.5),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText:
                      tr('Добавить тег…', 'Add a tag…', 'Añadir etiqueta…'),
                  hintStyle: TextStyle(color: c.dim, fontSize: 13.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          GxIconBtn(GxGlyph.plus, tr('Добавить', 'Add', 'Añadir'),
              tint: c.accent, onTap: _add),
        ]),
      ],
    );
  }
}
