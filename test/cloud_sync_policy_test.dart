import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/cloud_sync_policy.dart';

void main() {
  test('normal deltas stay incremental', () {
    expect(
      shouldUploadFullSnapshot(pendingEntries: 120, deltaChars: 2 << 20),
      isFalse,
    );
  });

  test('large backlog or oversized delta falls back to a full snapshot', () {
    expect(
      shouldUploadFullSnapshot(pendingEntries: cloudFullSnapshotBacklog + 1),
      isTrue,
    );
    expect(
      shouldUploadFullSnapshot(
        pendingEntries: 1,
        deltaChars: cloudMaxDeltaChars + 1,
      ),
      isTrue,
    );
  });
}
