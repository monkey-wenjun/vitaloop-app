import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/home_cards.dart';

void main() {
  test('默认首页第一张是今日训练建议，且为全宽卡片', () {
    final layout = HomeCardLayout.defaults;
    expect(layout.order.first, 'advice');
    expect(HomeCardLayout.specOf('advice').size, HomeCardSize.full);
  });

  test('保存的布局会保留顺序和隐藏状态，并补齐新增卡片', () {
    final layout = HomeCardLayout.parse(
      jsonEncode({
        'order': ['sleep', 'advice', 'steps', 'sleep'],
        'hidden': ['steps'],
      }),
    );

    expect(layout.order.take(3), ['sleep', 'advice', 'steps']);
    expect(layout.hidden, {'steps'});
    expect(layout.order.length, HomeCardLayout.knownIds.length);
    expect(layout.order.toSet(), HomeCardLayout.knownIds);
  });

  test('未知卡片和损坏 JSON 不会破坏首页', () {
    final layout = HomeCardLayout.parse(
      jsonEncode({
        'order': ['removed_card', 'weight'],
        'hidden': ['also_removed'],
      }),
    );

    expect(layout.order.first, 'weight');
    expect(layout.hidden, isEmpty);
    expect(HomeCardLayout.parse('{bad json').order.first, 'advice');
  });

  test('拖拽移动会把卡片插到目标位置，传空目标则放到最后', () {
    final moved = HomeCardLayout.move(
      ['advice', 'readiness', 'steps'],
      'steps',
      'advice',
    );
    expect(moved, ['steps', 'advice', 'readiness']);

    final last = HomeCardLayout.move(moved, 'steps', null);
    expect(last, ['advice', 'readiness', 'steps']);
  });
}
