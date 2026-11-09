const int cloudFullSnapshotBacklog = 10000;

// Dart string length counts UTF-16 code units; JSON text here is at most 3
// UTF-8 bytes per unit, so 16 MiB chars stays below the server's 64 MiB limit.
const int cloudMaxDeltaChars = 16 * 1024 * 1024;

bool shouldUploadFullSnapshot({
  required int pendingEntries,
  int deltaChars = 0,
}) =>
    pendingEntries > cloudFullSnapshotBacklog ||
    deltaChars > cloudMaxDeltaChars;
