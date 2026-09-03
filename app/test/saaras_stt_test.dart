import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/models.dart';
import 'package:openpendant/stt/saaras_stt.dart';
import 'package:openpendant/stt/stt_pricing.dart';
import 'package:openpendant/stt/voice_store.dart';

void main() {
  test('recognizes and shortens Saaras missing-key errors', () {
    final error = Exception(
      'saaras:v4 REST 403: No keys added. Please add your server key.',
    );
    expect(isSaarasAuthError(error), isTrue);
    expect(friendlySaarasError(error), contains('saved key'));
  });

  test('parseSaarasTranscript uses diarized entries', () {
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
      model: 'saaras:v4+diarize',
      startedAt: DateTime.utc(2026, 8, 21, 10),
      billedSeconds: 5,
    );
    expect(r.segments, hasLength(2));
    expect(r.segments[0].speaker, 'Speaker 1');
    expect(r.segments[1].speaker, 'Speaker 2');
    expect(r.segments[1].text, 'Question.');
    expect(r.text, contains('Speaker 1:'));
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
    expect(named.segments[0].speaker, 'Aditya');
    expect(named.segments[1].speaker, 'Sushma');
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
