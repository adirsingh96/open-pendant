import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/audio/find_phone.dart';

void main() {
  test('locate tone is a looping WAV chirp', () {
    final wav = findPhoneToneWav();
    expect(wav.length, greaterThan(44));
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final dataSize =
        wav[40] | (wav[41] << 8) | (wav[42] << 16) | (wav[43] << 24);
    expect(dataSize, wav.length - 44);
    expect(dataSize, greaterThan(2000));
  });
}
