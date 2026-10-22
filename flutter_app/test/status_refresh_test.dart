import 'package:checkin_hub/src/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进界面不再每次都打一轮状态接口：10 分钟内直接用库里的值。
void main() {
  test('状态刷新按 10 分钟节流', () {
    final state = AppState();

    expect(state.statusRefreshDue, isTrue, reason: '从未刷新过');

    state.lastStatusRefresh = DateTime.now();
    expect(state.statusRefreshDue, isFalse);

    state.lastStatusRefresh =
        DateTime.now().subtract(const Duration(minutes: 9));
    expect(state.statusRefreshDue, isFalse);

    state.lastStatusRefresh =
        DateTime.now().subtract(const Duration(minutes: 11));
    expect(state.statusRefreshDue, isTrue);
  });
}
