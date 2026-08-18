import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/audio/wav_writer.dart';
import 'package:openpendant/ble/pcm_reassembler.dart';

void main() {
  test('reassembles fragmented GATT PCM', () {
    final r = PcmReassembler();
    r.addNotify([1, 0, 0, 2, 0x11, 0x22]);
    r.addNotify([1, 0, 1, 2, 0x33, 0x44]);
    expect(r.complete.length, 1);
    expect(r.pcmBytes(), [0x11, 0x22, 0x33, 0x44]);
    expect(r.seqGaps, 0);
  });

  test('wav header is 44 bytes plus pcm', () {
    final wav = pcmToWav(pcm: [0, 0, 1, 0]);
    expect(wav.length, 48);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  });
}
