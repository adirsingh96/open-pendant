import 'package:flutter_test/flutter_test.dart';
import 'package:openpendant/db/models.dart';
import 'package:openpendant/db/scene_group.dart';

TranscriptSegment _seg(String text, DateTime at, {String? speaker}) {
  return TranscriptSegment(
    startS: 0,
    endS: 1,
    spokenAt: at,
    text: text,
    rawText: text,
    speaker: speaker,
  );
}

void main() {
  test('splits scenes on a 3 minute gap', () {
    final t0 = DateTime.utc(2026, 8, 19, 10);
    final segs = [
      _seg('hi', t0, speaker: 'A'),
      _seg('there', t0.add(const Duration(seconds: 20)), speaker: 'B'),
      _seg('later', t0.add(const Duration(minutes: 8)), speaker: 'A'),
    ];
    final scenes = SceneGroup.fromSegments(segs);
    expect(scenes, hasLength(2));
    expect(scenes.first.segments, hasLength(1));
    expect(scenes.last.preview, contains('A: hi'));
    expect(scenes.last.speakers, ['A', 'B']);
  });

  test('drops punctuation-only speaker labels', () {
    expect(SceneGroup.isDisplaySpeaker('@'), isFalse);
    expect(SceneGroup.isDisplaySpeaker('A'), isTrue);
    expect(SceneGroup.isDisplaySpeaker('Aditya'), isTrue);
    final t0 = DateTime.utc(2026, 8, 20, 9, 27);
    final scene = SceneGroup(
      segments: [
        _seg('hi', t0, speaker: '@'),
        _seg('there', t0.add(const Duration(minutes: 5)), speaker: 'Aditya'),
      ],
    );
    expect(scene.displaySpeakers, ['Aditya']);
    expect(scene.timeRangeLabel(), contains('–'));
  });

  test('drops empty turns', () {
    final t0 = DateTime.utc(2026, 8, 19, 10);
    final scenes = SceneGroup.fromSegments([
      _seg('   ', t0),
      _seg('ok', t0.add(const Duration(seconds: 1))),
    ]);
    expect(scenes, hasLength(1));
    expect(scenes.first.segments, hasLength(1));
  });
}
