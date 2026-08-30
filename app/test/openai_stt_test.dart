import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openpendant/stt/openai_stt.dart';

class _FlakyClient extends http.BaseClient {
  _FlakyClient({required this.failTimes});

  final int failTimes;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain();
    calls++;
    if (calls <= failTimes) {
      throw http.ClientException('Connection reset by peer', request.url);
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"text":"hello there"}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  test('isTransientSttError catches connection reset', () {
    expect(
      isTransientSttError(
        http.ClientException(
          'Connection reset by peer',
          Uri.parse('https://api.openai.com/v1/audio/transcriptions'),
        ),
      ),
      isTrue,
    );
    expect(
      isTransientSttError(Exception('gpt-4o-mini-transcribe 401: invalid')),
      isFalse,
    );
  });

  test('retries connection reset then succeeds', () async {
    final dir = await Directory.systemTemp.createTemp('stt');
    addTearDown(() => dir.delete(recursive: true));
    final wav = File('${dir.path}/clip.wav');
    await wav.writeAsBytes([0, 1, 2, 3]);
    final client = _FlakyClient(failTimes: 2);
    final stt = OpenAiStt(client: client, retryPause: Duration.zero);
    final r = await stt.transcribe(
      wav: wav,
      apiKey: 'sk-test',
      startedAt: DateTime.utc(2026, 8, 30),
      fast: true,
    );
    expect(r.text, 'hello there');
    expect(client.calls, 3);
  });
}
