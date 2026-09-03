/// Maps BLE RSSI (dBm) onto 0..1 closer. Typical phone RX of the XIAO radio.
double pendantProximity(int rssi) {
  const far = -95.0;
  const near = -42.0;
  return ((rssi - far) / (near - far)).clamp(0.0, 1.0);
}

String pendantProximityLabel(double proximity, {required bool hasSignal}) {
  if (!hasSignal) {
    return 'Not in range';
  }
  if (proximity >= 0.82) {
    return 'Very close';
  }
  if (proximity >= 0.55) {
    return 'Nearby';
  }
  if (proximity >= 0.28) {
    return 'In range';
  }
  return 'Far';
}

/// Haptic gap: slower when far, quicker when the signal is strong.
Duration pendantProximityHaptic(double proximity, {required bool hasSignal}) {
  if (!hasSignal) {
    return const Duration(milliseconds: 1400);
  }
  final ms = (920 - 760 * proximity).round().clamp(140, 920);
  return Duration(milliseconds: ms);
}
