import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Why a download stopped. The partial file is kept unless it is [corrupt].
enum DownloadFailureKind { offline, timeout, server, noSpace, corrupt, insecure, canceled }

class DownloadFailure implements Exception {
  final DownloadFailureKind kind;
  final int? status;
  final String detail;
  const DownloadFailure(this.kind, {this.status, this.detail = ''});
  @override
  String toString() => 'DownloadFailure($kind${status == null ? '' : ' $status'} $detail)';
}

/// Stops a running download; what has arrived stays on disk for the next try.
class DownloadCancel {
  bool _canceled = false;
  final List<void Function()> _listeners = [];
  bool get isCanceled => _canceled;
  void cancel() {
    if (_canceled) return;
    _canceled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void _listen(void Function() l) => _listeners.add(l);
  void _unlisten(void Function() l) => _listeners.remove(l);
}

/// Files of one update in its folder. The size is part of the partial file's
/// name, so a partial download of another release is never continued.
String updateApkName(int build) => 'GOAT-build-$build.apk';
String updatePartName(int build, int size) => 'GOAT-build-$build-$size.apk.part';

int? updateFileBuild(String name) {
  final m = RegExp(r'^GOAT-build-(\d+)(?:-\d+)?\.apk(?:\.part)?$').firstMatch(name);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Removes every file in the update folder that [keep] does not want; the
/// argument is the build a file belongs to (null for a stray file). Run on
/// start, so the APK is gone once the new version has been installed.
Future<int> cleanUpdateDir(Directory dir, bool Function(int? build) keep) async {
  var removed = 0;
  if (!await dir.exists()) return 0;
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File) continue;
    if (keep(updateFileBuild(p.basename(e.path)))) continue;
    try {
      await e.delete();
      removed++;
    } catch (_) {
      // a locked or vanished file is tried again next time
    }
  }
  return removed;
}

/// Which update files to keep: never one for the installed build or older;
/// when the latest release is known, only its own; when the check failed
/// (no network), anything newer, so a half-done download is not lost.
bool keepUpdateFile(int? build,
    {required int current, int? offered, required bool latestKnown}) {
  if (build == null || build <= current) return false;
  return latestKnown ? build == offered : true;
}

/// Free space an APK update needs: the rest of the download, plus room for the
/// installer's own copy, plus a margin so the tablet is not left completely full.
int updateSpaceNeeded(int size, int have) {
  if (size <= 0) return 0;
  final rest = size - have < 0 ? 0 : size - have;
  return rest + size + 64 * 1024 * 1024;
}

/// Bytes of [build] already on disk (a finished file counts in full).
int updateBytesOnDisk(Directory dir, int build, int size) {
  final done = File(p.join(dir.path, updateApkName(build)));
  if (done.existsSync() && (size <= 0 || done.lengthSync() == size)) {
    return done.lengthSync();
  }
  final part = File(p.join(dir.path, updatePartName(build, size)));
  return part.existsSync() ? part.lengthSync() : 0;
}

bool _isNoSpace(FileSystemException e) {
  final code = e.osError?.errorCode;
  // ENOSPC on Android/Linux; ERROR_HANDLE_DISK_FULL / ERROR_DISK_FULL on Windows
  if (code == 28 || code == 39 || code == 112) return true;
  return (e.osError?.message ?? e.message).toLowerCase().contains('no space');
}

Future<String> _sha256Of(String path) => Isolate.run(() {
      final raf = File(path).openSync();
      try {
        final out = _DigestSink();
        final input = sha256.startChunkedConversion(out);
        final buf = Uint8List(1 << 20);
        while (true) {
          final n = raf.readIntoSync(buf);
          if (n <= 0) break;
          input.add(Uint8List.sublistView(buf, 0, n));
        }
        input.close();
        return out.value.toString();
      } finally {
        raf.closeSync();
      }
    });

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Download that continues where it stopped (HTTP Range) and only ever hands
/// out a file that is complete: right size and, when known, right sha256.
class ResumableDownload {
  static const _maxRedirects = 8;

  static Future<File> fetch({
    required Uri url,
    required Directory dir,
    required int build,
    required int size,
    String? sha256,
    bool allowHttp = false,
    DownloadCancel? cancel,
    void Function(int done, int total)? onProgress,
    Duration stallTimeout = const Duration(seconds: 30),
  }) async {
    await dir.create(recursive: true);
    final done = File(p.join(dir.path, updateApkName(build)));
    final part = File(p.join(dir.path, updatePartName(build, size)));

    if (await done.exists() && (size <= 0 || await done.length() == size)) {
      onProgress?.call(size, size);
      return done;
    }
    if (await done.exists()) await done.delete();

    var have = await part.exists() ? await part.length() : 0;
    if (size <= 0 || have > size) {
      // unknown size: nothing to check a continuation against
      if (await part.exists()) await part.delete();
      have = 0;
    }
    if (cancel?.isCanceled ?? false) {
      throw const DownloadFailure(DownloadFailureKind.canceled);
    }

    if (size <= 0 || have < size) {
      await _transfer(url, part, have, size, allowHttp, cancel, onProgress, stallTimeout);
    }

    final got = await part.length();
    if (size > 0 && got != size) {
      if (got > size) await part.delete();
      throw DownloadFailure(
          got > size ? DownloadFailureKind.corrupt : DownloadFailureKind.offline,
          detail: 'got $got of $size');
    }
    if (sha256 != null) {
      final actual = await _sha256Of(part.path);
      if (actual != sha256.toLowerCase()) {
        await part.delete();
        throw const DownloadFailure(DownloadFailureKind.corrupt, detail: 'sha256');
      }
    }
    await part.rename(done.path);
    return done;
  }

  static Future<void> _transfer(
    Uri start,
    File part,
    int have,
    int size,
    bool allowHttp,
    DownloadCancel? cancel,
    void Function(int done, int total)? onProgress,
    Duration stallTimeout,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15)
      ..autoUncompress = false
      ..userAgent = 'GOAT-Updater';
    void abort() => client.close(force: true);
    cancel?._listen(abort);
    try {
      var url = start;
      HttpClientResponse? resp;
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        if (url.scheme != 'https' && !(allowHttp && url.scheme == 'http')) {
          throw DownloadFailure(DownloadFailureKind.insecure, detail: '$url');
        }
        final req = await client.getUrl(url);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final r = await req.close().timeout(stallTimeout);
        if (r.isRedirect || const [301, 302, 303, 307, 308].contains(r.statusCode)) {
          final loc = r.headers.value(HttpHeaders.locationHeader);
          await r.drain<void>().catchError((_) {});
          if (loc == null) {
            throw DownloadFailure(DownloadFailureKind.server, status: r.statusCode);
          }
          url = url.resolve(loc);
          continue;
        }
        resp = r;
        break;
      }
      if (resp == null) {
        throw const DownloadFailure(DownloadFailureKind.server, detail: 'redirects');
      }

      var append = false;
      if (resp.statusCode == 206 && have > 0) {
        final range = RegExp(r'bytes (\d+)-(\d+)/(\d+|\*)')
            .firstMatch(resp.headers.value(HttpHeaders.contentRangeHeader) ?? '');
        final from = int.tryParse(range?.group(1) ?? '');
        final total = int.tryParse(range?.group(3) ?? '');
        if (from != have || (total != null && size > 0 && total != size)) {
          // not the continuation we asked for: start over with a clean file
          await resp.drain<void>().catchError((_) {});
          await part.delete();
          return _transfer(start, part, 0, size, allowHttp, cancel, onProgress, stallTimeout);
        }
        append = true;
      } else if (resp.statusCode == 416 && have > 0) {
        await resp.drain<void>().catchError((_) {});
        if (have == size) return; // already all here
        await part.delete();
        return _transfer(start, part, 0, size, allowHttp, cancel, onProgress, stallTimeout);
      } else if (resp.statusCode == 200) {
        final len = resp.contentLength;
        if (size > 0 && len >= 0 && len != size) {
          await resp.drain<void>().catchError((_) {});
          throw DownloadFailure(DownloadFailureKind.corrupt, detail: 'length $len of $size');
        }
        have = 0; // the server sent the whole file
      } else {
        await resp.drain<void>().catchError((_) {});
        throw DownloadFailure(DownloadFailureKind.server, status: resp.statusCode);
      }

      final total = size > 0 ? size : (resp.contentLength >= 0 ? resp.contentLength : 0);
      var received = have;
      onProgress?.call(received, total);
      final raf = await part.open(mode: append ? FileMode.append : FileMode.write);
      try {
        final buf = BytesBuilder(copy: false);
        var lastReport = DateTime.now();
        await for (final chunk in resp.timeout(stallTimeout)) {
          buf.add(chunk);
          received += chunk.length;
          if (buf.length >= (1 << 20)) await raf.writeFrom(buf.takeBytes());
          final now = DateTime.now();
          if (now.difference(lastReport).inMilliseconds >= 150) {
            lastReport = now;
            onProgress?.call(received, total);
          }
        }
        if (buf.isNotEmpty) await raf.writeFrom(buf.takeBytes());
        await raf.flush();
      } finally {
        await raf.close();
      }
      onProgress?.call(received, total);
    } on DownloadFailure {
      if (cancel?.isCanceled ?? false) {
        throw const DownloadFailure(DownloadFailureKind.canceled);
      }
      rethrow;
    } on FileSystemException catch (e) {
      if (_isNoSpace(e)) {
        throw DownloadFailure(DownloadFailureKind.noSpace, detail: e.message);
      }
      rethrow;
    } on TimeoutException {
      if (cancel?.isCanceled ?? false) {
        throw const DownloadFailure(DownloadFailureKind.canceled);
      }
      throw const DownloadFailure(DownloadFailureKind.timeout);
    } catch (e) {
      if (cancel?.isCanceled ?? false) {
        throw const DownloadFailure(DownloadFailureKind.canceled);
      }
      if (e is SocketException || e is HttpException || e is HandshakeException ||
          e is TlsException) {
        throw DownloadFailure(DownloadFailureKind.offline, detail: '$e');
      }
      rethrow;
    } finally {
      cancel?._unlisten(abort);
      client.close(force: true);
    }
  }
}
