part of 'home_page.dart';

// Коллекция с ПК в обычном облике галереи: те же верхняя панель, рейка, строка
// фильтров, сетка и просмотрщик. Отличия намеренные: всё только для чтения
// (нет выделения, удаления, переноса, переименования, тегирования), а список
// файлов читается из отдельной базы страницами.

const _gPc = GxGlyph('M4.500 5.500h15v10h-15zM9 19.500h6M12 15.500v4');
const _gPerson = GxGlyph(
    'M12 12a3.750 3.750 0 1 0 0-7.500 3.750 3.750 0 0 0 0 7.500zM5 19.500c.8-3.400 3.600-5 7-5s6.200 1.600 7 5');
const _gBook = GxGlyph(
    'M12 6.500C10 5 7.500 4.500 4.500 4.500v13.500c3 0 5.500.5 7.500 2 2-1.500 4.500-2 7.500-2V4.500c-3 0-5.500.5-7.500 2zM12 6.500V20');

class LinkHomePage extends StatefulWidget {
  const LinkHomePage({super.key});

  @override
  State<LinkHomePage> createState() => _LinkHomePageState();
}

class _LinkHomePageState extends State<LinkHomePage>
    with WidgetsBindingObserver {
  final LinkService _link = LinkService.instance;

  bool? _sideOpenPref;
  int _sideTab = 0; // 0 папки, 1 теги, 2 авторы, 3 серии

  String _query = '';
  Set<String> _tags = {};
  int? _folderId;
  String _folderName = '';
  String? _seriesId;
  String _seriesTitle = '';
  String? _artist;
  MediaKindFilter _media = MediaKindFilter.all;
  int _nsfw = 0;
  SortMode _sort = SortMode.nameAsc;

  LinkPhotoList? _list;
  bool _listLoading = false;
  int _generation = 0;
  int _seenRevision = -1;
  Timer? _searchDelay;

  List<LinkFolder> _allFolders = const [];
  Map<int?, List<LinkFolder>> _children = const {};
  final Set<int> _openFolders = {};

  String _sideSearch = '';
  List<LinkTagRow> _tagRows = const [];
  List<LinkTagRow> _artistRows = const [];
  List<LinkSeriesRow> _seriesRows = const [];
  bool _sideRunning = false; // считается один набор за раз
  bool _sideAgain = false; // пока считали, фильтр успел измениться
  bool _sideLoading = false; // расчёт затянулся: чисел пока не показываем
  Timer? _sideSlow;
  Timer? _sideDelay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _link.addListener(_onLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLink());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _link.onResumed();
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _sideDelay?.cancel();
    _sideSlow?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _link.removeListener(_onLink);
    super.dispose();
  }

  void _onLink() {
    if (!mounted) return;
    if (_seenRevision != _link.dbRevision) {
      _seenRevision = _link.dbRevision;
      _reloadStructure();
    }
    setState(() {});
  }

  void _reloadStructure() {
    final db = _link.db;
    if (db == null) {
      _list = null;
      _allFolders = const [];
      _children = const {};
      return;
    }
    _allFolders = db.folders();
    final kids = <int?, List<LinkFolder>>{};
    for (final f in _allFolders) {
      kids.putIfAbsent(f.parentId, () => []).add(f);
    }
    for (final l in kids.values) {
      l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    _children = kids;
    _runQuery();
  }

  /// Счётчики панели считаются под текущий фильтр, в фоне и по одному расчёту
  /// за раз. Панель при этом остаётся живой; если расчёт затянулся, строки
  /// приглушаются и теряют числа, чтобы не обещать устаревшего.
  Future<void> _loadSide() async {
    if (_link.db == null || _sideTab == 0) return;
    if (_sideRunning) {
      _sideAgain = true;
      return;
    }
    _sideRunning = true;
    _sideSlow?.cancel();
    _sideSlow = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _sideLoading = true);
    });
    try {
      do {
        _sideAgain = false;
        final db = _link.db;
        if (db == null || _sideTab == 0) break;
        final only = switch (_sideTab) {
          1 => LinkSideList.tags,
          2 => LinkSideList.artists,
          _ => LinkSideList.series,
        };
        final side = await queryLinkSide(db.path, _filter(),
            search: _sideSearch.trim().toLowerCase(), only: only);
        if (!mounted) return;
        if (_sideAgain ||
            !identical(db, _link.db) ||
            only.index + 1 != _sideTab) {
          _sideAgain = true;
          continue;
        }
        setState(() {
          switch (only) {
            case LinkSideList.tags:
              _tagRows = side.tags;
            case LinkSideList.artists:
              _artistRows = side.artists;
            case LinkSideList.series:
              _seriesRows = side.series;
          }
        });
      } while (_sideAgain);
    } catch (e, s) {
      ErrorLog.recordError(e, s);
    } finally {
      _sideRunning = false;
      _sideSlow?.cancel();
      if (mounted && _sideLoading) setState(() => _sideLoading = false);
    }
  }

  LinkFilter _filter() => LinkFilter(
        folderId: _folderId,
        text: _query,
        tags: _tags,
        kind: _kind,
        nsfw: _nsfw,
        seriesId: _seriesId,
        artist: _artist,
        sort: switch (_sort) {
          SortMode.sizeDesc => 1,
          SortMode.random => 2,
          _ => 0,
        },
        seed: SettingsService.instance.sortSeed,
      );

  int? get _kind => switch (_media) {
        MediaKindFilter.all => null,
        MediaKindFilter.images => kKindImage,
        MediaKindFilter.gifs => kKindGif,
        MediaKindFilter.videos => kKindVideo,
      };

  Future<void> _runQuery() async {
    final db = _link.db;
    if (db == null) return;
    final generation = ++_generation;
    setState(() => _listLoading = true);
    unawaited(_loadSide());
    try {
      final found = await queryLinkRows(db.path, _filter());
      if (!mounted || generation != _generation || !identical(db, _link.db)) {
        return;
      }
      setState(() {
        _list = LinkPhotoList(db, found.ids, videos: found.videos);
        _listLoading = false;
      });
    } catch (e, s) {
      ErrorLog.recordError(e, s);
      if (mounted && generation == _generation) {
        setState(() => _listLoading = false);
      }
    }
  }

  void _change(VoidCallback fn) {
    setState(fn);
    _runQuery();
  }

  bool _compact(BuildContext context) {
    final pref = SettingsService.instance.uiDensity;
    if (pref == UiDensity.compact) return true;
    if (pref == UiDensity.comfortable) return false;
    return MediaQuery.sizeOf(context).shortestSide < 600;
  }

  // ───────────────────────── каркас ─────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final compact = _compact(context);
    final browsing = _link.canBrowse;
    final sideOpen = browsing && (_sideOpenPref ?? !compact);
    final title = _link.connection?.name.isNotEmpty == true
        ? _link.connection!.name
        : tr('Коллекция', 'Collection', 'Colección');
    final crumbs = [
      title,
      if (_folderId != null) _folderName,
      if (_seriesId != null) _seriesTitle,
      if (_artist != null) _artist!,
    ];
    final content = browsing ? _content(c) : _LinkStateView(link: _link);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (browsing) ...[
                      _TopBar(
                        crumbs: crumbs,
                        onCrumb: _onCrumb,
                        cell: SettingsService.instance.cellSize,
                        query: _query,
                        compact: compact,
                        onSearch: (q) {
                          _query = q;
                          _searchDelay?.cancel();
                          _searchDelay = Timer(
                              const Duration(milliseconds: 220), _runQuery);
                        },
                        onCell: (v) {
                          SettingsService.instance.setCellSize(v);
                          setState(() {});
                        },
                        update: null,
                        onUpdate: () {},
                      ),
                      const GxHLine(),
                    ],
                    Expanded(
                      child: compact
                          ? (sideOpen ? _sidePanel(c, compact: true) : content)
                          : Row(children: [
                              if (sideOpen) ...[
                                SizedBox(
                                    width: 280,
                                    child: _sidePanel(c, compact: false)),
                                const GxVLine(),
                              ],
                              Expanded(child: content),
                            ]),
                    ),
                  ],
                ),
              ),
              const GxVLine(),
              _linkRail(c, sideOpen, browsing),
            ]),
          ),
          const GxHLine(),
          _StatusBar(
            pictures: _list?.pictures ?? 0,
            videos: _list?.videos ?? 0,
            where: [
              title,
              if (_link.connection?.serverName.isNotEmpty == true)
                _link.connection!.serverName,
              tr('только просмотр', 'view only', 'solo lectura'),
            ].join(' · '),
          ),
        ]),
      ),
    );
  }

  void _onCrumb(int i) {
    if (i == 0) {
      _change(() {
        _folderId = null;
        _seriesId = null;
        _artist = null;
      });
    }
  }

  Widget _linkRail(AuroraColors c, bool sideOpen, bool browsing) {
    Widget gap(Widget w) =>
        Padding(padding: const EdgeInsets.only(bottom: 2), child: w);
    void side(int tab) {
      setState(() {
        if (sideOpen && _sideTab == tab) {
          _sideOpenPref = false;
        } else {
          _sideTab = tab;
          _sideOpenPref = true;
        }
      });
      unawaited(_loadSide());
    }

    return SizedBox(
      width: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          gap(GxIconBtn(GxGlyph.back,
              tr('Галерея планшета', 'Tablet gallery', 'Galería de la tableta'),
              onTap: () => Navigator.of(context).maybePop())),
          if (_link.explorerInstalled)
            gap(GxIconBtn(
                GxGlyph.list, tr('Проводник', 'Explorer', 'Explorador'),
                onTap: _link.openExplorer)),
          Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              width: 28,
              height: 1,
              color: c.line),
          if (browsing) ...[
            gap(GxIconBtn(GxGlyph.folder, tr('Папки', 'Folders', 'Carpetas'),
                onTap: () => side(0), active: sideOpen && _sideTab == 0)),
            gap(GxIconBtn(GxGlyph.tag, tr('Теги', 'Tags', 'Etiquetas'),
                onTap: () => side(1), active: sideOpen && _sideTab == 1)),
            gap(GxIconBtn(_gPerson, tr('Авторы', 'Artists', 'Autores'),
                onTap: () => side(2), active: sideOpen && _sideTab == 2)),
            gap(GxIconBtn(_gBook, tr('Серии', 'Series', 'Series'),
                onTap: () => side(3), active: sideOpen && _sideTab == 3)),
          ],
          const Spacer(),
          GxIconBtn(GxGlyph.refresh, tr('Обновить', 'Refresh', 'Actualizar'),
              onTap: _link.refresh),
        ]),
      ),
    );
  }

  // ───────────────────────── боковая панель ─────────────────────────
  Widget _sidePanel(AuroraColors c, {required bool compact}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 40,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: GxTabs<int>(
            value: _sideTab,
            height: 40,
            onChanged: (v) {
              setState(() => _sideTab = v);
              unawaited(_loadSide());
            },
            items: [
              (0, tr('Папки', 'Folders', 'Carpetas')),
              (1, tr('Теги', 'Tags', 'Etiquetas')),
              (2, tr('Авторы', 'Artists', 'Autores')),
              (3, tr('Серии', 'Series', 'Series')),
            ],
          ),
        ),
      ),
      const GxHLine(),
      if (_sideTab != 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: _SearchField(
            key: ValueKey('link-side-$_sideTab'),
            initial: _sideSearch,
            onSearch: (v) {
              _sideSearch = v;
              _sideDelay?.cancel();
              _sideDelay =
                  Timer(const Duration(milliseconds: 180), () => _loadSide());
            },
          ),
        ),
      Expanded(
        child: _sideTab == 0
            ? _folderList(compact)
            : Opacity(
                opacity: _sideLoading ? 0.45 : 1,
                child: switch (_sideTab) {
                  1 => _tagList(compact),
                  2 => _artistList(compact),
                  _ => _seriesList(compact),
                },
              ),
      ),
    ]);
  }

  void _closeSideIfCompact(bool compact) {
    if (compact) _sideOpenPref = false;
  }

  List<(LinkFolder, int)> _folderRows() {
    final rows = <(LinkFolder, int)>[];
    void walk(LinkFolder f, int depth) {
      rows.add((f, depth));
      if (_openFolders.contains(f.id)) {
        for (final ch in _children[f.id] ?? const <LinkFolder>[]) {
          walk(ch, depth + 1);
        }
      }
    }

    final roots = _children[null] ?? const <LinkFolder>[];
    for (final root in roots) {
      for (final ch in _children[root.id] ?? const <LinkFolder>[]) {
        walk(ch, 0);
      }
    }
    return rows;
  }

  Widget _folderList(bool compact) {
    final rows = _folderRows();
    final total = _allFolders
        .where((f) => f.parentId == null)
        .fold<int>(0, (n, f) => n + f.total);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemExtent: 34,
      itemCount: rows.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return _SideRow(
            name: tr('Вся коллекция', 'Whole collection', 'Toda la colección'),
            count: total,
            depth: 0,
            selected: _folderId == null && _seriesId == null && _artist == null,
            expanded: null,
            glyph: GxGlyph.gallery,
            onTap: () => _change(() {
              _folderId = null;
              _seriesId = null;
              _artist = null;
              _closeSideIfCompact(compact);
            }),
          );
        }
        final (f, depth) = rows[i - 1];
        final hasKids = (_children[f.id] ?? const []).isNotEmpty;
        final open = _openFolders.contains(f.id);
        return _SideRow(
          name: f.name,
          count: f.total,
          depth: depth,
          selected: _folderId == f.id,
          expanded: hasKids ? open : null,
          onExpand: hasKids
              ? () => setState(() {
                    if (open) {
                      _openFolders.remove(f.id);
                    } else {
                      _openFolders.add(f.id);
                    }
                  })
              : null,
          onTap: () => _change(() {
            _folderId = f.id;
            _folderName = f.name;
            _seriesId = null;
            _artist = null;
            _closeSideIfCompact(compact);
          }),
        );
      },
    );
  }

  Widget _tagList(bool compact) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemExtent: 34,
      itemCount: _tagRows.length,
      itemBuilder: (_, i) {
        final t = _tagRows[i];
        return _SideRow(
          name: t.name,
          count: _sideLoading ? null : t.count,
          depth: 0,
          selected: _tags.contains(t.name),
          expanded: null,
          glyph: GxGlyph.tag,
          onTap: () => _change(() {
            final next = {..._tags};
            if (!next.add(t.name)) next.remove(t.name);
            _tags = next;
            _closeSideIfCompact(compact);
          }),
        );
      },
    );
  }

  Widget _artistList(bool compact) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemExtent: 34,
      itemCount: _artistRows.length,
      itemBuilder: (_, i) {
        final a = _artistRows[i];
        return _SideRow(
          name: a.name,
          count: _sideLoading ? null : a.count,
          depth: 0,
          selected: _artist == a.name,
          expanded: null,
          glyph: _gPerson,
          onTap: () => _change(() {
            _artist = _artist == a.name ? null : a.name;
            _seriesId = null;
            _closeSideIfCompact(compact);
          }),
        );
      },
    );
  }

  Widget _seriesList(bool compact) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemExtent: 34,
      itemCount: _seriesRows.length,
      itemBuilder: (_, i) {
        final s = _seriesRows[i];
        return _SideRow(
          name: s.title,
          count: _sideLoading ? null : s.pages,
          depth: 0,
          selected: _seriesId == s.id,
          expanded: null,
          glyph: _gBook,
          onTap: () => _change(() {
            _seriesId = s.id;
            _seriesTitle = s.title;
            _folderId = null;
            _artist = null;
            _closeSideIfCompact(compact);
          }),
        );
      },
    );
  }

  // ───────────────────────── содержимое ─────────────────────────
  Widget _content(AuroraColors c) {
    final list = _list;
    Widget body;
    if (list == null) {
      body = Center(child: CircularProgressIndicator(color: c.accent));
    } else if (list.isEmpty) {
      body = _listLoading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : const _NoResults(favOnly: false);
    } else {
      body = _AllGrid(
        key: ObjectKey(list),
        photos: list,
        cell: SettingsService.instance.cellSize,
        selectable: false,
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _LinkStatusStrip(link: _link),
      _FilterRow(
        mode: ViewMode.all,
        media: _media,
        onMedia: (m) => _change(() => _media = m),
        folderView: FolderView.grid,
        onFolderView: (_) {},
        sort: _sort,
        sortModes: const [SortMode.nameAsc, SortMode.sizeDesc, SortMode.random],
        onSort: (m) => _change(() => _sort = m),
        nsfwMode: _nsfw,
        onNsfw: () => _change(() => _nsfw = (_nsfw + 1) % 3),
      ),
      const GxHLine(),
      if (_tags.isNotEmpty)
        _TagFilterBar(
          tags: _tags,
          onRemove: (t) => _change(() => _tags = {..._tags}..remove(t)),
          onClear: () => _change(() => _tags = {}),
          onEdit: () => setState(() {
            _sideTab = 1;
            _sideOpenPref = true;
          }),
        ),
      if (_seriesId != null && list != null && list.isNotEmpty)
        Container(
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(children: [
            GxIcon(_gBook, size: 16, color: c.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '$_seriesTitle · ${list.length} ${tr('стр.', 'pages', 'págs.')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 13)),
            ),
            GxTextBtn(tr('Читать', 'Read', 'Leer'),
                primary: true, onTap: () => openViewer(context, list, 0)),
          ]),
        ),
      Expanded(child: body),
    ]);
  }
}

/// Тонкая строка над сеткой: идёт обновление или ПК сейчас недоступен.
class _LinkStatusStrip extends StatelessWidget {
  final LinkService link;
  const _LinkStatusStrip({required this.link});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    if (link.phase == LinkPhase.importing) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: Text(
              link.copying
                  ? tr(
                      'Получаю обновлённый список с ПК…',
                      'Getting the updated list from the PC…',
                      'Recibiendo la lista actualizada del PC…')
                  : tr('Обновляю список…', 'Updating the list…',
                      'Actualizando la lista…'),
              style: TextStyle(color: c.muted, fontSize: 12)),
        ),
        LinearProgressIndicator(value: link.progress, minHeight: 2),
      ]);
    }
    if (link.phase != LinkPhase.offline) return const SizedBox.shrink();
    return Container(
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      child: Row(children: [
        GxIcon(GxGlyph.network, size: 15, color: c.warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              tr(
                  'ПК сейчас недоступен. Видно то, что уже загружено.',
                  'The PC is unavailable. Showing what is already loaded.',
                  'El PC no está disponible. Se muestra lo ya cargado.'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.text, fontSize: 12.5)),
        ),
        GxTextBtn(tr('Повторить', 'Retry', 'Reintentar'),
            height: 32, onTap: link.refresh),
      ]),
    );
  }
}

/// Экран вместо сетки, когда смотреть пока нечего. Всегда оставляет выход в
/// галерею планшета.
class _LinkStateView extends StatelessWidget {
  final LinkService link;
  const _LinkStateView({required this.link});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final back = GxTextBtn(
        tr('Открыть галерею планшета', 'Open tablet gallery',
            'Abrir galería de la tableta'),
        onTap: () => Navigator.of(context).maybePop());
    final connect = GxTextBtn(
        tr('Подключить коллекцию', 'Connect collection', 'Conectar colección'),
        primary: true,
        onTap: link.connect);
    // без сохранённого подключения повторить можно только сам запрос к Explorer
    final retry = GxTextBtn(tr('Повторить', 'Retry', 'Reintentar'),
        primary: true, onTap: link.hasConnection ? link.refresh : link.connect);
    final explorer = link.explorerInstalled
        ? GxTextBtn(
            tr('Открыть Goat Explorer', 'Open Goat Explorer',
                'Abrir Goat Explorer'),
            onTap: link.openExplorer)
        : null;

    final (GxGlyph glyph, String title, String body, List<Widget> actions) =
        switch (link.phase) {
      LinkPhase.notInstalled => (
          _gPc,
          tr('Нужен Goat Explorer', 'Goat Explorer is needed',
              'Se necesita Goat Explorer'),
          tr(
              'Коллекция с компьютера открывается через приложение Goat Explorer. Установите его на планшет и свяжите с ПК.',
              'The PC collection opens through the Goat Explorer app. Install it on this tablet and pair it with the PC.',
              'La colección del PC se abre con la app Goat Explorer. Instálala en la tableta y vincúlala con el PC.'),
          [back],
        ),
      LinkPhase.noPc => (
          _gPc,
          tr('ПК не подключён', 'No PC is paired', 'No hay PC vinculado'),
          tr(
              'В Goat Explorer пока нет связанного компьютера. Свяжите его там и вернитесь сюда.',
              'Goat Explorer has no paired PC yet. Pair one there and come back.',
              'Goat Explorer aún no tiene un PC vinculado. Vincúlalo allí y vuelve.'),
          [if (explorer != null) explorer, connect, back],
        ),
      LinkPhase.offline => (
          GxGlyph.network,
          tr('ПК не отвечает', 'The PC is not responding', 'El PC no responde'),
          tr(
              'Компьютер выключен или находится в другой сети. Включите его, проверьте Wi-Fi и повторите.',
              'The PC is off or on another network. Turn it on, check Wi-Fi and try again.',
              'El PC está apagado o en otra red. Enciéndelo, comprueba el Wi-Fi e inténtalo de nuevo.'),
          [retry, if (explorer != null) explorer, back],
        ),
      LinkPhase.noCollection => (
          GxGlyph.archive,
          tr('Коллекции пока нет', 'No collection yet', 'Aún no hay colección'),
          tr(
              'На компьютере не найдена коллекция Goat Archive. Откройте Goat Archive на ПК, выберите библиотеку и повторите.',
              'No Goat Archive collection was found on the PC. Open Goat Archive there, choose a library and try again.',
              'No se encontró ninguna colección de Goat Archive en el PC. Abre Goat Archive, elige una biblioteca e inténtalo de nuevo.'),
          [if (link.hasConnection) retry else connect, back],
        ),
      LinkPhase.revoked => (
          GxGlyph.shield,
          tr('Доступ отозван', 'Access was withdrawn', 'Acceso retirado'),
          tr(
              'Goat Explorer больше не даёт галерее доступ к коллекции. Подключите её заново.',
              'Goat Explorer no longer gives the gallery access to the collection. Connect it again.',
              'Goat Explorer ya no da acceso a la colección. Vuelve a conectarla.'),
          [connect, back],
        ),
      LinkPhase.failed => (
          GxGlyph.info,
          tr('Не удалось открыть коллекцию', 'Could not open the collection',
              'No se pudo abrir la colección'),
          tr(
              'Что-то пошло не так при чтении списка файлов. Галерея планшета не затронута.',
              'Something went wrong while reading the file list. The tablet gallery is not affected.',
              'Algo falló al leer la lista de archivos. La galería de la tableta no se ha visto afectada.'),
          [if (link.hasConnection) retry else connect, back],
        ),
      LinkPhase.importing => (
          _gPc,
          link.copying
              ? tr(
                  'Получаю список файлов с ПК…',
                  'Getting the file list from the PC…',
                  'Recibiendo la lista de archivos del PC…')
              : tr('Готовлю коллекцию…', 'Preparing the collection…',
                  'Preparando la colección…'),
          tr(
              'Это нужно один раз и после изменений в коллекции. Можно пока смотреть галерею планшета.',
              'This is needed once and after the collection changes. You can browse the tablet gallery meanwhile.',
              'Solo hace falta una vez y tras cambios en la colección. Mientras, puedes ver la galería de la tableta.'),
          [back],
        ),
      LinkPhase.checking || LinkPhase.connecting => (
          _gPc,
          tr('Подключаюсь к ПК…', 'Connecting to the PC…',
              'Conectando con el PC…'),
          '',
          [back],
        ),
      _ => (
          _gPc,
          tr('Коллекция на ПК', 'Collection on the PC', 'Colección en el PC'),
          tr(
              'Откройте свою коллекцию с компьютера прямо здесь. Соединение обеспечивает Goat Explorer, ничего не копируется и не меняется.',
              'Open your PC collection right here. Goat Explorer provides the connection; nothing is copied or changed.',
              'Abre aquí la colección de tu PC. Goat Explorer da la conexión; no se copia ni cambia nada.'),
          [connect, back],
        ),
    };
    final busy = link.phase == LinkPhase.checking ||
        link.phase == LinkPhase.connecting ||
        link.phase == LinkPhase.importing;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GxIcon(glyph, color: c.accent, size: 38),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: c.text, fontSize: 18, fontWeight: FontWeight.w600)),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(body,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 14, height: 1.35)),
            ],
            if (busy) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: 240,
                child: LinearProgressIndicator(
                    value: link.phase == LinkPhase.importing
                        ? link.progress
                        : null,
                    minHeight: 3),
              ),
            ],
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ]),
        ),
      ),
    );
  }
}

/// Предложение подключить коллекцию в галерее планшета: одна строка, убирается.
class _LinkOffer extends StatelessWidget {
  final VoidCallback onConnect;
  final VoidCallback onDismiss;
  const _LinkOffer({required this.onConnect, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
      child: Row(children: [
        GxIcon(_gPc, size: 17, color: c.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
              tr(
                  'Коллекцию с компьютера можно смотреть здесь',
                  'Your PC collection can be viewed here',
                  'Puedes ver aquí la colección de tu PC'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.text, fontSize: 13)),
        ),
        const SizedBox(width: 8),
        GxTextBtn(
            tr('Подключить коллекцию', 'Connect collection',
                'Conectar colección'),
            height: 34,
            primary: true,
            onTap: onConnect),
        GxIconBtn(GxGlyph.close, tr('Скрыть', 'Hide', 'Ocultar'),
            onTap: onDismiss, iconSize: 15),
      ]),
    );
  }
}
