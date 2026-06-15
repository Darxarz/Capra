import 'package:flutter/material.dart';
import 'theme.dart';
import 'tag_service.dart';
import 'batch_tagger.dart';
import 'i18n.dart';

/// Боковая панель тегов: поиск, сортировка, группировка по категориям.
/// Тап по тегу мгновенно включает/выключает его в фильтре (живая фильтрация).
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
              style: TextStyle(
                  color: c.text, fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: b.downloadProgress,
              color: c.accent,
              backgroundColor: c.surface2,
              minHeight: 6,
            ),
          ),
        ]),
      );
    }
    if (b.running) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(
                  '${tr('Тегирую', 'Tagging', 'Etiquetando')}: ${b.done} / ${b.total}',
                  style: TextStyle(
                      color: c.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ),
            GestureDetector(
              onTap: () {
                b.stop();
                setState(() {});
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.line),
                ),
                child: Text(tr('Стоп', 'Stop', 'Parar'),
                    style: TextStyle(color: c.text, fontSize: 12)),
              ),
            ),
          ]),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: b.total == 0 ? null : b.progress,
              color: c.accent,
              backgroundColor: c.surface2,
              minHeight: 6,
            ),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: widget.onStartBatch,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Text(tr('Тегировать всё', 'Tag everything', 'Etiquetar todo'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
        if (b.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(b.error!,
                style: TextStyle(color: c.muted, fontSize: 11.5)),
          ),
        if (b.error == null && b.done > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '${tr('Готово', 'Done', 'Listo')}: ${tr('отмечено', 'tagged', 'etiquetadas')} ${b.tagged} ${tr('из', 'of', 'de')} ${b.done}',
                style: TextStyle(color: c.muted, fontSize: 11.5)),
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

    return Container(
      width: widget.width ?? 290,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // шапка
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
            child: Row(children: [
              Icon(Icons.sell_outlined, size: 17, color: c.accent),
              const SizedBox(width: 8),
              Text(tr('Теги', 'Tags', 'Etiquetas'),
                  style: TextStyle(
                      color: c.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
              const Spacer(),
              _SortToggle(
                byCount: _byCount,
                onChanged: (v) {
                  setState(() => _byCount = v);
                  _load();
                },
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: Icon(Icons.close, size: 18, color: c.muted),
                tooltip: tr('Скрыть панель', 'Hide panel', 'Ocultar panel'),
              ),
            ]),
          ),
          // поиск
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: c.line),
              ),
              child: Row(children: [
                Icon(Icons.search, size: 17, color: c.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    onChanged: (v) => setState(() => _query = v),
                    cursorColor: c.accent,
                    style: TextStyle(color: c.text, fontSize: 13.5),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: tr(
                          'Поиск тега…', 'Search tags…', 'Buscar etiquetas…'),
                      hintStyle: TextStyle(color: c.muted, fontSize: 13.5),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          _batchBar(c),
          if (widget.selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 6),
              child: Row(children: [
                Text(
                    '${tr('Выбрано', 'Selected', 'Seleccionado')}: ${widget.selected.length}',
                    style: TextStyle(color: c.muted, fontSize: 12)),
                const Spacer(),
                GestureDetector(
                  onTap: widget.onClear,
                  child: Text(tr('Сброс', 'Reset', 'Restablecer'),
                      style: TextStyle(
                          color: c.muted,
                          fontSize: 12,
                          decoration: TextDecoration.underline)),
                ),
              ]),
            ),
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
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    children: [
                      for (final cat in orderedCats) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 12, 0, 7),
                          child: Text(
                              '${_catLabel(cat)}  ·  ${groups[cat]!.length}',
                              style: TextStyle(
                                  color: c.muted,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final t in groups[cat]!)
                            _Chip(
                              label: '${t.tag}  ${t.count}',
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
    Widget b(String label, bool on, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: on ? c.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: on ? c.text : c.muted)),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b(tr('Кол-во', 'Count', 'Cantidad'), byCount, () => onChanged(true)),
        b('А-Я', !byCount, () => onChanged(false)),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final AuroraColors colors;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.accent : c.surface2,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: selected ? c.accent : c.line),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : c.text,
                fontSize: 12,
                fontWeight: FontWeight.w500)),
      ),
    );
  }
}
