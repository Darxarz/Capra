import 'package:flutter/services.dart';

/// What Android says about a downloaded APK before it goes to the installer.
class ApkFacts {
  final bool readable;
  final String package;
  final String ownPackage;
  final int versionCode;
  final int installedVersionCode;

  /// null when Android does not report signers; the installer still checks.
  final bool? sameSigner;

  const ApkFacts({
    required this.readable,
    this.package = '',
    this.ownPackage = '',
    this.versionCode = 0,
    this.installedVersionCode = 0,
    this.sameSigner,
  });

  static ApkFacts fromMap(Map<Object?, Object?> m) => ApkFacts(
        readable: m['readable'] == true,
        package: '${m['package'] ?? ''}',
        ownPackage: '${m['ownPackage'] ?? ''}',
        versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
        installedVersionCode: (m['installedVersionCode'] as num?)?.toInt() ?? 0,
        sameSigner: m['sameSigner'] as bool?,
      );
}

enum InstallOutcome {
  /// The system installer finished (usually the process ends before this arrives).
  installed,

  /// The installer screen is open; no result will come back.
  opened,

  /// The owner closed the installer screen.
  canceled,

  /// Android refused the file.
  failed,
}

/// Android side of GOAT's self-update. Replaced by a fake in tests.
abstract class GoatUpdateApi {
  /// Folder for the download; the only one the installer may read from.
  Future<String> updateDir();

  /// Free bytes where the download goes.
  Future<int> freeSpace();

  /// Whether "install unknown apps" is allowed for GOAT.
  Future<bool> canInstall();

  /// Opens that settings page; completes with [canInstall] after the owner returns.
  Future<bool> openInstallSettings();

  Future<ApkFacts> inspect(String path);

  Future<InstallOutcome> install(String path);
}

class MethodChannelGoatUpdate implements GoatUpdateApi {
  static const MethodChannel _channel = MethodChannel('dev.goat.update');

  @override
  Future<String> updateDir() async =>
      (await _channel.invokeMethod<String>('updateDir'))!;

  @override
  Future<int> freeSpace() async =>
      (await _channel.invokeMethod<num>('freeSpace'))?.toInt() ?? 0;

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<bool> openInstallSettings() async =>
      await _channel.invokeMethod<bool>('openInstallSettings') ?? false;

  @override
  Future<ApkFacts> inspect(String path) async {
    final m = await _channel
        .invokeMapMethod<Object?, Object?>('inspect', {'path': path});
    return ApkFacts.fromMap(m ?? const {});
  }

  @override
  Future<InstallOutcome> install(String path) async {
    final r = await _channel.invokeMethod<String>('install', {'path': path});
    switch (r) {
      case 'ok':
        return InstallOutcome.installed;
      case 'opened':
        return InstallOutcome.opened;
      case 'canceled':
        return InstallOutcome.canceled;
      default:
        return InstallOutcome.failed;
    }
  }
}
