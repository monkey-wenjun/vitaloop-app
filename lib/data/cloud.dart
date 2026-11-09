import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

class CloudAccount {
  const CloudAccount({
    required this.accountId,
    required this.email,
    required this.token,
  });

  final String accountId;
  final String email;
  final String token;
}

class CloudException implements Exception {
  const CloudException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// 可选账号云同步。公开构建不内置服务器；私有构建可通过
/// `--dart-define=VITALOOP_CLOUD_URL=...` 注入。
class CloudApi {
  static const defaultBase = String.fromEnvironment('VITALOOP_CLOUD_URL');
  static String base = defaultBase;
  static const _timeout = Duration(seconds: 20);
  // 健康快照动辄 9 MB+，手机网络上 20 秒根本传不完；超时强断会让服务端只收到
  // 半截 body（旧版服务端还会把它落盘成损坏 JSON）。
  static const _transferTimeout = Duration(minutes: 3);

  static String normalizeBase(String raw) {
    var value = raw.trim();
    if (value.isEmpty) value = defaultBase.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) value = 'https://$value';
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static Future<CloudAccount> register(String email, String password) =>
      _auth('/v1/account/register', email, password);

  static Future<CloudAccount> login(String email, String password) =>
      _auth('/v1/account/login', email, password);

  static Future<CloudAccount> _auth(
    String path,
    String email,
    String password,
  ) async {
    final body = await _request(
      'POST',
      path,
      body: {'email': email, 'password': password},
    );
    final map = jsonDecode(body) as Map<String, dynamic>;
    final token = map['token'] as String? ?? '';
    final id = map['account_id'] as String? ?? '';
    if (token.isEmpty || id.isEmpty) {
      throw const CloudException('服务器没有返回登录会话');
    }
    return CloudAccount(
      accountId: id,
      email: map['email'] as String? ?? email,
      token: token,
    );
  }

  static Future<String?> download(String token) async {
    final body = await _request(
      'GET',
      '/v1/health/data',
      token: token,
      timeout: _transferTimeout,
    );
    final map = jsonDecode(body);
    if (map is! Map<String, dynamic>) return null;
    final tables = map['tables'];
    if (tables is! Map || tables.isEmpty) return null;
    return body;
  }

  static Future<void> upload(String token, String snapshot) async {
    // 健康快照 12MB+，走 Cloudflare 隧道要 ~3 分钟，会被 100 秒代理上限掐断。
    // gzip 后约 1/8，20 秒内能传完；服务端原样存压缩字节。
    // 首次登录的快照可能 80MB+，gzip 放在 isolate 里做，避免卡住 UI 线程。
    final compressed = await Isolate.run(
      () => gzip.encode(utf8.encode(snapshot)),
    );
    await _request(
      'PUT',
      '/v1/health/data',
      token: token,
      rawBytes: compressed,
      extraHeaders: const {'Content-Encoding': 'gzip'},
      timeout: _transferTimeout,
    );
  }

  /// 增量上传：只带本次变化的行和删除主键，由服务端合并进账号快照。
  static Future<void> uploadDelta(String token, String delta) async {
    await _request(
      'PUT',
      '/v1/health/delta',
      token: token,
      rawBody: delta,
      timeout: _transferTimeout,
    );
  }

  /// 运动表格单独传一份明文副本：服务端是 scratch 容器，不能解压 gzip 快照；
  /// 这份数据只用于只读的 /v1/workouts 接口，体积远小于完整健康快照。
  static Future<void> uploadWorkouts(String token, Object block) async {
    await _request(
      'PUT',
      '/v1/health/workouts',
      token: token,
      body: block,
      timeout: _transferTimeout,
    );
  }

  /// 旧版服务端在 `/api/v1/app/config`，新版自建服务走 `/v1/app/config`。
  /// 两个入口都允许匿名尝试；需要账号的部署会在 401 后由调用方带 token 重试。
  static Future<String> appConfig({
    String? token,
    String path = '/api/v1/app/config',
  }) {
    return _request('GET', path, token: token);
  }

  /// 手机移动网络经常只有 IPv4（IPv6 路由是黑洞）。Dart 默认按 DNS 顺序连接，
  /// 先试 IPv6 会一直等到 20s 超时；这里显式 IPv4 优先，再退回其它地址。
  static Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final addresses = await InternetAddress.lookup(uri.host);
    addresses.sort((a, b) {
      final a4 = a.type == InternetAddressType.IPv4 ? 0 : 1;
      final b4 = b.type == InternetAddressType.IPv4 ? 0 : 1;
      return a4.compareTo(b4);
    });
    Object? lastError;
    for (final address in addresses) {
      try {
        final raw = await Socket.connect(
          address,
          uri.port,
          timeout: const Duration(seconds: 5),
        );
        // connectionFactory 绕过了 HttpClient 自带的 TLS 包装，HTTPS 必须自己
        // 在这条已连到 IPv4 的 socket 上做 TLS，host 仍用域名以保证 SNI/证书校验。
        final Socket socket = uri.scheme == 'https'
            ? await SecureSocket.secure(raw, host: uri.host).timeout(_timeout)
            : raw;
        return ConnectionTask.fromSocket(Future.value(socket), () {});
      } catch (e) {
        lastError = e;
      }
    }
    throw SocketException('无法连接 ${uri.host}: ${lastError ?? "没有可用地址"}');
  }

  static Future<HttpClient> _newClient() async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..connectionFactory = _connect;
    return client;
  }

  static Future<String> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    String? rawBody,
    List<int>? rawBytes,
    Map<String, String>? extraHeaders,
    Duration timeout = _timeout,
  }) async {
    final client = await _newClient();
    try {
      final normalizedBase = normalizeBase(base);
      if (normalizedBase.isEmpty) {
        throw const CloudException('请先填写云端服务器地址');
      }
      final uri = Uri.parse('$normalizedBase$path');
      final req = await client.openUrl(method, uri).timeout(_timeout);
      req.headers.contentType = ContentType.json;
      if (token != null && token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      extraHeaders?.forEach(req.headers.set);
      final payload = rawBody ?? (body == null ? null : jsonEncode(body));
      if (payload != null) {
        final bytes = utf8.encode(payload);
        req.contentLength = bytes.length;
        req.add(bytes);
      } else if (rawBytes != null) {
        req.contentLength = rawBytes.length;
        req.add(rawBytes);
      }
      final res = await req.close().timeout(timeout);
      final text = await utf8.decoder.bind(res).join().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final detail = text.trim().isEmpty
            ? 'HTTP ${res.statusCode}'
            : text.trim();
        throw CloudException(_friendly(detail), status: res.statusCode);
      }
      return text;
    } on CloudException {
      rethrow;
    } on TimeoutException {
      throw const CloudException('连接云端超时');
    } on SocketException {
      throw const CloudException('连不上云端，请检查网络');
    } on HandshakeException {
      throw const CloudException('云端 HTTPS 握手失败');
    } finally {
      client.close(force: true);
    }
  }

  static String _friendly(String raw) {
    return switch (raw) {
      'account exists' => '这个邮箱已经注册过，请直接登录',
      'bad credentials' => '邮箱或密码不正确',
      'password too short' => '密码至少 8 位',
      'invalid email' => '邮箱格式不正确',
      'missing email' => '请输入邮箱',
      'missing password' => '请输入密码',
      _ => raw,
    };
  }
}
