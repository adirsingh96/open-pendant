import 'dart:typed_data';

List<int> pcmToWav({
  required List<int> pcm,
  int sampleRate = 16000,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataSize = pcm.length;
  final buffer = BytesBuilder();
  void ascii(String s) => buffer.add(s.codeUnits);
  void u16(int v) {
    buffer.add([v & 0xff, (v >> 8) & 0xff]);
  }

  void u32(int v) {
    buffer.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  }

  ascii('RIFF');
  u32(36 + dataSize);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(channels);
  u32(sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  ascii('data');
  u32(dataSize);
  buffer.add(pcm);
  return buffer.toBytes();
}
