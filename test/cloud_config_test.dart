import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/cloud.dart';

void main() {
  test('public build has no default cloud server', () {
    expect(CloudApi.defaultBase, isEmpty);
    expect(CloudApi.normalizeBase(''), isEmpty);
  });

  test('explicit self-hosted server remains supported', () {
    expect(
      CloudApi.normalizeBase('sync.example.com/'),
      'https://sync.example.com',
    );
  });
}
