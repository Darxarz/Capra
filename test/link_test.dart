// Коллекция с ПК (Goat Link): версия индекса, отдельность данных, режим только
// для чтения и состояния подключения. Настоящие данные не трогаются: всё во
// временных папках, вместо Android — подделка GoatLinkApi.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goat/archive_bridge.dart' show kArchiveDir;
import 'package:goat/library_service.dart';
import 'package:goat/link_images.dart';
import 'package:goat/link_index.dart';
import 'package:goat/link_service.dart';
import 'package:goat/media_actions.dart';
import 'package:goat/model.dart';
import 'package:goat_link/goat_link.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'fake_library.dart';

/// Индекс по договору GALLERY_BRIDGE §2.
void writeIndex(String path, {int generatedAt = 1000, bool extra = false}) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
      sha256 TEXT NOT NULL, size INTEGER NOT NULL, rating TEXT, artist TEXT,
      source_url TEXT, series_id TEXT, series_page INTEGER);
    CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL,
      category TEXT NOT NULL, UNIQUE (name, category));
    CREATE TABLE file_tags (file_id INTEGER NOT NULL, tag_id INTEGER NOT NULL,
      confidence REAL NOT NULL, origin TEXT NOT NULL,
      PRIMARY KEY (file_id, tag_id)) WITHOUT ROWID;
    CREATE TABLE series (id TEXT PRIMARY KEY, title TEXT NOT NULL,
      page_count INTEGER NOT NULL, confirmed INTEGER NOT NULL);
  ''');
  for (final e in {
    'format': 'goat-library-index',
    'version': '1',
    'generated_at_ms': '$generatedAt',
    'file_count': '8',
    'app_version': 'test',
  }.entries) {
    db.execute('INSERT INTO meta VALUES (?, ?)', [e.key, e.value]);
  }
  void file(int id, String rel,
      {String? rating, String? artist, String? series, int? page}) {
    db.execute('INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?)', [
      id,
      rel,
      id.toRadixString(16).padLeft(64, 'a'),
      1000 + id,
      rating,
      artist,
      artist == null ? null : 'https://example.test/$id',
      series,
      page,
    ]);
  }

  file(1, 'Furry/Wolf/a.jpg', rating: 'explicit', artist: 'Big Artist');
  file(2, 'Furry/Wolf/b.png', rating: 'general', artist: 'Big Artist');
  file(3, 'Humans/c.webp', rating: 'general');
  file(4, '_Other files/Video/Nature/clip.mp4');
  file(5, 'Comics/Story/p2.jpg', series: 's1', page: 2);
  file(6, 'Comics/Story/p1.jpg', series: 's1', page: 1);
  file(7, 'Comics/Story/p3.jpg', series: 's1', page: 3);
  file(8, 'Furry/project.kra');
  file(9, '_Other files/Audio/song.opus'); // не медиа галереи
  file(10, '_Damaged/broken.jpg'); // карантин сортировщика
  file(11, '.goat-archive-export/journal.jpg'); // служебная папка
  file(12, 'Furry/.thumbnails/t.jpg'); // чужой кэш
  if (extra) file(13, 'Humans/new.jpg');
  db.execute("INSERT INTO tags VALUES (1,'wolf','species'),(2,'solo','general'),"
      "(3,'big_artist','artist'),(4,'explicit','rating')");
  db.execute("INSERT INTO file_tags VALUES (1,1,0.9,'wd-v3'),(1,2,0.9,'wd-v3'),"
      "(2,1,0.8,'wd-v3'),(3,2,1.0,'user'),(1,3,1.0,'user'),(1,4,1.0,'wd-v3'),"
      "(9,2,0.9,'wd-v3')");
  db.execute("INSERT INTO series VALUES ('s1','Сказка',3,1)");
  db.dispose();
}

class FakeApi implements GoatLinkApi {
  FakeApi(this.indexSource);

  String indexSource;
  bool installed = true;
  LinkConnection? stored;
  ProbeResult probeResult = const ProbeResult(ProbeState.ok, indexVersion: '100:1');
  ConnectResult connectResult = const ConnectResult(ConnectStatus.canceled);
  int copies = 0;
  final List<int> canceled = [];
  final StreamController<void> _h = StreamController<void>.broadcast();

  void fireHandoff() => _h.add(null);

  @override
  Stream<void> get handoffs => _h.stream;
  @override
  Future<bool> explorerInstalled() async => installed;
  @override
  Future<bool> openExplorer() async => installed;
  @override
  Future<LinkConnection?> saved() async => stored;
  @override
  Future<bool> takeHandoff() async => false;
  @override
  Future<void> forget() async => stored = null;
  @override
  Future<ConnectResult> connect() async {
    if (connectResult.connection != null) stored = connectResult.connection;
    return connectResult;
  }

  @override
  Future<ProbeResult> probe(String treeUri) async => probeResult;
  @override
  Future<void> copyIndex(String treeUri, String dest,
      {void Function(int, int)? onProgress}) async {
    copies++;
    await File(indexSource).copy(dest);
    onProgress?.call(1, 1);
  }

  final Map<int, Completer<String>> pendingThumbs = {};
  @override
  Future<String> thumbnail(int id, String t, String r, String k, int s) {
    final c = Completer<String>();
    pendingThumbs[id] = c;
    return c.future;
  }

  @override
  Future<String> full(int id, String t, String r, String k) async => r;
  @override
  Future<void> cancel(int id) async {
    canceled.add(id);
    final c = pendingThumbs.remove(id);
    if (c != null && !c.isCompleted) c.completeError(const LinkCanceled());
  }

  @override
  Future<int> openFd(String t, String r) async => 42;
  @override
  Future<void> closeFd(int fd) async {}
}

const kArchiveDirForTest = kArchiveDir;

const conn = LinkConnection(
  treeUri: 'content://dev.filebridge.app.documents/tree/srv%2Froot%2FLib',
  collectionId: 'abc123',
  name: 'Коллекция',
  serverName: 'PC',
  indexVersion: '100:1',
  granted: true,
);

Future<void> settle(LinkService s) async {
  for (var i = 0; i < 400; i++) {
    final busy = s.phase == LinkPhase.checking || s.phase == LinkPhase.importing;
    if (!busy) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('link service did not settle: ${s.phase}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTestSqlite();

  late Directory tmp;
  late String indexPath;
  late FakeApi api;
  late LinkService service;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('goat_link_test');
    indexPath = p.join(tmp.path, 'source-index.sqlite3');
    writeIndex(indexPath);
    api = FakeApi(indexPath)..stored = conn;
    service = LinkService(
      api: api,
      enabled: true,
      supportDir: p.join(tmp.path, 'support'),
      cacheDir: p.join(tmp.path, 'cache'),
    );
  });

  tearDown(() async {
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('index version', () {
    test('a version compare decides whether to import', () {
      expect(linkNeedsImport(stored: null, live: '1:2'), isTrue);
      expect(linkNeedsImport(stored: '1:2', live: '1:2'), isFalse);
      expect(linkNeedsImport(stored: '1:2', live: '3:2'), isTrue);
      expect(linkNeedsImport(stored: '1:2', live: null), isFalse);
      expect(linkNeedsImport(stored: '1:2', live: ''), isFalse);
    });

    test('copies once, skips while unchanged, re-imports when it changes', () async {
      await service.start();
      await settle(service);
      expect(service.phase, LinkPhase.ready);
      expect(api.copies, 1);
      expect(service.db!.fileCount, 7);

      await service.refresh();
      await settle(service);
      expect(api.copies, 1, reason: 'same indexVersion must not copy again');

      writeIndex(p.join(tmp.path, 'v2.sqlite3'), generatedAt: 2000, extra: true);
      api.indexSource = p.join(tmp.path, 'v2.sqlite3');
      api.probeResult = const ProbeResult(ProbeState.ok, indexVersion: '200:2');
      await service.refresh();
      await settle(service);
      expect(api.copies, 2);
      expect(service.phase, LinkPhase.ready);
      expect(service.db!.fileCount, 8);
    });

    test('a restart with the same version opens without copying', () async {
      await service.start();
      await settle(service);
      service.dispose();
      service = LinkService(
        api: api,
        enabled: true,
        supportDir: p.join(tmp.path, 'support'),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      await service.start();
      await settle(service);
      expect(service.phase, LinkPhase.ready);
      expect(api.copies, 1);
    });

    test('a database from an older build is rebuilt, same index version', () async {
      await service.start();
      await settle(service);
      expect(api.copies, 1);
      final path = service.db!.path;
      service.dispose();
      final old = sqlite3.open(path);
      old.execute("UPDATE meta SET value = '1' WHERE key = 'schema'");
      old.dispose();
      service = LinkService(
        api: api,
        enabled: true,
        supportDir: p.join(tmp.path, 'support'),
        cacheDir: p.join(tmp.path, 'cache'),
      );
      await service.start();
      await settle(service);
      expect(service.phase, LinkPhase.ready);
      expect(api.copies, 2);
      expect(readLinkDbVersion(path, conn.collectionId), '100:1');
    });

    test('the private index copy is removed after the import', () async {
      await service.start();
      await settle(service);
      final left = Directory(p.join(tmp.path, 'cache')).listSync();
      expect(left, isEmpty);
    });
  });

  group('import and queries', () {
    late LinkDb db;
    setUp(() async {
      await service.start();
      await settle(service);
      db = service.db!;
    });

    Future<List<String>> rels(LinkFilter f) async {
      final ids = await queryLinkIds(db.path, f);
      return [for (final ph in LinkPhotoList(db, ids)) ph.link!.rel];
    }

    test('only media enters; service, cache and quarantine do not', () async {
      final all = await rels(const LinkFilter(kind: null));
      expect(all, isNot(contains('_Other files/Audio/song.opus')));
      expect(all.where((r) => r.startsWith('_Damaged')), isEmpty);
      expect(all.where((r) => r.contains('.goat-archive-export')), isEmpty);
      expect(all.where((r) => r.contains('.thumbnails')), isEmpty);
      expect(all, isNot(contains('Furry/project.kra')), reason: 'projects off by default');
      expect(await rels(const LinkFilter(kind: kKindProject)), ['Furry/project.kra']);
    });

    test('videos in theme subfolders are listed', () async {
      expect(await rels(const LinkFilter(kind: kKindVideo)),
          ['_Other files/Video/Nature/clip.mp4']);
    });

    test('search: tag, exclusion, artist, Cyrillic-safe folder match', () async {
      expect(await rels(const LinkFilter(text: 'wolf')),
          containsAll(['Furry/Wolf/a.jpg', 'Furry/Wolf/b.png']));
      expect(await rels(const LinkFilter(text: 'wolf -solo')), ['Furry/Wolf/b.png']);
      expect((await rels(const LinkFilter(text: 'artist:big_artist'))).length, 2);
      expect(await rels(const LinkFilter(tags: {'wolf', 'solo'})), ['Furry/Wolf/a.jpg']);
      expect(await rels(const LinkFilter(nsfw: 1)), ['Furry/Wolf/a.jpg']);
    });

    test('series come in reading order', () async {
      final rows = db.series();
      expect(rows.single.title, 'Сказка');
      expect(rows.single.pages, 3);
      expect(await rels(LinkFilter(seriesId: rows.single.id)), [
        'Comics/Story/p1.jpg',
        'Comics/Story/p2.jpg',
        'Comics/Story/p3.jpg',
      ]);
    });

    test('folder filter covers subfolders; counts add up', () async {
      final wolf = db.folders().firstWhere((f) => f.name == 'Wolf');
      expect(wolf.total, 2);
      final furry = db.folders().firstWhere((f) => f.name == 'Furry');
      expect(furry.total, 3, reason: 'Wolf 2 + project 1');
      expect((await rels(LinkFilter(folderId: furry.id))).length, 2);
    });

    test('a list holds a few pages, not every item', () {
      final ids = Int32List(LinkPhotoList.pageSize * 200);
      for (var i = 0; i < ids.length; i++) {
        ids[i] = (i % 7) + 1;
      }
      final list = LinkPhotoList(db, ids);
      expect(list.length, ids.length);
      for (var i = 0; i < ids.length; i += LinkPhotoList.pageSize) {
        expect(list[i].isLinked, isTrue);
      }
      expect(list.loadedPages, lessThanOrEqualTo(LinkPhotoList.maxPages));
      expect(() => list[0] = list[1], throwsUnsupportedError);
    });
  });

  group('data separation', () {
    test('nothing is written outside the link folders', () async {
      final tags = p.join(tmp.path, 'tags.sqlite3');
      final own = sqlite3.open(tags);
      own.execute("CREATE TABLE tags(path TEXT, tag TEXT); INSERT INTO tags VALUES('x','mine')");
      own.dispose();
      final before = File(tags).readAsBytesSync();

      await service.start();
      await settle(service);

      expect(File(tags).readAsBytesSync(), before);
      final dbFiles = Directory(p.join(tmp.path, 'support')).listSync();
      expect(dbFiles.map((e) => p.basename(e.path)), ['abc123.sqlite3']);
    });

    test('no absolute PC path is stored; paths are virtual', () async {
      await service.start();
      await settle(service);
      final ids = await queryLinkIds(service.db!.path, const LinkFilter());
      final ph = LinkPhotoList(service.db!, ids).first;
      expect(ph.path, startsWith('goat-link://abc123/'));
      expect(ph.link!.rel.contains(':'), isFalse);
      expect(await ph.resolveFile(), isNull);
    });

    test('the link database cannot be written through its connection', () async {
      await service.start();
      await settle(service);
      final raw = sqlite3.open(service.db!.path, mode: OpenMode.readOnly);
      expect(() => raw.execute("DELETE FROM files"), throwsA(isA<SqliteException>()));
      raw.dispose();
    });
  });

  group('read-only mode', () {
    PhotoItem linked() => linkPhoto(
        treeUri: conn.treeUri,
        collectionId: 'abc123',
        fileId: 1,
        rel: 'Furry/Wolf/a.jpg',
        sha: 'a' * 64,
        size: 10,
        kind: kKindImage);

    test('linked files never reach write actions', () {
      final local = PhotoItem(
        path: p.join(tmp.path, 'x.jpg'),
        isGif: false,
        folderPath: tmp.path,
        folderName: 'x',
        modified: DateTime(2020),
        sizeBytes: 1,
      );
      expect(writablePhotos([linked()]), isEmpty);
      expect(writablePhotos([linked(), local]), [local]);
    });

    testWidgets('delete with only linked files does nothing, no dialog', (t) async {
      late BuildContext ctx;
      await t.pumpWidget(WidgetsApp(
        color: const Color(0xFF000000),
        builder: (c, _) {
          ctx = c;
          return const SizedBox();
        },
      ));
      expect(await MediaActions.delete(ctx, [linked()]), 0);
      expect(await MediaActions.addTags(ctx, [linked()]), 0);
      expect(await MediaActions.copyOrMove(ctx, [linked()], move: true), isNull);
      expect(await MediaActions.share([linked()]), 0);
    });
  });

  group('connection states', () {
    Future<void> startedWith(ProbeState state) async {
      api.probeResult = ProbeResult(state);
      await service.start();
      await settle(service);
    }

    test('no Explorer, no connection', () async {
      api
        ..installed = false
        ..stored = null;
      await service.start();
      expect(service.phase, LinkPhase.notInstalled);
    });

    test('Explorer present, nothing connected yet', () async {
      api.stored = null;
      await service.start();
      expect(service.phase, LinkPhase.needsConnect);
    });

    test('offline, no collection, revoked', () async {
      await startedWith(ProbeState.offline);
      expect(service.phase, LinkPhase.offline);
      api.probeResult = const ProbeResult(ProbeState.noCollection);
      await service.refresh();
      expect(service.phase, LinkPhase.noCollection);
      api.probeResult = const ProbeResult(ProbeState.revoked);
      await service.refresh();
      expect(service.phase, LinkPhase.revoked);
    });

    test('offline keeps the already imported list browsable; retry recovers', () async {
      await service.start();
      await settle(service);
      api.probeResult = const ProbeResult(ProbeState.offline);
      await service.refresh();
      expect(service.phase, LinkPhase.offline);
      expect(service.canBrowse, isTrue);
      api.probeResult = const ProbeResult(ProbeState.ok, indexVersion: '100:1');
      await service.refresh();
      expect(service.phase, LinkPhase.ready);
      expect(api.copies, 1);
    });

    test('revoked hides the list', () async {
      await service.start();
      await settle(service);
      api.probeResult = const ProbeResult(ProbeState.revoked);
      await service.refresh();
      expect(service.canBrowse, isFalse);
      expect(service.db, isNull);
    });

    test('connect: declined keeps the offer, errors map to plain states', () async {
      api.stored = null;
      await service.start();
      api.connectResult = const ConnectResult(ConnectStatus.canceled);
      await service.connect();
      expect(service.phase, LinkPhase.needsConnect);
      api.connectResult = const ConnectResult(ConnectStatus.noPc);
      await service.connect();
      expect(service.phase, LinkPhase.noPc);
      api.connectResult = const ConnectResult(ConnectStatus.offline);
      await service.connect();
      expect(service.phase, LinkPhase.offline);
      api.connectResult = const ConnectResult(ConnectStatus.noCollection);
      await service.connect();
      expect(service.phase, LinkPhase.noCollection);
    });

    test('connect success imports and becomes ready', () async {
      api.stored = null;
      await service.start();
      api.connectResult = const ConnectResult(ConnectStatus.ok, connection: conn);
      await service.connect();
      await settle(service);
      expect(service.phase, LinkPhase.ready);
      expect(service.hasConnection, isTrue);
    });

    test('Explorer handing over while running opens the collection', () async {
      api.stored = null;
      await service.start();
      api.stored = conn;
      api.fireHandoff();
      for (var i = 0; i < 300 && service.phase != LinkPhase.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.phase, LinkPhase.ready);
      expect(service.handoffSerial, 1);
    });

    test('a corrupt index fails without touching the old list', () async {
      await service.start();
      await settle(service);
      final bad = p.join(tmp.path, 'bad.sqlite3');
      File(bad).writeAsStringSync('not a database');
      api.indexSource = bad;
      api.probeResult = const ProbeResult(ProbeState.ok, indexVersion: '300:3');
      await service.refresh();
      await settle(service);
      expect(service.phase, LinkPhase.failed);
      api
        ..indexSource = indexPath
        ..probeResult = const ProbeResult(ProbeState.ok, indexVersion: '100:1');
      await service.refresh();
      await settle(service);
      expect(service.phase, LinkPhase.ready);
      expect(service.db!.fileCount, 7);
    });
  });

  group('thumbnail cancellation', () {
    const ref = LinkRef(treeUri: 't', fileId: 1, rel: 'a.jpg', sha: 'abcdefabcdefabcdefabcdefabcdefab');

    test('a tile leaving the screen cancels its running load', () async {
      final loads = LinkLoads.instance..api = api;
      final key = LinkLoads.thumbKey(ref, 256);
      loads.retain(key);
      final f = loads.thumbnail(ref, 256);
      final expectation = expectLater(f, throwsA(isA<LinkCanceled>()));
      expect(api.pendingThumbs.length, 1);
      loads.release(key);
      await expectation;
      expect(api.canceled, hasLength(1));
    });

    test('a load another tile still needs survives', () async {
      final loads = LinkLoads.instance..api = api;
      const other = LinkRef(treeUri: 't', fileId: 2, rel: 'b.jpg', sha: 'bbcdefabcdefabcdefabcdefabcdefab');
      final key = LinkLoads.thumbKey(other, 256);
      loads
        ..retain(key)
        ..retain(key);
      final f = loads.thumbnail(other, 256);
      loads.release(key);
      expect(api.canceled, isEmpty);
      api.pendingThumbs.values.single.complete('/cache/x.jpg');
      expect(await f, '/cache/x.jpg');
      loads.release(key);
    });
  });

  test('Windows scan lists videos in _Other files/Video theme folders', () async {
    final lib = Directory(p.join(tmp.path, 'lib'))..createSync();
    final nested = File(p.join(lib.path, '_Other files', 'Video', 'Nature', 'river.mp4'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0, 0, 0, 24]);
    final direct = File(p.join(lib.path, '_Other files', 'Video', 'plain.webm'))
      ..writeAsBytesSync([1]);
    File(p.join(lib.path, kArchiveDirForTest, 'hidden.mp4'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([2]);
    final found = await LibraryService.scan(lib.path);
    expect(found.map((e) => e.path), unorderedEquals([nested.path, direct.path]));
    expect(found.every((e) => e.isVideo), isTrue);
  });

  test('linkShowable rejects unsafe paths', () {
    expect(linkShowable('../secret.jpg'), isFalse);
    expect(linkShowable('a/../b.jpg'), isFalse);
    expect(linkShowable('/abs.jpg'), isFalse);
    expect(linkShowable(r'a\b.jpg'), isFalse);
    expect(linkShowable('Furry/a.JPG'), isTrue);
    expect(linkShowable('Furry/a.txt'), isFalse);
  });
}
