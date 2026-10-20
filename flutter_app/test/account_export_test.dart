import 'dart:convert';
import 'dart:io';

import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/services/account_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('account-export-test-');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 忽略。
    }
  });

  test('导出两个平台的账号为 JSON', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);

    await db.upsertAccount(
      provider: PlatformKind.trae,
      externalId: 'trae-1',
      displayName: '我的 Trae',
      endpoint: 'https://api.trae.cn',
      credential: base64Encode([1, 2, 3]),
      label: '主力',
    );
    await db.upsertAccount(
      provider: PlatformKind.workbuddy,
      externalId: 'wb-1',
      displayName: '工作号',
      endpoint: 'https://www.workbuddy.cn',
      credential: jsonEncode({'auth': {'token': 't'}, 'account': {}, 'snapshot': {}}),
    );

    final rows = await db.listAccountRows();
    final out = p.join(temp.path, 'accounts.json');
    final result = await AccountExporter.exportJson(
      rows: rows,
      outputPath: out,
    );

    expect(result.count, 2);
    expect(result.path, out);
    final json =
        jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>;
    expect(json['format'], 'accounts');
    expect(json['version'], AccountExporter.formatVersion);
    final accounts = (json['accounts'] as List).cast<Map<String, Object?>>();
    final trae = accounts.firstWhere((a) => a['provider'] == 'trae');
    final workbuddy =
        accounts.firstWhere((a) => a['provider'] == 'workbuddy');

    expect(trae['externalId'], 'trae-1');
    expect(trae['label'], '主力');
    // 不是 JSON 的登录态保留原字符串，JSON 的原样展开。
    expect(trae['credential'], base64Encode([1, 2, 3]));
    expect((workbuddy['credential'] as Map)['auth'], isA<Map>());
    expect(trae['schedule'], isA<Map>());
  });

  test('导出的 JSON 能导回，重复导入是更新而不是新增', () async {
    final source = await AppDatabase.openInMemory();
    addTearDown(source.close);
    await source.upsertAccount(
      provider: PlatformKind.trae,
      externalId: 'trae-1',
      displayName: '我的 Trae',
      endpoint: 'https://api.trae.cn',
      credential: '{"token":"t"}',
      label: '主力',
    );
    await source.upsertAccount(
      provider: PlatformKind.workbuddy,
      externalId: 'wb-1',
      displayName: '工作号',
      endpoint: 'https://www.workbuddy.cn',
      credential: '{"auth":{}}',
    );
    final out = p.join(temp.path, 'accounts.json');
    await AccountExporter.exportJson(
      rows: await source.listAccountRows(),
      outputPath: out,
    );

    final target = await AppDatabase.openInMemory();
    addTearDown(target.close);
    final first = await AccountExporter.importJson(path: out, db: target);
    expect(first.added, 2);
    expect(first.updated, 0);
    expect(first.skipped, 0);

    final accounts = await target.listAccounts();
    expect(accounts.length, 2);
    final trae = accounts.firstWhere((a) => a.provider == PlatformKind.trae);
    expect(trae.displayName, '我的 Trae');
    expect(trae.label, '主力');
    expect(await target.listAccountRows(), hasLength(2));

    // 再导一次：同 provider + externalId 视为同一账号。
    final second = await AccountExporter.importJson(path: out, db: target);
    expect(second.added, 0);
    expect(second.updated, 2);
    expect((await target.listAccounts()).length, 2);
  });

  test('不是账号文件时给出明确错误', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final bad = p.join(temp.path, 'bad.json');
    File(bad).writeAsStringSync('{"hello":1}');
    await expectLater(
      AccountExporter.importJson(path: bad, db: db),
      throwsA(isA<AccountImportException>()),
    );
    await expectLater(
      AccountExporter.importJson(path: p.join(temp.path, 'nope.json'), db: db),
      throwsA(isA<AccountImportException>()),
    );
  });
}