const autoRerouteMinDistanceM = 80.0;
const autoRerouteDelayMs = 12000;
const autoRerouteCooldownMs = 25000;

bool shouldAutoReroute({
  required bool enabled,
  required bool offRoute,
  required double offRouteM,
  required int? offRouteSinceMs,
  required int nowMs,
  required int lastRerouteMs,
}) {
  if (!enabled ||
      !offRoute ||
      offRouteM < autoRerouteMinDistanceM ||
      offRouteSinceMs == null) {
    return false;
  }
  if (nowMs - offRouteSinceMs < autoRerouteDelayMs) return false;
  return lastRerouteMs == 0 || nowMs - lastRerouteMs >= autoRerouteCooldownMs;
}
