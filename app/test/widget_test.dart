import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/ble/pcm_reassembler.dart';

void main() {
  test('GATT PCM reassembly still works', () {
    final r = PcmReassembler();
    r.addNotify([0, 0, 0, 1, 1, 2]);
    expect(r.pcmBytes(), [1, 2]);
  });
}
