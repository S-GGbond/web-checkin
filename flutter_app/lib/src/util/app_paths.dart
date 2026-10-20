import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 运行期数据目录解析，与 Python `paths.py` 的语义保持一致。
class AppPaths {
  AppPaths._();

  /// 跨平台用户主目录：Linux / macOS 用 `HOME`，Windows 用 `USERPROFILE`
  /// （Windows 上 `HOME` 一般不存在）。两者都取不到时退回临时目录，
  /// 保证永远返回绝对路径，不会退化成相对路径。
  static String get home {
    for (final value in [
      Platform.environment['HOME'],
      Platform.environment['USERPROFILE'],
    ]) {
      if (value != null && value.isNotEmpty) return value;
    }
    return Directory.systemTemp.path;
  }

  static Future<Directory> dataDir() async {
    final override = Platform.environment['WEB_CHECKIN_HOME'];
    if (override != null && override.isNotEmpty) {
      final dir = Directory(override);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final support = await getApplicationSupportDirectory();
    if (!await support.exists()) await support.create(recursive: true);
    return support;
  }

  /// Trae 设备指纹文件，可用 `TRAE_IDENTITY_PATH` 覆盖。
  static Future<File> traeIdentityFile() async {
    final override = Platform.environment['TRAE_IDENTITY_PATH'];
    final path = (override != null && override.isNotEmpty)
        ? override
        : p.join((await dataDir()).path, 'trae-identity.json');
    return File(path);
  }
}
