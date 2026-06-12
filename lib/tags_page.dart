import 'package:flutter/material.dart';
import 'theme.dart';
import 'tag_service.dart';

/// Обозреватель тегов: поиск, сортировка, группировка по категориям,
/// выбор тегов для фильтрации галереи (И). Возвращает выбранный набор.
class TagsPage extends StatefulWidget {
  final Set<String> initialSelected;
  const TagsPage({super.key, required this.initialSelected});

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  late final Set<String> _selected = {...widget.initialSelected};
  final _ctl = TextEditingController();
  String _query = '';
  bool _byCount = true;
  List<({String tag, int count, String category})> _all = const [];

  static const _catOrder = ['rating', 'character', 'general', 'manual'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _load() =>
      setState(() => _all = TagService.instance.tagList(byCount: _byCount));

  int get _matchCount => _selected.isEmpty
      ? 0
      : TagService.instance.pathsWithAllTags(_selected).length;

  String _catLabel(String c) => switch (c) {
        'rating' => 'Рейтинг',
        'character' => 'Персонажи',
        'manual' => 'Добавленные вручную',
        _ => 'Общие',
      };

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

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // шапка
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 14, 6),
              child: Row(children: [
                IconButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  icon: Icon(Icons.arrow_back, color: c.text),
                  tooltip: 'Назад',
                ),
                const SizedBox(width: 2),
                Text('Теги',
                    style: TextStyle(
                        color: c.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
                const Spacer(),
                _SortToggle(
                  byCount: _byCount,
                  onChanged: (v) {
                    setState(() => _byCount = v);
                    _load();
                  },
                ),
              ]),
            ),
            // поиск
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.line),
                ),
                child: Row(children: [
                  Icon(Icons.search, size: 18, color: c.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _ctl,
                      onChanged: (v) => setState(() => _query = v),
                      cursorColor: c.accent,
                      style: TextStyle(color: c.text, fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Поиск тега…',
                        hintStyle: TextStyle(color: c.muted, fontSize: 14),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            // выбранные (активный фильтр)
            if (_selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final t in _selected)
                    _Chip(
                      label: t,
                      selected: true,
                      colors: c,
                      onTap: () => setState(() => _selected.remove(t)),
                    ),
                  GestureDetector(
                    onTap: () => setState(_selected.clear),
                    child: Text('Очистить',
                        style: TextStyle(
                            color: c.muted,
                            fontSize: 12,
                            decoration: TextDecoration.underline)),
                  ),
                ]),
              ),
            // список тегов по группам
            Expanded(
              child: _all.isEmpty
                  ? Center(
                      child: Text(
                          'Тегов пока нет.\nОтметь фото в просмотрщике или запусти авто-тегирование.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted)),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                      children: [
                        for (final cat in orderedCats) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
                            child: Text(
                                '${_catLabel(cat)}  ·  ${groups[cat]!.length}',
                                style: TextStyle(
                                    color: c.muted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                          ),
                          Wrap(spacing: 6, runSpacing: 6, children: [
                            for (final t in groups[cat]!)
                              _Chip(
                                label: '${t.tag}  ${t.count}',
                                selected: _selected.contains(t.tag),
                                colors: c,
                                onTap: () => setState(() {
                                  if (!_selected.add(t.tag)) {
                                    _selected.remove(t.tag);
                                  }
                                }),
                              ),
                          ]),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: () => Navigator.pop(context, _selected),
                  child: Text('Показать $_matchCount фото'),
                ),
              ),
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
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: on ? c.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: on ? c.text : c.muted)),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: c.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b('Кол-во', byCount, () => onChanged(true)),
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
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.accent : c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? c.accent : c.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  color: selected ? Colors.white : c.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500)),
          if (selected) ...[
            const SizedBox(width: 5),
            const Icon(Icons.close, size: 13, color: Colors.white),
          ],
        ]),
      ),
    );
  }
}
