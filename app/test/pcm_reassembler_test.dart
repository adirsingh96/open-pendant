import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/audio/wav_writer.dart';
import 'package:openpendant/ble/pendant_ble.dart';
import 'package:openpendant/ble/pcm_reassembler.dart';

void main() {
  test('reassembles out-of-order fragments', () {
    final r = PcmReassembler();
    r.addNotify([1, 0, 1, 2, 0x33, 0x44]);
    r.addNotify([1, 0, 0, 2, 0x11, 0x22]);
    expect(r.pcmBytes(), [0x11, 0x22, 0x33, 0x44]);
  });

  test('does not emit a block if a middle fragment is missing', () {
    final r = PcmReassembler();
    r.addNotify([1, 0, 0, 3, 0x11]);
    r.addNotify([1, 0, 2, 3, 0x33]);
    expect(r.complete, isEmpty);
  });

  test('addRaw appends host-mic PCM', () {
    final r = PcmReassembler();
    r.addRaw([1, 2]);
    r.addRaw([3, 4]);
    expect(r.pcmBytes(), [1, 2, 3, 4]);
    expect(r.pcmByteLength, 4);
  });

  test('replaceWith keeps a PCM prefix', () {
    final r = PcmReassembler();
    r.addNotify([1, 0, 0, 1, 1, 2, 3, 4, 5, 6]);
    r.replaceWith([1, 2]);
    expect(r.pcmBytes(), [1, 2]);
    expect(r.pcmByteLength, 2);
  });

  test('wav header is 44 bytes plus pcm', () {
    final wav = pcmToWav(pcm: [0, 0, 1, 0]);
    expect(wav.length, 48);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  });

  test('status parse keeps old 6-byte payloads and reads button bytes', () {
    final old = PendantStatus.parse([2, 10, 0, 3, 0xD0, 0x0E]);
    expect(old, isNotNull);
    expect(old!.micRunning, isTrue);
    expect(old.buttonEvent, 0);
    expect(old.buttonSeq, 0);

    final next = PendantStatus.parse([2, 10, 0, 3, 0xD0, 0x0E, 2, 5]);
    expect(next!.buttonLabel, 'double press');
    expect(next.buttonSeq, 5);
    expect(next.noteHeld, isFalse);

    final held = PendantStatus.parse([34, 10, 0, 3, 0xD0, 0x0E, 3, 6]);
    expect(held!.noteHeld, isTrue);
    expect(held.buttonLabel, 'long press');
    expect(
      PendantStatus.parse([2, 0, 0, 0, 0, 0, 4, 7])!.buttonLabel,
      'long release',
    );
  });
}
