import 'dart:typed_data';
import 'package:controller/services/ble_protocol.dart';
import 'package:controller/services/youtrack_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expiration boundaries and missing date', () {
    final now = DateTime.utc(2026, 10, 23);
    YtIssue issue(Duration delta) =>
        YtIssue('A', '', now.add(delta).millisecondsSinceEpoch);
    expect(issue(Duration.zero).colorIndex(now, 24), 3);
    expect(issue(const Duration(hours: -1)).colorIndex(now, 24), 3);
    expect(issue(const Duration(hours: 2)).colorIndex(now, 24), 3);
    expect(issue(const Duration(hours: 2, seconds: 1)).colorIndex(now, 24), 2);
    expect(issue(const Duration(hours: 2)).colorIndex(now, 1), 3);
    expect(issue(const Duration(hours: 24)).colorIndex(now, 24), 2);
    expect(issue(const Duration(hours: 24, seconds: 1)).colorIndex(now, 24), 0);
    expect(YtIssue('B', '', null).colorIndex(now, 24), 0);
    expect(
      YtIssue.parse({
        'id': 'A',
        'customFields': [
          {'name': 'EXPIRATION TIME', 'value': 123},
        ],
      }, 'Expiration time').expiration,
      123,
    );
  });
  testWidgets('overlay preserves base and pixels above strip', (tester) async {
    await tester.runAsync(() async {
      final base = Uint8List(BleProtocol.imageBytes)
        ..fillRange(0, BleProtocol.imageBytes, 0xaa);
      final output = await overlayYt(
        base,
        [],
        DateTime.utc(2026),
        24,
        '2026-01-01 00:00',
      );
      expect(base.every((e) => e == 0xaa), isTrue);
      expect(output.length, base.length);
      expect(
        output.sublist(0, 288 * BleProtocol.rowBytes),
        base.sublist(0, 288 * BleProtocol.rowBytes),
      );
      expect(output, isNot(base));
    });
  });
  testWidgets(
    'four rotations and nine anchors stay inside their selected rectangle',
    (tester) async {
      await tester.runAsync(() async {
        final base = Uint8List(BleProtocol.imageBytes)
          ..fillRange(0, BleProtocol.imageBytes, 0xaa);
        for (final angle in [0, 90, 180, 270]) {
          for (final position in YtConfig.positions.keys) {
            final output = await overlayYt(
              base,
              [
                YtIssue(
                  'DE4-12345',
                  '',
                  DateTime.utc(2025, 12, 31, 23).millisecondsSinceEpoch,
                ),
                YtIssue(
                  'DE4-23456',
                  '',
                  DateTime.utc(2026, 1, 1, 1).millisecondsSinceEpoch,
                ),
                YtIssue(
                  'DE4-34567',
                  '',
                  DateTime.utc(2026, 1, 3).millisecondsSinceEpoch,
                ),
              ],
              DateTime.utc(2026),
              24,
              '2026-01-01 00:00',
              rotation: angle,
              position: position,
            );
            final w = angle % 180 == 0 ? 480 : 264;
            final h = angle % 180 == 0 ? 264 : 480;
            final col = position.endsWith('left')
                ? 0
                : position.endsWith('right')
                ? 2
                : 1;
            final row = position.startsWith('top')
                ? 0
                : position.startsWith('bottom')
                ? 2
                : 1;
            final left = (768 - w) * col ~/ 2, top = (552 - h) * row ~/ 2;
            var changed = 0;
            for (var y = 0; y < 552; y++) {
              for (var x = 0; x < 768; x++) {
                final i = y * 192 + x ~/ 4, shift = 6 - 2 * (x % 4);
                final pixel = (output[i] >> shift) & 3;
                if (x < left || x >= left + w || y < top || y >= top + h) {
                  if (pixel != 2) {
                    fail('Outside panel changed: $angle $position ($x,$y)');
                  }
                } else if (pixel != 2) {
                  changed++;
                }
              }
            }
            expect(changed, greaterThan(100));
            expect(
              changed,
              lessThan(100000),
              reason: 'No opaque text panel background',
            );
            // Transparent padding inside the text bounds preserves the base too.
            for (final point in [(left, top), (left + w - 1, top + h - 1)]) {
              final x = point.$1, y = point.$2;
              expect((output[y * 192 + x ~/ 4] >> (6 - 2 * (x % 4))) & 3, 2);
            }
          }
        }
        expect(base.every((b) => b == 0xaa), isTrue);
      });
    },
  );
  test(
    'three deadlines show remaining duration, order and independent urgency',
    () {
      final now = DateTime.utc(2026, 10, 23, 0);
      final rows = ytDeadlineRows(
        [
          YtIssue('NONE', '', null),
          YtIssue(
            'LATER',
            '',
            now.add(const Duration(days: 3)).millisecondsSinceEpoch,
          ),
          YtIssue(
            'BLACK',
            '',
            now.add(const Duration(days: 2, minutes: 5)).millisecondsSinceEpoch,
          ),
          YtIssue(
            'YELLOW',
            '',
            now
                .add(const Duration(hours: 3, minutes: 7))
                .millisecondsSinceEpoch,
          ),
          YtIssue(
            'RED',
            '',
            now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
          ),
        ],
        now,
        24,
      );
      expect(rows.map((r) => r.text), [
        '-0h01m  RED',
        '3h07m  YELLOW',
        '48h05m  BLACK',
      ]);
      expect(rows.map((r) => r.colorIndex), [3, 2, 0]);
      expect(
        ytDeadlineRows(
          [
            YtIssue(
              'SOON',
              '',
              now.add(const Duration(seconds: 20)).millisecondsSinceEpoch,
            ),
          ],
          now,
          24,
        ).single.text,
        '0h01m  SOON',
      );
      expect(
        ytDeadlineRows(
          [YtIssue('NOW', '', now.millisecondsSinceEpoch)],
          now,
          24,
        ).single,
        (text: '-0h00m  NOW', colorIndex: 3),
      );

      expect(ytDeadlineRows([], now, 24), isEmpty);
      expect(ytDeadlineRows([YtIssue('NO-DATE', '', null)], now, 24).single, (
        text: '无到期时间  NO-DATE',
        colorIndex: 0,
      ));
    },
  );
  test('pagination and sorting', () async {
    final service = _Pages();
    final issues = await service.issues(YtConfig({}));
    expect(issues.length, 101);
    expect(service.skips, ['0', '100']);
    expect(issues.first.expiration, 1);
    expect(issues.last.expiration, isNull);
  });
}

class _Pages extends YouTrackService {
  final skips = <String>[];
  @override
  Future<dynamic> get(
    YtConfig config,
    String path,
    Map<String, String> query,
  ) async {
    skips.add(query['\$skip']!);
    return query['\$skip'] == '0'
        ? List.generate(100, (i) => {'id': '$i', 'customFields': []})
        : [
            {
              'id': 'last',
              'customFields': [
                {'name': 'Expiration time', 'value': 1},
              ],
            },
          ];
  }
}
