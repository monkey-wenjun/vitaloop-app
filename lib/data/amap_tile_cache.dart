import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// 高德栅格瓦片的磁盘缓存。
///
/// 运动详情只按当前视野取瓦片，不预下载整座城市；用户看过的区域落盘后，
/// 断网再次打开同一条轨迹仍能显示。缓存放在应用支持目录，卸载时随应用一起删除。
class AmapTileCache {
  AmapTileCache._();

  static final AmapTileCache instance = AmapTileCache._();

  static const _folderName = 'amap_tiles';
  static const _maxAge = Duration(days: 90);

  final Map<String, Future<Uint8List?>> _inflight = {};
  Directory? _root;

  Future<Directory?> _rootDir() async {
    if (_root != null) return _root;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/$_folderName');
      if (!await dir.exists()) await dir.create(recursive: true);
      _root = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<File?> _fileFor(String url) async {
    final root = await _rootDir();
    if (root == null) return null;
    final uri = Uri.tryParse(url);
    final z = int.tryParse(uri?.queryParameters['z'] ?? '');
    final x = int.tryParse(uri?.queryParameters['x'] ?? '');
    final y = int.tryParse(uri?.queryParameters['y'] ?? '');
    if (z == null || x == null || y == null) return null;
    // 同一 z/x/y 不同 ltype 是两张完全不同的图（带路名 / 无路名）。
    // 只按 z/x/y 存会导致关掉「显示街道名称」后仍然读到旧的带字瓦片。
    final ltype = uri?.queryParameters['ltype'] ?? '0';
    final prefix = ltype == '0' ? '' : 'lt$ltype/';
    return File('${root.path}/$prefix$z/$x/$y.png');
  }

  Future<Uint8List?> load(String url) {
    return _inflight.putIfAbsent(url, () async {
      try {
        final file = await _fileFor(url);
        if (file != null && await file.exists()) {
          if (await _isFresh(file)) return await file.readAsBytes();
        }
        final bytes = await _download(url);
        if (bytes != null && bytes.isNotEmpty) {
          await _write(file, bytes);
          return bytes;
        }
        if (file != null && await file.exists()) {
          return await file.readAsBytes();
        }
        return null;
      } catch (_) {
        try {
          final file = await _fileFor(url);
          if (file != null && await file.exists()) {
            return await file.readAsBytes();
          }
        } catch (_) {}
        return null;
      } finally {
        _inflight.remove(url);
      }
    });
  }

  Future<bool> _isFresh(File file) async {
    try {
      final age = DateTime.now().difference(await file.lastModified());
      return age <= _maxAge;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> _download(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Vitaloop/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _write(File? file, Uint8List bytes) async {
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<({int bytes, int files})> stats() async {
    final root = await _rootDir();
    if (root == null) return (bytes: 0, files: 0);
    var bytes = 0;
    var files = 0;
    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          files += 1;
          bytes += await entity.length();
        }
      }
    } catch (_) {}
    return (bytes: bytes, files: files);
  }

  Future<void> clear() async {
    final root = await _rootDir();
    if (root == null) return;
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
    _root = null;
  }
}

/// 先读磁盘、未命中再下载的瓦片图片源。
class AmapTileImageProvider extends ImageProvider<AmapTileImageProvider> {
  const AmapTileImageProvider(this.url);

  final String url;

  @override
  Future<AmapTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    AmapTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadAsync(
    AmapTileImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await AmapTileCache.instance.load(key.url);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('地图瓦片不可用');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is AmapTileImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'AmapTileImageProvider($url)';
}
