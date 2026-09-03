import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/ble/pendant_proximity.dart';

void main() {
  test('proximity is 0 far and 1 at contact RSSI', () {
    expect(pendantProximity(-95), closeTo(0, 1e-9));
    expect(pendantProximity(-42), closeTo(1, 1e-9));
    expect(pendantProximity(-30), 1.0);
    expect(pendantProximity(-120), 0.0);
  });

  test('mid-room RSSI is in the middle of the scale', () {
    final p = pendantProximity(-68);
    expect(p, greaterThan(0.4));
    expect(p, lessThan(0.7));
  });

  test('labels follow proximity bands', () {
    expect(
      pendantProximityLabel(0.9, hasSignal: true),
      'Very close',
    );
    expect(
      pendantProximityLabel(0.6, hasSignal: true),
      'Nearby',
    );
    expect(
      pendantProximityLabel(0.4, hasSignal: true),
      'In range',
    );
    expect(
      pendantProximityLabel(0.1, hasSignal: true),
      'Far',
    );
    expect(
      pendantProximityLabel(1, hasSignal: false),
      'Not in range',
    );
  });

  test('haptic speeds up as the signal gets stronger', () {
    final far = pendantProximityHaptic(0.1, hasSignal: true);
    final near = pendantProximityHaptic(0.9, hasSignal: true);
    expect(near < far, isTrue);
    expect(
      pendantProximityHaptic(1, hasSignal: false).inMilliseconds,
      greaterThan(near.inMilliseconds),
    );
  });
}
