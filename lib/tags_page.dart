import 'package:flutter/material.dart';
import 'theme.dart';
import 'gx.dart';
import 'tag_service.dart';
import 'batch_tagger.dart';
import 'i18n.dart';

/// Боковая панель тегов: поиск, сортировка, группировка по категориям.
/// Тап по тегу мгновенно включает/выключает его в фильтре (живая фильтрация).
/// Показывается внутри боковой панели главного экрана — как продолжение
/// списка альбомов: без своего фона, рамки и крупной шапки.
class TagsPanel extends StatefulWidget {
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final VoidCallback onStartBatch;
  final double? width;
  const TagsPanel({
    super.key,
    required this.selected,
    required this.onToggle,
    required this.onClear,
    required this.onClose,
    required this.onStartBatch,
    this.width,
  });

  @override
  State<TagsPanel> createState() => _TagsPanelState();
}

class _TagsPanelState extends State<TagsPanel> {
  final _ctl = TextEditingController();
  String _query = '';
  bool _byCount = true;
  List<({String tag, int count, String category})> _all = const [];

  static const _catOrder = ['type', 'rating', 'character', 'general', 'manual'];

  @override
  void initState() {
    super.initState();
    _load();
    BatchTagger.instance.addListener(_onBatch);
  }

  @override
  void dispose() {
    BatchTagger.instance.removeListener(_onBatch);
    _ctl.dispose();
    super.dispose();
  }

  void _load() =>
      setState(() => _all = TagService.instance.tagList(byCount: _byCount));

  // во время пакетного тегирования обновляем список тегов (не каждый кадр —
  // запрос GROUP BY тяжелеет с ростом базы) и всегда — индикатор прогресса
  void _onBatch() {
    if (!mounted) return;
    final b = BatchTagger.instance;
    if (!b.running || b.done % 30 == 0) {
      _all = TagService.instance.tagList(byCount: _byCount);
    }
    setState(() {});
  }

  String _catLabel(String c) => switch (c) {
        'type' => tr('Тип', 'Type', 'Tipo'),
        'rating' => tr('Рейтинг', 'Rating', 'Clasificación'),
        'character' => tr('Персонажи', 'Characters', 'Personajes'),
        'manual' => tr('Вручную', 'Manual', 'Manual'),
        _ => tr('Общие', 'General', 'Generales'),
      };

  Widget _batchBar(AuroraColors c) {
    final b = BatchTagger.instance;
    if (b.downloading) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              '${tr('Скачивание модели…', 'Downloading model…', 'Descargando modelo…')} ${(b.downloadProgress * 100).round()}%',
              style: TextStyle(color: c.text, fontSize: 12.5)),
          const SizedBox(height: 7),
          LinearProgressIndicator(value: b.downloadProgress, minHeight: 3),
        ]),
      );
    }
    if (b.running) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(
                  '${tr('Тегирую', 'Tagging', 'Etiquetando')}: ${b.done} / ${b.total}',
                  style: TextStyle(color: c.text, fontSize: 12.5)),
            ),
            GxTextBtn(tr('Стоп', 'Stop', 'Parar'), height: 30, onTap: () {
              b.stop();
              setState(() {});
            }),
          ]),
          const SizedBox(height: 7),
          LinearProgressIndicator(
              value: b.total == 0 ? null : b.progress, minHeight: 3),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: gxCorner, side: BorderSide(color: c.field)),
          child: InkWell(
            borderRadius: gxCorner,
            onTap: widget.onStartBatch,
            child: SizedBox(
              height: 34,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                GxIcon(GxGlyph.bolt, size: 16, color: c.accent),
                const SizedBox(width: 8),
                Text(tr('Тегировать всё', 'Tag everything', 'Etiquetar todo'),
                    style: TextStyle(
                        color: c.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ),
        if (b.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(b.error!,
                style: TextStyle(color: c.muted, fontSize: 12)),
          ),
        if (b.error == null && b.done > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '${tr('Готово', 'Done', 'Listo')}: ${tr('отмечено', 'tagged', 'etiquetadas')} ${b.tagged} ${tr('из', 'of', 'de')} ${b.done}',
                style: TextStyle(color: c.muted, fontSize: 12)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final q = _query.trim().toLowerCase();
    final filtered =
        q.isEmpty ? _all : _all.where((t) => t.tag.contains(q)).toList();

    final groups = <String, List<({String tag, int count, String category})>>{};
    for (final t in filtered) {
      groups.putIfAbsent(t.category, () => []).add(t);
    }
    final orderedCats = [
      ..._catOrder.where(groups.containsKey),
      ...groups.keys.where((k) => !_catOrder.contains(k)),
    ];

    return SizedBox(
      width: widget.width ?? 290,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // тонкая строка управления: сортировка · сброс · скрыть
          SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(children: [
                _SortToggle(
                  byCount: _byCount,
                  onChanged: (v) {
                    setState(() => _byCount = v);
                    _load();
                  },
                ),
                const Spacer(),
                if (widget.selected.isNotEmpty)
                  GxIconBtn(GxGlyph.refresh,
                      tr('Сброс', 'Reset', 'Restablecer'),
                      iconSize: 17, onTap: widget.onClear),
                GxIconBtn(GxGlyph.close,
                    tr('Скрыть панель', 'Hide panel', 'Ocultar panel'),
                    iconSize: 17, onTap: widget.onClose),
              ]),
            ),
          ),
          // поиск
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: gxCorner,
                border: Border.all(color: c.field),
              ),
              child: Row(children: [
                GxIcon(GxGlyph.search, size: 16, color: c.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(color: c.text, fontSize: 13.5),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: tr(
                          'Поиск тега…', 'Search tags…', 'Buscar etiquetas…'),
                      hintStyle: TextStyle(color: c.dim, fontSize: 13.5),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          _batchBar(c),
          if (widget.selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 4),
              child: Text(
                  '${tr('Выбрано', 'Selected', 'Seleccionado')}: ${widget.selected.length}',
                  style: TextStyle(color: c.muted, fontSize: 12)),
            ),
          const GxHLine(),
          // список тегов
          Expanded(
            child: _all.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                          tr(
                              'Тегов пока нет.\nОтметь фото или запусти авто-тегирование.',
                              'No tags yet.\nTag a photo or start auto-tagging.',
                              'Todavía no hay etiquetas.\nEtiqueta una foto o inicia el auto-etiquetado.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted, fontSize: 13)),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: [
                      for (final cat in orderedCats) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 12, 0, 6),
                          child: Text(
                              '${_catLabel(cat)}  ·  ${groups[cat]!.length}',
                              style: TextStyle(
                                  color: c.muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500)),
                        ),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final t in groups[cat]!)
                            _Chip(
                              tag: t.tag,
                              count: t.count,
                              selected: widget.selected.contains(t.tag),
                              colors: c,
                              onTap: () => widget.onToggle(t.tag),
                            ),
                        ]),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SortToggle extends StatelessWidget {
  final bool byCount;
  final ValueChanged<bool> onChanged;
  const _SortToggle({required this.byCount, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget b(String label, bool on, VoidCallback onTap) => Material(
          color: on ? c.active : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: on ? c.text : c.muted)),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: gxCorner,
        border: Border.all(color: c.field),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b(tr('Кол-во', 'Count', 'Cantidad'), byCount, () => onChanged(true)),
        b('А-Я', !byCount, () => onChanged(false)),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String tag;
  final int count;
  final bool selected;
  final AuroraColors colors;
  final VoidCallback onTap;
  const _Chip({
    required this.tag,
    required this.count,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return InkWell(
      borderRadius: gxCorner,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? c.selected : Colors.transparent,
          borderRadius: gxCorner,
          border: Border.all(
              color: selected ? c.accent.withValues(alpha: 0.5) : c.field),
        ),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: tag, style: TextStyle(color: c.text, fontSize: 12.5)),
          TextSpan(
              text: '  $count', style: TextStyle(color: c.dim, fontSize: 11.5)),
        ])),
      ),
    );
  }
}
