import 'package:controller/services/clock_out_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  tzdata.initializeTimeZones();
  test('clockIn plus 9 or 12 hours, boundary and cumulative duration', () {
    final now = DateTime.utc(2026, 10, 24, 9); // Shanghai 17:00
    final data = ClockOutData('09:30:00', false, now);
    expect(data.label(now, 9, 'Asia/Shanghai'), '还有1h30m下班');
    expect(data.label(now, 12, 'Asia/Shanghai'), '还有4h30m下班');
    expect(
      data.label(
        now.add(const Duration(hours: 1, minutes: 30)),
        9,
        'Asia/Shanghai',
      ),
      '可以下班了',
    );
    expect(
      data.label(now.add(const Duration(hours: 2)), 9, 'Asia/Shanghai'),
      '可以下班了',
    );
  });
  test('missing, rest day and yesterday cannot yield false countdown', () {
    final now = DateTime.utc(2026, 10, 24, 9);
    expect(
      ClockOutData(null, false, now).label(now, 9, 'Asia/Shanghai'),
      '下班：尚未打卡',
    );
    expect(
      ClockOutData(null, true, now).label(now, 9, 'Asia/Shanghai'),
      '下班：尚未打卡',
    );
    expect(
      ClockOutData('99:00:00', false, now).label(now, 9, 'Asia/Shanghai'),
      '下班：打卡时间异常',
    );
    expect(
      ClockOutData(
        '09:00:00',
        false,
        now.subtract(const Duration(days: 1)),
      ).label(now, 9, 'Asia/Shanghai'),
      '下班：等待更新',
    );
  });
  test(
    'weekend and rest flag still use clockIn and metrics preserve zero and decimals',
    () {
      final now = DateTime.utc(2026, 10, 24, 9); // Saturday
      final data = ClockOutData.fromJson({
        'clockInTime': '09:30:00',
        'isRestDay': true,
        'totalStruggleOt': 0,
        'striver': 12.5,
        'lateAndEarlyRemaining': '120',
      }, now);
      expect(data.label(now, 9, 'Asia/Shanghai'), '还有1h30m下班');
      expect(data.metrics, 'WK:0 ALL:12.5 S:120');
      expect(ClockOutData.fromJson({}, now).metrics, 'WK:-- ALL:-- S:--');
    },
  );
  test('import endpoint and token only from existing Swift format', () {
    final config = ClockOutService.importSwift('''
    guard let url = URL(string: "https://example.com/getUserClock?userId=test") else {}
    request.setValue("test-token", forHTTPHeaderField: "x-access-token")
    ''');
    expect(config, {
      'clock_url': 'https://example.com/getUserClock?userId=test',
      'clock_token': 'test-token',
    });
  });
}
