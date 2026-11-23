// Связка с Goat Archive: узнавание библиотеки, импорт индекса, порядок серий,
// поиск, файлы запуска. Всё на поддельной библиотеке во временной папке.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:goat/archive_bridge.dart';
import 'package:goat/batch_tagger.dart';
import 'package:goat/collections_service.dart';
import 'package:goat/library_service.dart';
import 'package:goat/model.dart';
import 'package:goat/search_query.dart';
import 'package:goat/tag_service.dart';

import 'fake_library.dart';

const series = [
  FakeSeries('s-1', 'Лесная история'),
  FakeSeries('s-2', 'Наброски', confirmed: false),
];

List<FakeFile> baseFiles() => const [
      FakeFile('Комиксы/Лесная история/p03.png',
          seriesId: 's-1', seriesPage: 3, rating: 'general'),
      FakeFile('Комиксы/Лесная история/p01.png',
          seriesId: 's-1',
          seriesPage: 1,
          rating: 'general',
          tags: [FakeTag('forest'), FakeTag('comic', category: 'meta')]),
      FakeFile('Комиксы/Лесная история/p02.png',
          seriesId: 's-1', seriesPage: 2, rating: 'sensitive'),
      FakeFile('Арт/dragon.png',
          rating: 'explicit',
          artist: 'Foxy Art',
          sourceUrl: 'https://example.org/post/1',
          tags: [
            FakeTag('dragon', category: 'species', confidence: 0.97),
            FakeTag('long_hair', confidence: 0.61),
            FakeTag('sketch', confidence: 1.0, origin: 'user'),
            FakeTag('someartist', category: 'artist', confidence: 0.4),
          ]),
      FakeFile('Арт/wolf.png',
          rating: 'questionable',
          tags: [FakeTag('wolf', category: 'species'), FakeTag('forest')]),
      FakeFile('Арт/plain.png'),
      FakeFile('Арт/resized.png', wrongSize: true, tags: [FakeTag('forest')]),
      FakeFile('Арт/gone.png', onDisk: false, tags: [FakeTag('dragon')]),
      FakeFile('Наброски/a.png', seriesId: 's-2', seriesPage: 1),
      FakeFile('Наброски/b.png', seriesId: 's-2'),
    ];

void main() {
  useTestSqlite();

  late Directory tmp;
  late Directory lib;
  late String tagsDb;
  late String collDb;

  ArchiveImportReport import({int? batch}) => runArchiveImport(
        ArchiveImportRequest(
          root: lib.path,
          tagsDbPath: tagsDb,
          collectionsDbPath: collDb,
          tempDir: tmp.path,
          batchFiles: batch ?? 3,
        ),
      );

  List<Map<String, Object?>> tagRows(String rel) {
    final db = sqlite3.open(tagsDb);
    try {
      return [
        for (final r in db.select(
            'SELECT tag, category, source, confidence FROM tags '
            'WHERE path = ? ORDER BY tag',
            [abs(lib, rel)]))
          {...r}
      ];
    } finally {
      db.dispose();
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('goat_bridge_test_');
    lib = Directory(p.join(tmp.path, 'Коллекция'));
    tagsDb = p.join(tmp.path, 'tags.db');
    collDb = p.join(tmp.path, 'collections.db');
    writeFakeLibraryFiles(lib, baseFiles());
    writeFakeIndex(lib, baseFiles(), series: series, generatedAtMs: 1000);
    TagService.instance.openAt(tagsDb);
    CollectionsService.instance.openAt(collDb);
  });

  tearDown(() {
    TagService.instance.close();
    CollectionsService.instance.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('узнавание библиотеки', () {
    test('метка в корне делает папку и всё под ней библиотекой', () {
      final outside = Directory(p.join(tmp.path, 'Обычная', 'папка'))
        ..createSync(recursive: true);
      final found = findArchiveLibraries([
        p.join(lib.path, 'Арт'),
        p.join(lib.path, 'Комиксы', 'Лесная история'),
        outside.path,
      ]);
      expect(found, [lib.path]);

      final b = ArchiveBridge.instance..libraries = found;
      expect(b.inLibrary(abs(lib, 'Арт/dragon.png')), isTrue);
      expect(b.isLibraryRoot(lib.path), isTrue);
      expect(b.inLibrary(outside.path), isFalse);
      // папка с похожим началом имени — не внутри библиотеки
      expect(b.inLibrary('${lib.path}2'), isFalse);
      b.libraries = const [];
    });

    test('служебная папка распознаётся по сегменту пути', () {
      expect(isInsideArchiveDir(abs(lib, '.goat-archive-export/staging/x.png')),
          isTrue);
      expect(isInsideArchiveDir(abs(lib, 'Арт/dragon.png')), isFalse);
      expect(isInsideArchiveDir(abs(lib, '.goat-archive-export-old/x.png')),
          isFalse);
    });

    test('скан не заходит в служебную папку сортировщика', () async {
      final photos = await LibraryService.scan(lib.path);
      final rels = [
        for (final ph in photos)
          p.relative(ph.path, from: lib.path).replaceAll('\\', '/')
      ]..sort();
      expect(rels, hasLength(9)); // 10 в индексе, один не на диске
      expect(rels.any((r) => r.contains('.goat-archive-export')), isFalse);
      expect(rels.contains('Арт/dragon.png'), isTrue);
      // приманка на месте: её не тронули
      expect(
          File(abs(lib, '.goat-archive-export/staging/decoy.png')).existsSync(),
          isTrue);
    });

    test('папки .thumbnails (любой регистр, любая глубина) не сканируются',
        () async {
      final root = Directory.systemTemp.createTempSync('goat_thumbs_');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final rel in [
        'a/keep.png',
        'a/.thumbnails/x.png',
        '.Thumbnails/y.png',
        'b/c/.THUMBNAILS/z.jpg',
        'b/c/ok.jpg',
        'thumbnails/real.png', // обычная папка с таким именем — остаётся
      ]) {
        final f = File(p.join(root.path, rel))..createSync(recursive: true);
        f.writeAsBytesSync([1, 2, 3]);
      }
      final photos = await LibraryService.scan(root.path);
      final rels = [
        for (final ph in photos)
          p.relative(ph.path, from: root.path).replaceAll(r'\', '/')
      ]..sort();
      expect(rels, ['a/keep.png', 'b/c/ok.jpg', 'thumbnails/real.png']);
    });

    test('общая папка-родитель для выделения', () {
      final a = p.join(lib.path, 'Арт');
      final c = p.join(lib.path, 'Комиксы', 'Лесная история');
      expect(commonParentFolder([a, a]), a);
      expect(commonParentFolder([a, c]), lib.path);
      if (Platform.isWindows) {
        expect(commonParentFolder([r'D:\a', r'E:\a']), isNull);
        expect(commonParentFolder([r'D:\a', r'D:\b']), isNull); // весь диск
      }
    });
  });

  group('импорт индекса', () {
    test('теги, рейтинг, автор и сведения о файле', () {
      final r = import();
      expect(r.error, isNull);
      expect(r.files, 10);
      expect(r.onDisk, 9);
      expect(r.generatedAtMs, 1000);
      expect(r.rated, 5);
      expect(r.withArtist, 1);

      final dragon = tagRows('Арт/dragon.png');
      expect(dragon.map((t) => t['tag']), [
        'artist:foxy_art',
        'dragon',
        'long_hair',
        'rating:explicit',
        'sketch',
        'someartist',
      ]);
      expect(dragon.every((t) => t['source'] == 'goat-archive'), isTrue);
      final byTag = {for (final t in dragon) t['tag']: t};
      expect(byTag['dragon']!['category'], 'species');
      expect(byTag['dragon']!['confidence'], closeTo(0.97, 1e-9));
      expect(byTag['long_hair']!['confidence'], closeTo(0.61, 1e-9));
      expect(byTag['rating:explicit']!['category'], 'rating');
      expect(byTag['artist:foxy_art']!['category'], 'artist');

      final info = TagService.instance.archiveInfo(abs(lib, 'Арт/dragon.png'))!;
      expect(info.artist, 'Foxy Art');
      expect(info.sourceUrl, 'https://example.org/post/1');
      expect(info.library, lib.path);
      final page = TagService.instance
          .archiveInfo(abs(lib, 'Комиксы/Лесная история/p02.png'))!;
      expect(page.seriesId, 's-1');
      expect(page.seriesPage, 2);
      expect(TagService.instance.archiveInfo(abs(tmp, 'нет.png')), isNull);
    });

    test('рейтинг включает существующий фильтр 18+', () {
      import();
      final nsfw = {
        ...TagService.instance.pathsWithTag('rating:questionable'),
        ...TagService.instance.pathsWithTag('rating:explicit'),
      };
      expect(nsfw, {abs(lib, 'Арт/dragon.png'), abs(lib, 'Арт/wolf.png')});
    });

    test('хеши попадают в file_sig только при совпавшем размере', () {
      final r = import();
      expect(r.signatures, 8); // 9 на диске, у одного размер не тот
      final f = File(abs(lib, 'Арт/dragon.png'));
      final st = f.statSync();
      final sig = TagService.instance
          .sigFor(f.path, st.size, st.modified.millisecondsSinceEpoch);
      expect(sig, isNotNull);
      expect(sig!.sha, sha256.convert(f.readAsBytesSync()).toString());
      expect(TagService.instance.shaForPath(abs(lib, 'Арт/resized.png')),
          isNull);
      expect(TagService.instance.shaForPath(abs(lib, 'Арт/gone.png')), isNull);
    });

    test('ручные теги не перезаписываются и не удаляются', () {
      final dragon = abs(lib, 'Арт/dragon.png');
      TagService.instance.addTag(dragon, 'dragon'); // тот же тег, но свой
      TagService.instance.addTag(dragon, 'мой любимый');
      TagService.instance.addTag(dragon, 'long_hair',
          category: 'general', source: 'wd-v3', confidence: 0.2);
      TagService.instance.addTag(dragon, 'rating:general',
          category: 'rating', source: 'wd-v3', confidence: 0.5);
      import();
      final byTag = {for (final t in tagRows('Арт/dragon.png')) t['tag']: t};
      expect(byTag['dragon']!['source'], 'manual');
      expect(byTag['dragon']!['category'], 'manual');
      expect(byTag['мой любимый']!['source'], 'manual');
      // тег своей модели уступает тегу сортировщика
      expect(byTag['long_hair']!['source'], 'goat-archive');
      expect(byTag['long_hair']!['confidence'], closeTo(0.61, 1e-9));
      // рейтинг один: тот, что знает сортировщик
      expect(byTag.containsKey('rating:general'), isFalse);
      expect(byTag['rating:explicit']!['source'], 'goat-archive');
    });

    test('повторный импорт убирает отклонённые теги и пропавшие файлы', () {
      import();
      final dragon = abs(lib, 'Арт/dragon.png');
      TagService.instance.addTag(dragon, 'мой любимый');
      TagService.instance.addTag(abs(lib, 'Арт/wolf.png'), 'оставить');

      // в сортировщике у dragon отклонили long_hair, а wolf.png убрали совсем
      final next = [
        for (final f in baseFiles())
          if (f.rel == 'Арт/dragon.png')
            const FakeFile('Арт/dragon.png',
                rating: 'questionable',
                artist: 'Foxy Art',
                tags: [FakeTag('dragon', category: 'species')])
          else if (f.rel != 'Арт/wolf.png')
            f
      ];
      writeFakeIndex(lib, next, series: series, generatedAtMs: 2000);
      final r = import();
      expect(r.error, isNull);
      expect(r.generatedAtMs, 2000);
      expect(r.staleFiles, 1);

      expect(tagRows('Арт/dragon.png').map((t) => t['tag']), [
        'artist:foxy_art',
        'dragon',
        'rating:questionable',
        'мой любимый',
      ]);
      // у файла, ушедшего из индекса, остаётся только своё
      expect(tagRows('Арт/wolf.png').map((t) => t['tag']), ['оставить']);
      expect(TagService.instance.archiveInfo(abs(lib, 'Арт/wolf.png')), isNull);
    });

    test('тот же индекс дважды не плодит строк', () {
      final a = import();
      final b = import(batch: 1000);
      expect(b.tagRows, a.tagRows);
      final db = sqlite3.open(tagsDb);
      final n = db.select('SELECT count(*) AS n FROM tags').first['n'];
      final files =
          db.select('SELECT count(*) AS n FROM archive_files').first['n'];
      db.dispose();
      expect(n, a.tagRows);
      expect(files, 10);
    });

    test('индекс только читается; в библиотеке ничего не появляется', () {
      Map<String, String> snapshot() => {
            for (final e in lib.listSync(recursive: true))
              if (e is File)
                e.path: sha256.convert(e.readAsBytesSync()).toString()
          };
      final before = snapshot();
      expect(import().error, isNull);
      expect(snapshot(), before);
      // частная копия индекса за собой убрана
      expect(
          tmp.listSync().where((e) => e.path.contains('goat-library-index')),
          isEmpty);
    });

    test('нет индекса или он не того формата — понятный отказ, базы целы', () {
      File(archiveIndexPath(lib.path)).deleteSync();
      expect(readArchiveIndexInfo(lib.path), isNull);
      expect(import().error, 'no-index');

      writeFakeIndex(lib, baseFiles(),
          generatedAtMs: 5, format: 'something-else');
      expect(readArchiveIndexInfo(lib.path), isNull);
      expect(import().error, 'bad-index');

      writeFakeIndex(lib, baseFiles(), generatedAtMs: 5, version: '2');
      expect(import().error, 'bad-index');
      expect(TagService.instance.taggedPaths(), isEmpty);

      writeFakeIndex(lib, baseFiles(), generatedAtMs: 77);
      final info = readArchiveIndexInfo(lib.path)!;
      expect(info.generatedAtMs, 77);
      expect(info.fileCount, 10);
    });

    test('файлы с тегами сортировщика не идут в очередь своей модели', () {
      import();
      PhotoItem ph(String rel) => PhotoItem(
            path: abs(lib, rel),
            isGif: false,
            folderPath: p.dirname(abs(lib, rel)),
            folderName: 'x',
            modified: DateTime(2026),
            sizeBytes: 1,
          );
      final photos = [
        ph('Арт/dragon.png'), // теги из сортировщика
        ph('Арт/wolf.png'),
        ph('Арт/plain.png'), // в индексе без единого тега
      ];
      final todo =
          BatchTagger.pending(photos, TagService.instance.taggedPaths());
      expect(todo.map((e) => p.basename(e.path)), ['plain.png']);
    });

    test('теги сортировщика не попадают в резервную копию', () {
      import();
      TagService.instance.addTag(abs(lib, 'Арт/dragon.png'), 'мой');
      final data = jsonDecode(TagService.instance.exportJson()) as Map;
      final list = data['tags'] as List;
      expect(list, hasLength(1));
      expect((list.first as Map)['tag'], 'мой');
    });
  });

  group('серии → коллекции', () {
    List<String> names(Iterable<String> paths) =>
        [for (final x in paths) p.basename(x)];

    test('одна коллекция на серию, страницы по порядку', () {
      final r = import();
      expect(r.series, 2);
      expect(r.seriesPages, 5);
      final cols = CollectionsService.instance.list();
      expect(cols.map((c) => c.name), ['Лесная история', 'Наброски']);
      expect(cols.every((c) => c.fromArchive), isTrue);
      final forest = cols.first;
      expect(forest.count, 3);
      // в индексе страницы идут 3, 1, 2 — в коллекции 1, 2, 3
      expect(names(CollectionsService.instance.pathsOf(forest.id)),
          ['p01.png', 'p02.png', 'p03.png']);
      expect(p.basename(CollectionsService.instance.coverPath(forest.id)!),
          'p01.png');
      // страница без номера идёт после пронумерованных
      expect(names(CollectionsService.instance.pathsOf(cols.last.id)),
          ['a.png', 'b.png']);
    });

    test('повторный импорт не дублирует и не трогает свои коллекции', () {
      final svc = CollectionsService.instance;
      final mine = svc.create('Моя подборка');
      svc.addPaths(mine, [abs(lib, 'Арт/wolf.png')]);
      import();
      final forest = svc.list(archive: true).first;
      svc.addPaths(forest.id, [abs(lib, 'Арт/dragon.png')]); // добавили руками

      // серию переименовали и переставили страницы; вторая серия исчезла
      final next = [
        for (final f in baseFiles())
          if (f.rel.endsWith('p01.png'))
            const FakeFile('Комиксы/Лесная история/p01.png',
                seriesId: 's-1', seriesPage: 2)
          else if (f.rel.endsWith('p02.png'))
            const FakeFile('Комиксы/Лесная история/p02.png',
                seriesId: 's-1', seriesPage: 1)
          else if (f.seriesId == 's-2')
            FakeFile(f.rel)
          else
            f
      ];
      writeFakeIndex(lib, next,
          series: const [FakeSeries('s-1', 'Лесная история (полная)')],
          generatedAtMs: 3000);
      final r = import();
      expect(r.error, isNull);
      expect(r.series, 1);

      final archive = svc.list(archive: true);
      expect(archive.map((c) => c.name), ['Лесная история (полная)']);
      expect(archive.first.id, forest.id); // та же коллекция, не новая
      expect(names(svc.pathsOf(forest.id)),
          ['p02.png', 'p01.png', 'p03.png', 'dragon.png']);

      final own = svc.list(archive: false);
      expect(own.map((c) => c.name), ['Моя подборка']);
      expect(own.first.fromArchive, isFalse);
      expect(names(svc.pathsOf(mine)), ['wolf.png']);
      expect(svc.hasArchiveSeries, isTrue);
    });

    test('свои коллекции показываются как раньше — новые сверху', () async {
      final svc = CollectionsService.instance;
      final id = svc.create('Своя');
      svc.addPaths(id, ['a']);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      svc.addPaths(id, ['b']);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      svc.addPaths(id, ['c']);
      expect(svc.pathsOf(id), ['c', 'b', 'a']);
      expect(svc.coverPath(id), 'a');
    });

    test('база прежнего вида мигрирует без потери данных', () {
      CollectionsService.instance.close();
      final old = p.join(tmp.path, 'old_collections.db');
      final db = sqlite3.open(old);
      db.execute('''
        CREATE TABLE collections(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL, created INTEGER NOT NULL);
        CREATE TABLE collection_items(
          collection_id INTEGER NOT NULL, path TEXT NOT NULL,
          added INTEGER NOT NULL, PRIMARY KEY(collection_id, path));
        INSERT INTO collections(name, created) VALUES('Старая', 10);
        INSERT INTO collection_items VALUES(1, 'x', 1), (1, 'y', 2);
      ''');
      db.dispose();
      CollectionsService.instance.openAt(old);
      CollectionsService.instance.openAt(old); // повторно — без ошибок
      final cols = CollectionsService.instance.list();
      expect(cols.single.name, 'Старая');
      expect(cols.single.fromArchive, isFalse);
      expect(CollectionsService.instance.pathsOf(cols.single.id), ['y', 'x']);
    });
  });

  group('поиск как в сортировщике', () {
    test('разбор строки', () {
      final q = SearchQuery.parse(
          '  Dragon -sketch artist:Someone автор:Кто-то - night ');
      expect(q.terms, ['dragon', 'night']);
      expect(q.excluded, ['sketch']);
      expect(q.artists, ['someone', 'кто-то']);
      expect(SearchQuery.parse('   ').isEmpty, isTrue);
    });

    Set<String> run(String query) {
      final m = SearchMatcher.resolve(query);
      return {
        for (final f in baseFiles())
          if (m.matches(
              abs(lib, f.rel),
              p.basename(f.rel).toLowerCase(),
              p.dirname(f.rel).toLowerCase()))
            f.rel
      };
    }

    test('слово, -тег и artist:имя', () {
      import();
      // слово — имя файла, папка или тег (подстрокой, как раньше)
      expect(run('forest'), {
        'Комиксы/Лесная история/p01.png',
        'Арт/wolf.png',
        'Арт/resized.png',
      });
      expect(run('drag'), {'Арт/dragon.png', 'Арт/gone.png'});
      expect(run('лесная'), hasLength(3)); // папка
      // исключение — точный тег
      expect(run('forest -wolf'), {
        'Комиксы/Лесная история/p01.png',
        'Арт/resized.png',
      });
      expect(run('-forest').contains('Арт/wolf.png'), isFalse);
      expect(run('-forest'), hasLength(7));
      expect(run('-fore'), hasLength(10)); // часть тега не исключает
      // «_» и пробел равнозначны, регистр не важен
      expect(run('-LONG_HAIR').contains('Арт/dragon.png'), isFalse);
      // автор: только уверенный автор сортировщика, не подсказка модели
      expect(run('artist:foxy_art'), {'Арт/dragon.png'});
      expect(run('artist:foxy'), {'Арт/dragon.png'});
      expect(run('автор:FoxyArt'), {'Арт/dragon.png'});
      expect(run('artist:someartist'), isEmpty);
      expect(run('artist:foxy -dragon'), isEmpty);
      expect(run('rating:explicit'), {'Арт/dragon.png'});
      expect(run(''), hasLength(10));
    });

    test('новый ручной тег находится сразу', () {
      import();
      expect(run('закат'), isEmpty);
      TagService.instance.addTag(abs(lib, 'Арт/plain.png'), 'Закат');
      expect(run('закат'), {'Арт/plain.png'});
      expect(run('artist:me'), isEmpty);
      TagService.instance.addTag(abs(lib, 'Арт/plain.png'), 'artist:me');
      expect(run('artist:me'), {'Арт/plain.png'});
    });

    test('поиск идёт по индексу тегов, без перебора таблицы', () {
      import();
      final db = sqlite3.open(tagsDb);
      String plan(String sql) => db
          .select('EXPLAIN QUERY PLAN $sql')
          .map((r) => '${r['detail']}')
          .join(' | ');
      final paths =
          plan("SELECT DISTINCT path FROM tags WHERE tag IN ('a', 'b')");
      final vocab = plan('''
        WITH RECURSIVE t(tag) AS (
          SELECT min(tag) FROM tags
          UNION ALL
          SELECT (SELECT min(tag) FROM tags WHERE tag > t.tag)
          FROM t WHERE t.tag IS NOT NULL
        ) SELECT tag FROM t WHERE tag IS NOT NULL''');
      db.dispose();
      expect(paths, contains('idx_tags_tag'));
      expect(paths, isNot(contains('SCAN tags')));
      expect(vocab, contains('idx_tags_tag'));
      expect(vocab, isNot(contains('SCAN tags')));
      expect(TagService.instance.vocabulary(), contains('artist:foxy_art'));
    });
  });

  group('запуск друг друга', () {
    test('gallery.json пишется по договору', () {
      final ok = GoatApps.writeGalleryJson(
          base: tmp.path, exe: r'C:\Apps\GOAT\aurora_gallery.exe', version: '9');
      expect(ok, isTrue);
      final f = File(p.join(tmp.path, 'Goat', 'apps', 'gallery.json'));
      expect(jsonDecode(f.readAsStringSync()),
          {'exe': r'C:\Apps\GOAT\aurora_gallery.exe', 'version': '9'});
      expect(f.parent.listSync(), hasLength(1)); // .tmp не остался
    });

    test('без archive.json просьба не пишется', () async {
      expect(GoatApps.archiveExe(base: tmp.path), isNull);
      final r = await GoatApps.mergeFolder(r'D:\Old backup\Pictures',
          base: tmp.path, launch: false);
      expect(r, HandoffResult.notInstalled);
      expect(Directory(p.join(tmp.path, 'Goat', 'inbox')).existsSync(), isFalse);
    });

    test('просьба «добавить папку» ложится в ящик сортировщика', () async {
      final exe = File(p.join(tmp.path, 'goat-archive-desktop.exe'))
        ..writeAsStringSync('stub');
      final apps = Directory(p.join(tmp.path, 'Goat', 'apps'))
        ..createSync(recursive: true);
      File(p.join(apps.path, 'archive.json'))
          .writeAsStringSync(jsonEncode({'exe': exe.path, 'version': '1'}));
      expect(GoatApps.archiveExe(base: tmp.path), exe.path);

      final r = await GoatApps.mergeFolder(r'D:\Old backup\Pictures',
          base: tmp.path, launch: false);
      expect(r, HandoffResult.sent);
      final inbox = Directory(p.join(tmp.path, 'Goat', 'inbox', 'archive'));
      final files = inbox.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.path.endsWith('.json'), isTrue);
      expect(jsonDecode(files.single.readAsStringSync()),
          {'action': 'add-source', 'path': r'D:\Old backup\Pictures'});
      // вторая просьба — отдельный файл
      await GoatApps.mergeFolder(lib.path, base: tmp.path, launch: false);
      expect(inbox.listSync(), hasLength(2));
    });

    test('--open: папка, файл и добавление корня', () {
      expect(GoatApps.openPathFromArgs(['--open', r'D:\x']), r'D:\x');
      expect(GoatApps.openPathFromArgs(['--open=D:/x']), 'D:/x');
      expect(GoatApps.openPathFromArgs(['--other']), isNull);
      expect(GoatApps.openPathFromArgs(['--open']), isNull);

      final roots = [p.join(tmp.path, 'Чужой корень')];
      final folder = planOpen(lib.path, roots)!;
      expect(folder.folder, lib.path);
      expect(folder.file, isNull);
      expect(folder.addRoot, lib.path); // не под корнями — добавить

      final file = planOpen(abs(lib, 'Арт/dragon.png'), [lib.path])!;
      expect(file.folder, p.join(lib.path, 'Арт'));
      expect(file.file, abs(lib, 'Арт/dragon.png'));
      expect(file.addRoot, isNull); // уже под корнем — корни не меняются

      expect(planOpen(p.join(tmp.path, 'нет такой'), roots), isNull);
    });
  });
}
