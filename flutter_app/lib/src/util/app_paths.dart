import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 运行期数据目录解析，与 Python `paths.py` 的语义保持一致。
class AppPaths {
  AppPaths._();

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
