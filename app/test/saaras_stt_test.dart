import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openpendant/db/models.dart';
import 'package:openpendant/stt/saaras_stt.dart';
import 'package:openpendant/stt/stt_pricing.dart';
import 'package:openpendant/stt/voice_store.dart';

class _StatusClient extends http.BaseClient {
  _StatusClient(this.codes);

  final List<int> codes;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    final code = codes[calls.clamp(0, codes.length - 1)];
    calls++;
    final body = code >= 400
        ? '{"error":{"message":"busy"}}'
        : '{"transcript":"hello there"}';
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      code,
    );
  }
}

void main() {
  test('retries Sarvam 503 then keeps the transcript', () async {
    final dir = await Directory.systemTemp.createTemp('saaras');
    addTearDown(() => dir.delete(recursive: true));
    final wav = File('${dir.path}/clip.wav');
    await wav.writeAsBytes(const [0, 1, 2, 3]);
    final client = _StatusClient([503, 503, 200]);
    final stt = SaarasStt(client: client, retryPause: Duration.zero);
    final r = await stt.transcribe(
      wav: wav,
      apiKey: 'test',
      startedAt: DateTime.utc(2026, 10, 26),
    );
    expect(r.text, 'hello there');
    expect(client.calls, 3);
  });

  test('does not retry a Sarvam 400', () async {
    final dir = await Directory.systemTemp.createTemp('saaras400');
    addTearDown(() => dir.delete(recursive: true));
    final wav = File('${dir.path}/clip.wav');
    await wav.writeAsBytes(const [0, 1, 2, 3]);
    final client = _StatusClient([400]);
    final stt = SaarasStt(client: client, retryPause: Duration.zero);
    await expectLater(
      stt.transcribe(
        wav: wav,
        apiKey: 'test',
        startedAt: DateTime.utc(2026, 10, 26),
      ),
      throwsA(predicate((Object e) => e.toString().contains('REST 400'))),
    );
    expect(client.calls, 1);
  });

  test('recognizes and shortens Saaras missing-key errors', () {
    final error = Exception(
      'saaras:v4 REST 403: No keys added. Please add your server key.',
    );
    expect(isSaarasAuthError(error), isTrue);
    expect(friendlySaarasError(error), contains('saved key'));
  });

  test('friendlySaarasError explains duration limit', () {
    final error = Exception(
      'saaras:v4 REST 400: Audio duration exceeds the maximum limit of 30 seconds',
    );
    expect(isSaarasDurationError(error), isTrue);
    expect(friendlySaarasError(error), contains('too long'));
  });

  test('saarasRestPcmRanges splits long PCM under 12s', () {
    final sixty = 60 * 16000 * 2;
    final ranges = saarasRestPcmRanges(sixty);
    expect(ranges, hasLength(5));
    expect(ranges.first.$1, 0);
    expect(ranges.last.$2, sixty);
    for (final (start, end) in ranges) {
      final secs = (end - start) / (16000 * 2);
      expect(secs, lessThanOrEqualTo(SaarasStt.maxRestSeconds + 1e-9));
      expect((end - start) % 2, 0);
    }
  });

  test('parseSaarasTranscript applies concatOffsetS', () {
    final r = parseSaarasTranscript(
      json: {
        'transcript': 'Second half',
        'timestamps': {
          'words': ['Second'],
          'start_time_seconds': [0.5],
          'end_time_seconds': [1.0],
        },
      },
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      concatOffsetS: 28,
      billedSeconds: 2,
    );
    expect(r.segments.single.startS, closeTo(28.5, 1e-9));
    expect(r.segments.single.endS, closeTo(29.0, 1e-9));
  });

  test('mergeSaarasChunkResults stitches text in order', () {
    final a = parseSaarasTranscript(
      json: {'transcript': 'One'},
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 1,
    );
    final b = parseSaarasTranscript(
      json: {'transcript': 'Two'},
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      concatOffsetS: 28,
      billedSeconds: 1,
    );
    final merged = mergeSaarasChunkResults(
      [a, b],
      model: 'saaras:v4',
      billedSeconds: 2,
    );
    expect(merged.text, 'One Two');
    expect(merged.segments, hasLength(2));
  });

  test('parseSaarasTranscript ignores diarized entries', () {
    final r = parseSaarasTranscript(
      json: {
        'transcript': 'Hello. Question.',
        'diarized_transcript': {
          'entries': [
            {
              'transcript': 'Hello.',
              'start_time_seconds': 0.01,
              'end_time_seconds': 2.5,
              'speaker_id': '0',
            },
            {
              'transcript': 'Question.',
              'start_time_seconds': 2.8,
              'end_time_seconds': 4.2,
              'speaker_id': '1',
            },
          ],
        },
      },
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 5,
    );
    expect(r.segments, hasLength(1));
    expect(r.segments.single.speaker, isNull);
    expect(r.segments.single.text, 'Hello. Question.');
    expect(r.text, 'Hello. Question.');
  });

  test('parseSaarasTranscript prefers transcript over word timestamps', () {
    final r = parseSaarasTranscript(
      json: {
        'transcript': 'Hi there',
        'timestamps': {
          'words': ['Hi', 'there'],
          'start_time_seconds': [0.0, 0.4],
          'end_time_seconds': [0.3, 0.8],
        },
      },
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 1,
    );
    expect(r.segments, hasLength(1));
    expect(r.segments[0].speaker, isNull);
    expect(r.segments[0].text, 'Hi there');
    expect(r.text, 'Hi there');
  });

  test('parseSaarasTranscript keeps Hindi transcript not split words', () {
    final r = parseSaarasTranscript(
      json: {
        'transcript': 'मेरा नाम क्या है',
        'timestamps': {
          'words': ['मे', 'रा', 'नाम'],
          'start_time_seconds': [0.0, 0.2, 0.4],
          'end_time_seconds': [0.2, 0.4, 0.8],
        },
      },
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 1,
    );
    expect(r.text, 'मेरा नाम क्या है');
    expect(r.segments.single.text, 'मेरा नाम क्या है');
  });

  test('applySaarasVoiceTags uses enrolled names', () {
    final unlabeled = parseSaarasTranscript(
      json: {
        'transcript': 'Hi there',
        'timestamps': {
          'words': ['Hi'],
          'start_time_seconds': [0.0],
          'end_time_seconds': [0.3],
        },
      },
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 1,
    );
    final tagged = applySaarasVoiceTags(unlabeled, [
      VoiceProfile(id: '1', name: 'Aditya', wavPath: '/tmp/a.wav'),
    ]);
    expect(tagged.segments.single.speaker, 'Aditya');
    expect(tagged.segments.single.text, 'Hi there');
    expect(tagged.text, startsWith('Aditya:'));

    final diar = parseSaarasTranscript(
      json: {
        'transcript': 'A B',
        'diarized_transcript': {
          'entries': [
            {
              'transcript': 'A',
              'start_time_seconds': 0,
              'end_time_seconds': 1,
              'speaker_id': '0',
            },
            {
              'transcript': 'B',
              'start_time_seconds': 1,
              'end_time_seconds': 2,
              'speaker_id': '1',
            },
          ],
        },
      },
      model: 'saaras:v4',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 2,
    );
    final named = applySaarasVoiceTags(diar, [
      VoiceProfile(id: '1', name: 'Aditya', wavPath: '/tmp/a.wav'),
      VoiceProfile(id: '2', name: 'Sushma', wavPath: '/tmp/b.wav'),
    ]);
    expect(named.segments, hasLength(1));
    expect(named.segments.single.speaker, 'Aditya');
    expect(named.segments.single.text, 'A B');
  });

  test('saarasSpeakerLabel maps SPEAKER_00', () {
    expect(saarasSpeakerLabel('SPEAKER_00'), 'Speaker 1');
    expect(saarasSpeakerLabel(2), 'Speaker 3');
  });

  test('saaras diarize pricing uses 45 INR per hour', () {
    final usd = SttPricing.usd(
      model: 'saaras:v4+diarize',
      billedSeconds: 3600,
    );
    expect(usd, closeTo(45 / 87, 1e-9));
  });

  test('alt segments round-trip JSON', () {
    final segs = [
      TranscriptSegment(
        startS: 0.1,
        endS: 1.2,
        spokenAt: DateTime.utc(2026, 8, 21, 12),
        text: 'नमस्ते',
        speaker: null,
      ),
    ];
    final back = decodeAltSegments(
      jsonEncode(encodeAltSegments(segs)),
      clipId: 'c1',
    );
    expect(back.single.text, 'नमस्ते');
    expect(back.single.clipId, 'c1');
  });
}
