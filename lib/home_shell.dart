part of 'home_page.dart';

// Каркас главного экрана в облике Goat Explorer: рейка значков справа, строка
// пути с фильтром сверху, строка-заголовок над содержимым, строка состояния
// внизу. Размеры и отступы — те же, что в проводнике (рейка 52, кнопки 44×40,
// верхняя панель 52, заголовок 34, строка состояния 28).

// ───────────────────────── рейка значков ─────────────────────────
class _Rail extends StatelessWidget {
  final ViewMode mode;
  final ValueChanged<ViewMode> onMode;
  final VoidCallback? onExplorer; // null — проводник не установлен
  final bool sideOpen;
  final VoidCallback onSide;
  final bool favOnly;
  final VoidCallback onFav;
  final bool projectsOnly;
  final VoidCallback onProjects;
  final bool tagsOpen;
  final VoidCallback onTags;
  final VoidCallback onCollections;
  final VoidCallback onDedup;
  final VoidCallback onLan;
  final VoidCallback onTrash;
  final VoidCallback onFolders;
  final VoidCallback onRescan;
  final VoidCallback onSettings;
  const _Rail({
    required this.mode,
    required this.onMode,
    required this.onExplorer,
    required this.sideOpen,
    required this.onSide,
    required this.favOnly,
    required this.onFav,
    required this.projectsOnly,
    required this.onProjects,
    required this.tagsOpen,
    required this.onTags,
    required this.onCollections,
    required this.onDedup,
    required this.onLan,
    required this.onTrash,
    required this.onFolders,
    required this.onRescan,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    Widget rule() => Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        width: 28,
        height: 1,
        color: c.line);
    Widget gap(Widget w) =>
        Padding(padding: const EdgeInsets.only(bottom: 2), child: w);

    return SizedBox(
      width: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          // на низком экране верхняя группа прокручивается, нижняя всегда под рукой
          Expanded(
            child: SingleChildScrollView(
              child: Column(children: [
                if (onExplorer != null) ...[
                  gap(GxIconBtn(GxGlyph.list,
                      tr('Проводник', 'Explorer', 'Explorador'),
                      onTap: onExplorer)),
                  rule(),
                ],
                gap(GxIconBtn(
                    GxGlyph.grid, tr('Все фото', 'All photos', 'Todas'),
                    onTap: () => onMode(ViewMode.all),
                    active: mode == ViewMode.all)),
                gap(GxIconBtn(
                    GxGlyph.calendar, tr('По датам', 'By date', 'Por fecha'),
                    onTap: () => onMode(ViewMode.dates),
                    active: mode == ViewMode.dates)),
                gap(GxIconBtn(
                    GxGlyph.folder, tr('Альбомы', 'Albums', 'Álbumes'),
                    onTap: () => onMode(ViewMode.albums),
                    active: mode == ViewMode.albums)),
                rule(),
                gap(GxIconBtn(
                    GxGlyph.sidebar,
                    tr('Панель альбомов и тегов', 'Albums and tags panel',
                        'Panel de álbumes y etiquetas'),
                    onTap: onSide,
                    active: sideOpen)),
                gap(GxIconBtn(GxGlyph.tag, tr('Теги', 'Tags', 'Etiquetas'),
                    onTap: onTags, active: tagsOpen)),
                gap(GxIconBtn(
                    GxGlyph.star, tr('Избранное', 'Favorites', 'Favoritos'),
                    onTap: onFav,
                    active: favOnly,
                    tint: favOnly ? c.current : null)),
                gap(GxIconBtn(
                    GxGlyph.pencil,
                    tr('Проекты (KRA/PSD)', 'Projects (KRA/PSD)',
                        'Proyectos (KRA/PSD)'),
                    onTap: onProjects,
                    active: projectsOnly)),
                rule(),
                gap(GxIconBtn(GxGlyph.library,
                    tr('Коллекции', 'Collections', 'Colecciones'),
                    onTap: onCollections)),
                gap(GxIconBtn(GxGlyph.duplicates,
                    tr('Дубликаты', 'Duplicates', 'Duplicados'),
                    onTap: onDedup)),
                // подсвечена, пока раздаём по сети
                AnimatedBuilder(
                  animation: LanService.instance,
                  builder: (_, __) => gap(GxIconBtn(
                      GxGlyph.network,
                      tr('Локальная сеть', 'Local network', 'Red local'),
                      onTap: onLan,
                      active: LanService.instance.isRunning,
                      tint: LanService.instance.isRunning ? c.accent : null)),
                ),
                gap(GxIconBtn(GxGlyph.bin, tr('Корзина', 'Trash', 'Papelera'),
                    onTap: onTrash)),
              ]),
            ),
          ),
          gap(GxIconBtn(
              GxGlyph.plus,
              tr('Папки библиотеки', 'Library folders',
                  'Carpetas de la biblioteca'),
              onTap: onFolders)),
          gap(GxIconBtn(
              GxGlyph.settings, tr('Настройки', 'Settings', 'Ajustes'),
              onTap: onSettings)),
          GxIconBtn(GxGlyph.refresh, tr('Обновить', 'Refresh', 'Actualizar'),
              onTap: onRescan),
        ]),
      ),
    );
  }
}

// ───────────────────────── верхняя панель ─────────────────────────
class _TopBar extends StatelessWidget {
  final List<String> crumbs;
  final ValueChanged<int> onCrumb;
  final double cell;
  final String query;
  final bool compact;
  final ValueChanged<String> onSearch;
  final ValueChanged<double> onCell;
  final UpdateInfo? update;
  final VoidCallback onUpdate;
  const _TopBar({
    required this.crumbs,
    required this.onCrumb,
    required this.cell,
    required this.query,
    required this.compact,
    required this.onSearch,
    required this.onCell,
    required this.update,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    const layout = _LayoutSegments();

    final updateBtn = update == null
        ? null
        : Tooltip(
            message: tr(
                'Доступна сборка №${update!.build}',
                'Build #${update!.build} is available',
                'Compilación n.º ${update!.build} disponible'),
            child: GxTextBtn(tr('Обновить', 'Update', 'Actualizar'),
                onTap: onUpdate, primary: true),
          );

    if (compact) {
      // на узком экране путь уходит на свою строку, как в проводнике
      return Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Expanded(child: _SearchField(initial: query, onSearch: onSearch)),
              const SizedBox(width: 6),
              layout,
              if (updateBtn != null) ...[const SizedBox(width: 6), updateBtn],
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: _Crumbs(crumbs: crumbs, onCrumb: onCrumb),
        ),
      ]);
    }
    final c = AuroraTheme.of(context).colors;
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Expanded(flex: 3, child: _Crumbs(crumbs: crumbs, onCrumb: onCrumb)),
          const SizedBox(width: 8),
          Expanded(
              flex: 2,
              child: _SearchField(initial: query, onSearch: onSearch)),
          const SizedBox(width: 8),
          layout,
          const SizedBox(width: 6),
          // размер плиток
          GxIcon(GxGlyph.grid, color: c.dim, size: 14),
          SizedBox(
            width: 120,
            child: Slider(value: cell, min: 70, max: 220, onChanged: onCell),
          ),
          if (updateBtn != null) ...[const SizedBox(width: 6), updateBtn],
        ]),
      ),
    );
  }
}

/// Строка пути в рамке: «Галерея / Альбомы / имя». Нажатие на звено ведёт к нему.
class _Crumbs extends StatelessWidget {
  final List<String> crumbs;
  final ValueChanged<int> onCrumb;
  const _Crumbs({required this.crumbs, required this.onCrumb});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      height: 40,
      decoration: BoxDecoration(
          borderRadius: gxCorner, border: Border.all(color: c.field)),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var i = 0; i < crumbs.length; i++) ...[
            if (i > 0) Text('/', style: TextStyle(color: c.dim, fontSize: 14)),
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () => onCrumb(i),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(crumbs[i],
                    style: TextStyle(
                        color: i == crumbs.length - 1 ? c.strong : c.muted,
                        fontSize: 14,
                        fontWeight: i == crumbs.length - 1
                            ? FontWeight.w600
                            : FontWeight.w400)),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

// ───────────────────────── поле фильтра ─────────────────────────
class _SearchField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onSearch;
  const _SearchField({required this.initial, required this.onSearch});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
          borderRadius: gxCorner, border: Border.all(color: c.field)),
      child: Row(
        children: [
          GxIcon(GxGlyph.search, color: c.muted, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctl,
              onChanged: (v) {
                widget.onSearch(v);
                setState(() {}); // обновить видимость крестика
              },
              cursorColor: c.accent,
              style: TextStyle(color: c.text, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: tr('Имя, папка или тег', 'Name, folder or tag',
                    'Nombre, carpeta o etiqueta'),
                hintStyle: TextStyle(color: c.dim, fontSize: 14),
              ),
            ),
          ),
          if (_ctl.text.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () {
                _ctl.clear();
                widget.onSearch('');
                setState(() {});
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: GxIcon(GxGlyph.close, color: c.muted, size: 14),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────── строка-заголовок над содержимым ───────────────
/// Как строка «Имя / Размер / Изменён» над списком в проводнике: слева — что
/// показывать (всё, фото, GIF, видео), справа — рейтинг и порядок.
class _FilterRow extends StatelessWidget {
  final ViewMode mode;
  final MediaKindFilter media;
  final ValueChanged<MediaKindFilter> onMedia;
  final FolderView folderView;
  final ValueChanged<FolderView> onFolderView;
  final SortMode sort;
  final ValueChanged<SortMode> onSort;
  final int nsfwMode; // 0 все, 1 только 18+, 2 без 18+
  final VoidCallback onNsfw;
  const _FilterRow({
    required this.mode,
    required this.media,
    required this.onMedia,
    required this.folderView,
    required this.onFolderView,
    required this.sort,
    required this.onSort,
    required this.nsfwMode,
    required this.onNsfw,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final albums = mode == ViewMode.albums;
    return SizedBox(
      height: 34,
      child: Row(children: [
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: GxTabs<MediaKindFilter>(
              value: media,
              onChanged: onMedia,
              items: [
                (MediaKindFilter.all, tr('Всё', 'All', 'Todo')),
                (MediaKindFilter.images, tr('Фото', 'Images', 'Imágenes')),
                (MediaKindFilter.gifs, 'GIF'),
                (MediaKindFilter.videos, tr('Видео', 'Video', 'Vídeo')),
              ],
            ),
          ),
        ),
        if (albums)
          GxTabs<FolderView>(
            value: folderView,
            onChanged: onFolderView,
            items: [
              (FolderView.grid, tr('Сетка', 'Grid', 'Cuadrícula')),
              (FolderView.list, tr('Список', 'List', 'Lista')),
              (FolderView.tree, tr('Древо', 'Tree', 'Árbol')),
            ],
          )
        else ...[
          // быстрый фильтр рейтинга: все → только 18+ → без 18+ (по тегам)
          Tooltip(
            message: switch (nsfwMode) {
              1 => tr('Только 18+', 'Only 18+', 'Solo 18+'),
              2 => tr('Без 18+', 'Hide 18+', 'Sin 18+'),
              _ => tr('Рейтинг: все', 'Rating: all', 'Clasificación: todo'),
            },
            child: InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: onNsfw,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  GxIcon(GxGlyph.shield,
                      size: 15,
                      color: switch (nsfwMode) {
                        1 => c.danger,
                        2 => c.accent,
                        _ => c.muted
                      }),
                  if (nsfwMode != 0) ...[
                    const SizedBox(width: 5),
                    Text(nsfwMode == 1 ? '18+' : tr('без 18+', 'no 18+', 'sin 18+'),
                        style: TextStyle(
                            color: nsfwMode == 1 ? c.danger : c.accent,
                            fontSize: 12)),
                  ],
                ]),
              ),
            ),
          ),
          PopupMenuButton<SortMode>(
            tooltip: tr('Сортировка', 'Sort', 'Orden'),
            initialValue: sort,
            onSelected: onSort,
            position: PopupMenuPosition.under,
            itemBuilder: (ctx) => [
              for (final m in SortMode.values)
                PopupMenuItem(
                  value: m,
                  height: 38,
                  child: Text(sortModeLabel(m),
                      style: TextStyle(
                          color: m == sort ? c.accent : c.text,
                          fontSize: 14,
                          fontWeight:
                              m == sort ? FontWeight.w600 : FontWeight.w400)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(sortModeLabel(sort),
                    style: TextStyle(color: c.muted, fontSize: 12)),
                const SizedBox(width: 4),
                GxIcon(GxGlyph.down, color: c.muted, size: 12),
              ]),
            ),
          ),
        ],
        const SizedBox(width: 6),
      ]),
    );
  }
}

// ───────────── полоса активного фильтра по тегам ─────────────
class _TagFilterBar extends StatelessWidget {
  final Set<String> tags;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;
  final VoidCallback onEdit;
  const _TagFilterBar({
    required this.tags,
    required this.onRemove,
    required this.onClear,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Container(
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(children: [
        GxIcon(GxGlyph.tag, size: 15, color: c.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in tags)
              InkWell(
                borderRadius: gxCorner,
                onTap: () => onRemove(t),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(9, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: c.selected,
                    borderRadius: gxCorner,
                    border: Border.all(color: c.accent.withValues(alpha: 0.5)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(t, style: TextStyle(color: c.text, fontSize: 12.5)),
                    const SizedBox(width: 5),
                    GxIcon(GxGlyph.close, size: 11, color: c.muted),
                  ]),
                ),
              ),
          ]),
        ),
        GxIconBtn(
            GxGlyph.pencil, tr('Изменить', 'Edit', 'Editar'), onTap: onEdit,
            iconSize: 16),
        GxIconBtn(
            GxGlyph.close, tr('Сброс', 'Reset', 'Restablecer'), onTap: onClear,
            iconSize: 16),
      ]),
    );
  }
}

// ───────────── полоса действий над выделенным ─────────────
/// Появляется над плитками, пока что-то выделено. Плоская, в рамке — как
/// полоса значков действий в проводнике.
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onFavorite;
  final VoidCallback onTags;
  final VoidCallback onCopy;
  final VoidCallback onMove;
  final VoidCallback onShare;
  final VoidCallback onCollections;
  final VoidCallback onDelete;
  const _SelectionBar({
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.onFavorite,
    required this.onTags,
    required this.onCopy,
    required this.onMove,
    required this.onShare,
    required this.onCollections,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    final on = count > 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: gxCorner,
        border: Border.all(color: c.field),
      ),
      child: Row(children: [
        GxIconBtn(GxGlyph.close,
            tr('Снять выделение', 'Clear selection', 'Quitar selección'),
            onTap: onClose),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('${tr('Выбрано', 'Selected', 'Seleccionadas')} $count',
              style: TextStyle(
                  color: c.strong, fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        GxIconBtn(GxGlyph.selectAll,
            tr('Выбрать все', 'Select all', 'Seleccionar todo'),
            onTap: onSelectAll),
        const Spacer(),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(children: [
              GxIconBtn(
                  GxGlyph.star, tr('В избранное', 'Favorite', 'A favoritos'),
                  onTap: on ? onFavorite : null, tint: on ? c.current : null),
              GxIconBtn(GxGlyph.tag,
                  tr('Добавить теги', 'Add tags', 'Añadir etiquetas'),
                  onTap: on ? onTags : null, tint: on ? c.text : null),
              GxIconBtn(
                  GxGlyph.copy,
                  tr('Копировать в папку', 'Copy to folder',
                      'Copiar a carpeta'),
                  onTap: on ? onCopy : null,
                  tint: on ? c.text : null),
              GxIconBtn(
                  GxGlyph.moveTo,
                  tr('Переместить в папку', 'Move to folder',
                      'Mover a carpeta'),
                  onTap: on ? onMove : null,
                  tint: on ? c.text : null),
              GxIconBtn(
                  GxGlyph.share, tr('Отправить', 'Share', 'Compartir'),
                  onTap: on ? onShare : null, tint: on ? c.text : null),
              GxIconBtn(
                  GxGlyph.library,
                  tr('В коллекцию', 'To collection', 'A colección'),
                  onTap: on ? onCollections : null,
                  tint: on ? c.text : null),
              GxIconBtn(GxGlyph.bin, tr('Удалить', 'Delete', 'Eliminar'),
                  onTap: on ? onDelete : null, tint: on ? c.danger : null),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ───────────────────────── строка состояния ─────────────────────────
class _StatusBar extends StatelessWidget {
  final int total;
  final String? where;
  const _StatusBar({required this.total, required this.where});

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          Expanded(
            child: AnimatedBuilder(
              animation: Selection.instance,
              builder: (_, __) {
                final sel = Selection.instance;
                final images = tr('изображений', 'images', 'imágenes');
                final text = sel.active
                    ? '${tr('Выбрано', 'Selected', 'Seleccionadas')} ${sel.count} ${tr('из', 'of', 'de')} $total'
                    : (where == null
                        ? '$total $images'
                        : '$total $images · $where');
                return Text(text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: sel.active ? c.text : c.muted, fontSize: 12));
              },
            ),
          ),
          // ход пакетного тегирования — как ход копирования в проводнике
          AnimatedBuilder(
            animation: BatchTagger.instance,
            builder: (_, __) {
              final b = BatchTagger.instance;
              if (!b.running) return const SizedBox.shrink();
              return Text(
                  '${tr('Тегирование', 'Tagging', 'Etiquetado')}: ${b.done}',
                  style: TextStyle(color: c.current, fontSize: 12));
            },
          ),
        ]),
      ),
    );
  }
}

// ─────────────── строка боковой панели (альбом) ───────────────
/// Одна строка панели альбомов — как строка папки в панели папок проводника.
class _SideRow extends StatelessWidget {
  final String name;
  final int count;
  final int depth;
  final bool selected;
  final bool? expanded; // null — раскрывать нечего
  final GxGlyph glyph;
  final VoidCallback onTap;
  final VoidCallback? onExpand;
  const _SideRow({
    required this.name,
    required this.count,
    required this.depth,
    required this.selected,
    required this.expanded,
    required this.onTap,
    this.onExpand,
    this.glyph = GxGlyph.folder,
  });

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Material(
      color: selected ? c.selected : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 34,
          child: Row(children: [
            SizedBox(width: 6.0 + depth * 14),
            InkWell(
              onTap: onExpand,
              borderRadius: BorderRadius.circular(5),
              child: SizedBox(
                width: 22,
                height: 34,
                child: expanded == null
                    ? null
                    : Center(
                        child: GxIcon(
                            expanded! ? GxGlyph.down : GxGlyph.forward,
                            color: c.muted,
                            size: 11)),
              ),
            ),
            GxIcon(glyph, color: c.accent, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: selected ? c.strong : c.text,
                      fontSize: 13.5,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 10),
              child: Text('$count',
                  style: TextStyle(color: c.dim, fontSize: 12)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ───────── переключатель раскладки: квадраты / мозаика ─────────
class _LayoutSegments extends StatelessWidget {
  const _LayoutSegments();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SettingsService.instance,
      builder: (_, __) => GxSegments<GridLayout>(
        value: SettingsService.instance.gridLayout,
        items: [
          (
            GridLayout.square,
            GxGlyph.grid,
            tr('Ровные квадраты', 'Even squares', 'Cuadrícula uniforme')
          ),
          (GridLayout.mosaic, GxGlyph.mosaic, tr('Мозаика', 'Mosaic', 'Mosaico')),
        ],
        onChanged: SettingsService.instance.setGridLayout,
      ),
    );
  }
}