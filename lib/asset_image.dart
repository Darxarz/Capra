import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:photo_manager/photo_manager.dart';

/// Картинки прямо из MediaStore по id ассета — БЕЗ чтения файла с диска.
/// Так делают быстрые галереи: система уже держит миниатюры в своём кэше,
/// а на Android 11+ прямой доступ к путям вне приложения закрыт. Один и тот же
/// подход и для сетки (маленький размер), и для просмотрщика (крупный, с потолком).

@immutable
class AssetImageKey {
  final String assetId;
  final int size; // потолок большей стороны, px
  const AssetImageKey(this.assetId, this.size);

  @override
  bool operator ==(Object other) =>
      other is AssetImageKey &&
      other.assetId == assetId &&
      other.size == size;

  @override
  int get hashCode => Object.hash(assetId, size);
}

class AssetThumbImage extends ImageProvider<AssetImageKey> {
  final String assetId;
  final int size;
  const AssetThumbImage(this.assetId, {required this.size});

  @override
  Future<AssetImageKey> obtainKey(ImageConfiguration configuration) async =>
      AssetImageKey(assetId, size);

  @override
  ImageStreamCompleter loadImage(
      AssetImageKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _codec(key, decode),
      scale: 1.0,
      debugLabel: 'asset:${key.assetId}@${key.size}',
    );
  }

  Future<ui.Codec> _codec(AssetImageKey key, ImageDecoderCallback decode) async {
    final a = await AssetEntity.fromId(key.assetId);
    if (a == null) throw StateError('нет ассета ${key.assetId}');
    final bytes = await a.thumbnailDataWithSize(
      ThumbnailSize(key.size, key.size),
      quality: 90,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('нет миниатюры ${key.assetId}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }
}
