import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/navigation_reroute_policy.dart';

void main() {
  test('偏航距离不足或未持续足够久时不重算', () {
    expect(
      shouldAutoReroute(
        enabled: true,
        offRoute: true,
        offRouteM: 79.9,
        offRouteSinceMs: 0,
        nowMs: 30000,
        lastRerouteMs: 0,
      ),
      isFalse,
    );
    expect(
      shouldAutoReroute(
        enabled: true,
        offRoute: true,
        offRouteM: 100,
        offRouteSinceMs: 10000,
        nowMs: 21999,
        lastRerouteMs: 0,
      ),
      isFalse,
    );
  });

  test('持续偏航后触发，并遵守重算冷却时间', () {
    expect(
      shouldAutoReroute(
        enabled: true,
        offRoute: true,
        offRouteM: 100,
        offRouteSinceMs: 10000,
        nowMs: 22000,
        lastRerouteMs: 0,
      ),
      isTrue,
    );
    expect(
      shouldAutoReroute(
        enabled: true,
        offRoute: true,
        offRouteM: 100,
        offRouteSinceMs: 30000,
        nowMs: 44999,
        lastRerouteMs: 20000,
      ),
      isFalse,
    );
    expect(
      shouldAutoReroute(
        enabled: false,
        offRoute: true,
        offRouteM: 100,
        offRouteSinceMs: 0,
        nowMs: 30000,
        lastRerouteMs: 0,
      ),
      isFalse,
    );
  });
}
