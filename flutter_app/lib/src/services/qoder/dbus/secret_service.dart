import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 读取系统钥匙环失败（无会话总线、无该条目、条目被锁等）。
class SecretServiceException implements Exception {
  SecretServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 极简 D-Bus 客户端 + Secret Service（org.freedesktop.secrets）。
///
/// 只为一件小事服务：取 Chrome 系浏览器的 "Safe Storage" 口令（解密 Cookies
/// 库里的 v11 条目要用）。之所以自带实现：
/// - secret-tool 属于 libsecret-tools，很多发行版默认不装；
/// - gdbus call 每条命令都是一条新连接，而 Secret Service 的 session 绑定在
///   连接上，第二次调用就会报 NoSession。
class SecretService {
  SecretService._(this._conn);

  final _DBusConnection _conn;

  static const _destination = 'org.freedesktop.secrets';
  static const _root = '/org/freedesktop/secrets';

  /// 连接会话总线；没有可用的总线时抛 [SecretServiceException]。
  static Future<SecretService> connect() async {
    final address =
        Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? _fallbackAddress();
    try {
      final socket = await _openUnix(address);
      final conn = _DBusConnection(socket);
      await conn.authenticate();
      await conn.hello();
      return SecretService._(conn);
    } on SecretServiceException {
      rethrow;
    } catch (error) {
      throw SecretServiceException('无法连接系统钥匙环：$error');
    }
  }

  static String _fallbackAddress() {
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtime != null && runtime.isNotEmpty) return 'unix:path=$runtime/bus';
    return 'unix:path=/run/user/$_uid/bus';
  }

  static final int _uid = _currentUid();

  static int _currentUid() {
    try {
      final status = File('/proc/self/status').readAsLinesSync();
      for (final line in status) {
        if (!line.startsWith('Uid:')) continue;
        return int.tryParse(line.split(RegExp(r'\s+'))[1]) ?? 0;
      }
    } catch (_) {
      // 没有 /proc 时只能用 0 兜底。
    }
    return 0;
  }

  static Future<Socket> _openUnix(String address) async {
    final entry = address
        .split(';')
        .map((part) => part.trim())
        .firstWhere((part) => part.startsWith('unix:'), orElse: () => '');
    if (entry.isEmpty) {
      throw SecretServiceException('不支持的会话总线地址：$address');
    }
    final params = <String, String>{};
    for (final part in entry.substring('unix:'.length).split(',')) {
      final at = part.indexOf('=');
      if (at <= 0) continue;
      params[part.substring(0, at)] = part.substring(at + 1);
    }
    final path = params['path'];
    if (path != null && path.isNotEmpty) {
      return Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
    }
    final abstract = params['abstract'];
    if (abstract != null && abstract.isNotEmpty) {
      return Socket.connect(
        InternetAddress('\u0000$abstract', type: InternetAddressType.unix),
        0,
      );
    }
    throw SecretServiceException('会话总线地址缺少 path/abstract：$address');
  }

  /// 按属性检索条目并取出全部密钥（同一检索可能命中多条，调用方逐个尝试）。
  ///
  /// 未解锁的条目会被忽略：Chrome 的 Safe Storage 在登录后由钥匙环自动解锁。
  Future<List<Uint8List>> secretsFor(Map<String, String> attributes) async {
    final searched = await _conn.request(
      path: _root,
      interface: 'org.freedesktop.Secret.Service',
      member: 'SearchItems',
      signature: 'a{ss}',
      writeBody: (w) {
        final mark = w.beginArray(8);
        for (final entry in attributes.entries) {
          w.align(8);
          w.string(entry.key);
          w.string(entry.value);
        }
        w.endArray(mark);
      },
    );
    final paths = <String>[
      ..._strings(searched[0]),
      ..._strings(searched[1]),
    ];
    if (paths.isEmpty) return const [];

    final opened = await _conn.request(
      path: _root,
      interface: 'org.freedesktop.Secret.Service',
      member: 'OpenSession',
      signature: 'sv',
      writeBody: (w) {
        w.string('plain');
        w.variant('s', () => w.string(''));
      },
    );
    final session = opened[1];
    if (session is! String || session.isEmpty) {
      throw SecretServiceException('钥匙环未返回会话路径');
    }

    final secrets = await _conn.request(
      path: _root,
      interface: 'org.freedesktop.Secret.Service',
      member: 'GetSecrets',
      signature: 'aoo',
      writeBody: (w) {
        // ao 的元素是对象路径（4 对齐），不能按头部 struct 的 8 对齐。
        final mark = w.beginArray(4);
        for (final path in paths) {
          w.objectPath(path);
        }
        w.endArray(mark);
        w.objectPath(session);
      },
    );

    final values = <Uint8List>[];
    final map = secrets.first;
    if (map is Map) {
      for (final item in map.values) {
        // 结构为 (o session, ay params, ay value, s content_type)。
        final fields = item is List ? item : const [];
        if (fields.length >= 3 && fields[2] is List) {
          values.add(Uint8List.fromList((fields[2] as List).cast<int>()));
        }
      }
    }
    return values;
  }

  Future<void> close() => _conn.close();

  static Iterable<String> _strings(Object? value) =>
      value is List ? value.whereType<String>() : const <String>[];
}

/// 一条 D-Bus 连接：认证、发送方法调用、按 serial 配对返回。
class _DBusConnection {
  _DBusConnection(this._socket) {
    _subscription = _socket.listen(
      _inbox.add,
      onError: (Object error) => _inbox.fail(error),
      onDone: () => _inbox.fail(SecretServiceException('会话总线连接已断开')),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final _Inbox _inbox = _Inbox();
  late final StreamSubscription<Uint8List> _subscription;
  int _serial = 0;
  bool _authed = false;

  Future<void> authenticate() async {
    _socket.add(const [0]);
    final hexUid = SecretService._uid
        .toString()
        .codeUnits
        .map((code) => code.toRadixString(16).padLeft(2, '0'))
        .join();
    _socket.add(utf8.encode('AUTH EXTERNAL $hexUid\r\n'));
    await _socket.flush();

    while (true) {
      final line = await _inbox.readLine().timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw SecretServiceException('会话总线认证超时'),
          );
      if (line.startsWith('OK')) break;
      if (line.startsWith('REJECTED')) {
        throw SecretServiceException('会话总线拒绝认证（D-Bus EXTERNAL）');
      }
      if (line.startsWith('ERROR')) {
        throw SecretServiceException('会话总线认证失败：$line');
      }
      // DATA / AGREE_UNIX_FD 等中间响应，继续读。
    }
    _socket.add(utf8.encode('BEGIN\r\n'));
    await _socket.flush();
    _authed = true;
  }

  Future<List<Object?>> request({
    required String path,
    required String interface,
    required String member,
    required String signature,
    required void Function(_Writer writer) writeBody,
    String? destination,
  }) async {
    if (!_authed) throw SecretServiceException('会话总线尚未认证');

    final body = _Writer();
    writeBody(body);

    final message = _Writer();
    message.byte(0x6c); // 'l'：小端
    message.byte(1); // method call
    message.byte(0); // flags
    message.byte(1); // protocol version
    final bodyLengthAt = message.reserveU32();
    final serial = ++_serial;
    message.u32(serial);

    final fieldsAt = message.reserveU32();
    message.align(8);
    final fieldsStart = message.length;
    // 报文头里的每个字段都是 (字节码, variant)。
    void field(int code, String type, void Function() writeValue) {
      message.align(8);
      message.byte(code);
      message.variant(type, writeValue);
    }

    field(1, 'o', () => message.objectPath(path));
    field(2, 's', () => message.string(interface));
    field(3, 's', () => message.string(member));
    field(6, 's',
        () => message.string(destination ?? SecretService._destination));
    // 空签名不写：libdbus 对空的 SIGNATURE 字段会直接判定报文非法。
    if (signature.isNotEmpty) {
      field(8, 'g', () => message.signature(signature));
    }
    message.patchU32(fieldsAt, message.length - fieldsStart);
    message.align(8);
    message.patchU32(bodyLengthAt, body.length);
    message.addAll(body.toBytes());

    _socket.add(message.toBytes());
    await _socket.flush();

    // 直到收到同一 serial 的 method return / error。
    while (true) {
      final reply = await _inbox.readMessage().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw SecretServiceException('等待钥匙环响应超时'),
          );
      if (reply.replySerial != serial) continue;
      if (reply.type == 3) {
        final name = reply.errorName.isEmpty ? 'unknown' : reply.errorName;
        final text = reply.errorText.isEmpty ? '' : '（$reply.errorText）';
        throw SecretServiceException('钥匙环返回错误：$name$text');
      }
      if (reply.type != 2) continue;
      final reader = _Reader(reply.body);
      return [
        for (final type in _splitSignature(reply.signature)) reader.read(type),
      ];
    }
  }

  /// D-Bus 规定第一条消息必须是 Hello，否则守护进程直接断开连接。
  Future<void> hello() async {
    await request(
      path: '/org/freedesktop/DBus',
      interface: 'org.freedesktop.DBus',
      member: 'Hello',
      signature: '',
      destination: 'org.freedesktop.DBus',
      writeBody: (_) {},
    );
  }

  Future<void> close() async {
    try {
      await _subscription.cancel();
    } catch (_) {
      // 忽略。
    }
    try {
      await _socket.close();
    } catch (_) {
      // 忽略。
    }
  }

  /// 错误消息里的说明字段（签名 s）。
  static String _errorText(_Reader reader) {
    try {
      return reader.read('s')?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }
}

class _Reply {
  _Reply({
    required this.type,
    required this.replySerial,
    required this.signature,
    required this.body,
    required this.errorName,
    required this.errorText,
  });

  final int type;
  final int replySerial;
  final String signature;
  final Uint8List body;
  final String errorName;
  final String errorText;
}

/// 字节收件箱：认证阶段按行读，之后按 D-Bus 报文读。
class _Inbox {
  final List<int> _buffer = <int>[];
  Completer<void>? _waiter;
  Object? _error;

  void add(Uint8List data) {
    _buffer.addAll(data);
    _waiter?.complete();
    _waiter = null;
  }

  void fail(Object error) {
    _error ??= error;
    _waiter?.complete();
    _waiter = null;
  }

  Future<void> _waitFor(int Function() available) async {
    while (available() <= 0) {
      if (_error != null) throw _error!;
      final completer = Completer<void>();
      _waiter = completer;
      await completer.future;
    }
  }

  Future<String> readLine() async {
    await _waitFor(() {
      for (var i = 0; i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 0x0d && _buffer[i + 1] == 0x0a) return i;
      }
      return 0;
    });
    var end = 0;
    for (var i = 0; i + 1 < _buffer.length; i++) {
      if (_buffer[i] == 0x0d && _buffer[i + 1] == 0x0a) {
        end = i;
        break;
      }
    }
    final line = latin1.decode(_buffer.sublist(0, end));
    _buffer.removeRange(0, end + 2);
    return line;
  }

  Future<_Reply> readMessage() async {
    await _waitFor(() => _buffer.length >= 16 ? 1 : 0);
    final header = Uint8List.fromList(_buffer.sublist(0, 16));
    final data = ByteData.sublistView(header);
    final type = header[1];
    final bodyLength = data.getUint32(4, Endian.little);
    final fieldsLength = data.getUint32(12, Endian.little);
    final headerLength = _roundUp(16 + fieldsLength, 8);
    final total = headerLength + bodyLength;
    await _waitFor(() => _buffer.length >= total ? 1 : 0);

    final message = Uint8List.fromList(_buffer.sublist(0, total));
    _buffer.removeRange(0, total);

    final reader =
        _Reader(Uint8List.sublistView(message, 16, 16 + fieldsLength));
    var signature = '';
    var errorName = '';
    // REPLY_SERIAL 是头字段 5；offset 8 上的只是本条消息自己的 serial。
    var replySerial = -1;
    while (reader.hasMore) {
      reader.align(8); // 每个头字段都是 8 对齐的 struct(yv)
      final code = reader.byte();
      final value = reader.read('v');
      if (code == 8 && value is String) signature = value;
      if (code == 4 && value is String) errorName = value;
      if (code == 5 && value is int) replySerial = value;
    }
    final body = Uint8List.sublistView(message, headerLength, total);
    final text = type == 3 ? _DBusConnection._errorText(_Reader(body)) : '';
    return _Reply(
      type: type,
      replySerial: replySerial,
      signature: signature,
      body: body,
      errorName: errorName,
      errorText: text,
    );
  }
}

int _roundUp(int value, int alignment) =>
    (value + alignment - 1) & ~(alignment - 1);

/// 把签名拆成若干个完整类型（"aoo" → ["ao", "o"]）。
List<String> _splitSignature(String signature) {
  final types = <String>[];
  var rest = signature;
  while (rest.isNotEmpty) {
    final type = _firstType(rest);
    if (type.isEmpty) break;
    types.add(type);
    rest = rest.substring(type.length);
  }
  return types;
}

/// 取签名里的第一个完整类型（含数组前缀与容器括号）。
String _firstType(String signature) {
  if (signature.isEmpty) return '';
  final head = signature[0];
  if (head == 'a') {
    final inner = _firstType(signature.substring(1));
    return inner.isEmpty ? '' : 'a$inner';
  }
  if (head == '(' || head == '{') {
    var depth = 0;
    for (var i = 0; i < signature.length; i++) {
      final ch = signature[i];
      if (ch == '(' || ch == '{') depth++;
      if (ch == ')' || ch == '}') {
        depth--;
        if (depth == 0) return signature.substring(0, i + 1);
      }
    }
    return '';
  }
  return head;
}

int _alignmentOf(String type) {
  if (type.isEmpty) return 1;
  switch (type[0]) {
    case 'y':
    case 'g':
    case 'v':
      return 1;
    case 'n':
    case 'q':
    case 'b':
    case 'i':
    case 'u':
    case 's':
    case 'o':
    case 'a':
      return 4;
    default:
      return 8; // x t d ( {
  }
}

/// 数组写入标记：长度字段位置 + 数据起点。
class _ArrayMark {
  const _ArrayMark(this.lengthAt, this.dataStart);

  final int lengthAt;
  final int dataStart;
}

class _Writer {
  Uint8List _buffer = Uint8List(256);
  int _length = 0;

  int get length => _length;

  void _ensure(int extra) {
    if (_length + extra <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < _length + extra) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
  }

  void byte(int value) {
    _ensure(1);
    _buffer[_length++] = value & 0xff;
  }

  void align(int alignment) {
    while (_length % alignment != 0) {
      byte(0);
    }
  }

  void u32(int value) {
    align(4);
    _ensure(4);
    ByteData.sublistView(_buffer)
        .setUint32(_length, value & 0xffffffff, Endian.little);
    _length += 4;
  }

  int reserveU32() {
    final at = _length;
    u32(0);
    return at;
  }

  void patchU32(int at, int value) {
    ByteData.sublistView(_buffer)
        .setUint32(at, value & 0xffffffff, Endian.little);
  }

  void addAll(Uint8List data) {
    _ensure(data.length);
    _buffer.setRange(_length, _length + data.length, data);
    _length += data.length;
  }

  void string(String value) {
    final bytes = utf8.encode(value);
    u32(bytes.length);
    _ensure(bytes.length + 1);
    _buffer.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
    byte(0);
  }

  void objectPath(String value) => string(value);

  void signature(String value) {
    final bytes = utf8.encode(value);
    byte(bytes.length);
    _ensure(bytes.length + 1);
    _buffer.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
    byte(0);
  }

  void variant(String innerSignature, void Function() writeValue) {
    signature(innerSignature);
    align(_alignmentOf(innerSignature));
    writeValue();
  }

  /// 数组起点：写长度占位并记下数据起点；元素各自保证对齐。
  _ArrayMark beginArray(int elementAlignment) {
    final lengthAt = reserveU32();
    align(elementAlignment);
    return _ArrayMark(lengthAt, _length);
  }

  void endArray(_ArrayMark mark) {
    // 数组长度只算数据本身，不含数据前的对齐填充与尾部填充。
    patchU32(mark.lengthAt, _length - mark.dataStart);
  }

  Uint8List toBytes() => Uint8List.sublistView(_buffer, 0, _length);
}

class _Reader {
  _Reader(this._buffer);

  final Uint8List _buffer;
  int _offset = 0;
  late final ByteData _data = ByteData.sublistView(_buffer);

  bool get hasMore => _offset < _buffer.length;

  void align(int alignment) {
    _offset = _roundUp(_offset, alignment);
  }

  int byte() {
    if (_offset >= _buffer.length) throw const FormatException('D-Bus 数据越界');
    return _buffer[_offset++];
  }

  int u32() {
    align(4);
    final value = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  String _string() {
    final length = u32();
    final value = utf8.decode(
      _buffer.sublist(_offset, _offset + length),
      allowMalformed: true,
    );
    _offset += length + 1; // 跳过结尾 NUL
    return value;
  }

  String _signatureString() {
    final length = byte();
    final value = utf8.decode(
      _buffer.sublist(_offset, _offset + length),
      allowMalformed: true,
    );
    _offset += length + 1;
    return value;
  }

  Object? read(String type) {
    if (type.isEmpty) return null;
    switch (type[0]) {
      case 'y':
        return byte();
      case 'b':
        return u32() != 0;
      case 's':
      case 'o':
        return _string();
      case 'g':
        return _signatureString();
      case 'u':
        return u32();
      case 'i':
        align(4);
        final value = _data.getInt32(_offset, Endian.little);
        _offset += 4;
        return value;
      case 't':
      case 'x':
        align(8);
        final value = _data.getUint64(_offset, Endian.little);
        _offset += 8;
        return value;
      case 'v':
        return read(_signatureString());
      case 'a':
        final element = type.substring(1);
        final length = u32();
        align(_alignmentOf(element));
        final end = _offset + length;
        if (element.startsWith('{')) {
          final map = <Object?, Object?>{};
          while (_offset < end) {
            final entry = read(element) as List;
            map[entry[0]] = entry[1];
          }
          return map;
        }
        final list = <Object?>[];
        while (_offset < end) {
          list.add(read(element));
        }
        return list;
      case '(':
      case '{':
        align(8);
        return [
          for (final member
              in _splitSignature(type.substring(1, type.length - 1)))
            read(member),
        ];
    }
    throw FormatException('不支持的 D-Bus 类型：$type');
  }
}
