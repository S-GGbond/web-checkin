import 'package:checkin_hub/src/services/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final parse = CheckinScheduler.parseScheduleTime;

  group('parseScheduleTime', () {
    test('解析合法时间', () {
      expect(parse('09:00'), (9, 0));
      expect(parse('23:59'), (23, 59));
      expect(parse('0:05'), (0, 5));
    });

    test('非法输入回退到默认 09:00', () {
      expect(parse(''), (9, 0));
      expect(parse('abc'), (9, 0));
      expect(parse('24:00'), (9, 0));
      expect(parse('12:60'), (9, 0));
      expect(parse('12'), (9, 0));
    });
  });
}
