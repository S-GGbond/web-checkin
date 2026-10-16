import 'dart:convert';

/// 稳定的 JSON 编码：对 Map 的键排序，便于与 Python 版写入的
/// `json.dumps(..., sort_keys=True)` 保持一致的字符串形态。
String jsonEncodeSorted(Object? value) {
  return jsonEncode(_sortDeep(value));
}

Object? _sortDeep(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final key in keys) key: _sortDeep(value[key])};
  }
  if (value is List) {
    return value.map(_sortDeep).toList();
  }
  return value;
}

/// 把任意对象安全地转成 `Map<String, dynamic>`。
Map<String, dynamic> asStringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}
