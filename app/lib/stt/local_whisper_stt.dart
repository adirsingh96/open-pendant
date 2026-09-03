import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio/speech_vad.dart';
import '../db/models.dart';
import 'whisper_mapper.dart';

typedef WhisperDownloadProgress = void Function(int received, int total);

/// On-device Qwen3-ASR 0.6B (INT8) via sherpa-onnx.
class LocalWhisperStt {
  static const modelId = qwen3AsrModelId;
  static const _hf =
      'https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main';
  static const _convName = 'conv_frontend.onnx';
  static const _encoderName = 'encoder.int8.onnx';
  static const _decoderName = 'decoder.int8.onnx';
  static const convMinBytes = 20 * 1000 * 1000;
  static const encoderMinBytes = 100 * 1000 * 1000;
  static const decoderMinBytes = 400 * 1000 * 1000;
  static const mergesMinBytes = 100 * 1000;
  static const vocabMinBytes = 500 * 1000;
  static const tokCfgMinBytes = 200;

  static Future<void>? _download;
  static Isolate? _iso;
  static SendPort? _cmd;
  static ReceivePort? _replies;
  static Future<void>? _boot;
  static var _jobId = 0;
  static final _jobs = <int, Completer<TranscriptResult>>{};

  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'qwen3-asr-06'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _tok() async {
    final dir = Directory(p.join((await _dir()).path, 'tokenizer'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _deleteLegacy() async {
    final root = await getApplicationSupportDirectory();
    for (final name in [
      'whisper-turbo',
      'indic-hi',
      'hi-hinglish-apex',
      'hinglish-apex',
    ]) {
      final dir = Directory(p.join(root.path, name));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  static Future<File> convFile() async =>
      File(p.join((await _dir()).path, _convName));
  static Future<File> encoderFile() async =>
      File(p.join((await _dir()).path, _encoderName));
  static Future<File> decoderFile() async =>
      File(p.join((await _dir()).path, _decoderName));
  static Future<File> mergesFile() async =>
      File(p.join((await _tok()).path, 'merges.txt'));
  static Future<File> vocabFile() async =>
      File(p.join((await _tok()).path, 'vocab.json'));
  static Future<File> tokCfgFile() async =>
      File(p.join((await _tok()).path, 'tokenizer_config.json'));

  static Future<bool> isReady() async {
    final checks = [
      (await convFile(), convMinBytes),
      (await encoderFile(), encoderMinBytes),
      (await decoderFile(), decoderMinBytes),
      (await mergesFile(), mergesMinBytes),
      (await vocabFile(), vocabMinBytes),
      (await tokCfgFile(), tokCfgMinBytes),
    ];
    for (final c in checks) {
      if (!await c.$1.exists() || await c.$1.length() < c.$2) {
        return false;
      }
    }
    return true;
  }

  static Future<int> installedBytes() async {
    var n = 0;
    for (final f in [
      await convFile(),
      await encoderFile(),
      await decoderFile(),
      await mergesFile(),
      await vocabFile(),
      await tokCfgFile(),
    ]) {
      if (await f.exists()) {
        n += await f.length();
      }
    }
    return n;
  }

  static Future<void> ensureModel({WhisperDownloadProgress? onProgress}) {
    _download ??= _ensureModel(onProgress: onProgress);
    return _download!.whenComplete(() {
      _download = null;
    });
  }

  static Future<void> _ensureModel(
      {WhisperDownloadProgress? onProgress}) async {
    await _deleteLegacy();
    var received = 0;
    final sizes = <String, int>{};
    Future<void> one({
      required Directory dir,
      required String name,
      required int minBytes,
      required Uri url,
    }) async {
      final dest = File(p.join(dir.path, name));
      if (await dest.exists() && await dest.length() >= minBytes) {
        received += await dest.length();
        sizes[name] = await dest.length();
        onProgress?.call(received, _progressTotal(sizes, received));
        return;
      }
      await _downloadFile(
        url,
        dest,
        onChunk: (n, contentLen) {
          sizes[name] = contentLen;
          onProgress?.call(received + n, _progressTotal(sizes, received + n));
        },
      );
      received += await dest.length();
    }

    final root = await _dir();
    final tok = await _tok();
    await one(
      dir: root,
      name: _convName,
      minBytes: convMinBytes,
      url: Uri.parse('$_hf/$_convName'),
    );
    await one(
      dir: root,
      name: _encoderName,
      minBytes: encoderMinBytes,
      url: Uri.parse('$_hf/$_encoderName'),
    );
    await one(
      dir: root,
      name: _decoderName,
      minBytes: decoderMinBytes,
      url: Uri.parse('$_hf/$_decoderName'),
    );
    await one(
      dir: tok,
      name: 'merges.txt',
      minBytes: mergesMinBytes,
      url: Uri.parse('$_hf/tokenizer/merges.txt'),
    );
    await one(
      dir: tok,
      name: 'vocab.json',
      minBytes: vocabMinBytes,
      url: Uri.parse('$_hf/tokenizer/vocab.json'),
    );
    await one(
      dir: tok,
      name: 'tokenizer_config.json',
      minBytes: tokCfgMinBytes,
      url: Uri.parse('$_hf/tokenizer/tokenizer_config.json'),
    );
    if (!await isReady()) {
      throw Exception('On-device models are incomplete. Try download again.');
    }
  }

  static int _progressTotal(Map<String, int> sizes, int received) {
    var known = 0;
    for (final v in sizes.values) {
      if (v > 0) {
        known += v;
      }
    }
    if (known >= received && sizes.length >= 6) {
      return known;
    }
    return known > received ? known : received;
  }

  static Future<void> _downloadFile(
    Uri url,
    File dest, {
    required void Function(int got, int contentLen) onChunk,
  }) async {
    final tmp = File('${dest.path}.part');
    if (await tmp.exists()) {
      await tmp.delete();
    }
    final client = http.Client();
    try {
      final req = http.Request('GET', url);
      req.headers['User-Agent'] = 'OpenPendant';
      final res = await client.send(req).timeout(const Duration(minutes: 30));
      if (res.statusCode >= 400) {
        throw Exception('Model download ${res.statusCode} for ${dest.path}');
      }
      final contentLen = res.contentLength ?? 0;
      final sink = tmp.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        onChunk(got, contentLen);
      }
      await sink.close();
      if (await dest.exists()) {
        await dest.delete();
      }
      await tmp.rename(dest.path);
    } finally {
      client.close();
    }
  }

  static Future<void> deleteModel() async {
    free();
    await _deleteLegacy();
    final dir = await _dir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  static bool get isBusy => _jobs.isNotEmpty;

  static void free() {
    try {
      _cmd?.send({'op': 'stop'});
    } catch (_) {}
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _cmd = null;
    _replies?.close();
    _replies = null;
    _boot = null;
    for (final c in _jobs.values) {
      if (!c.isCompleted) {
        c.completeError(Exception('On-device STT stopped.'));
      }
    }
    _jobs.clear();
  }

  static Future<void> _ensureWorker() {
    _boot ??= () async {
      try {
        final ready = ReceivePort();
        _iso = await Isolate.spawn(
          _qwen3IsolateMain,
          ready.sendPort,
          debugName: 'qwen3-asr',
        );
        _cmd = await ready.first as SendPort;
        ready.close();
        _replies = ReceivePort();
        _replies!.listen(_onWorkerMsg);
      } catch (e) {
        _boot = null;
        _iso = null;
        _cmd = null;
        rethrow;
      }
    }();
    return _boot!;
  }

  static void _onWorkerMsg(dynamic raw) {
    if (raw is! Map) {
      return;
    }
    final msg = Map<Object?, Object?>.from(raw);
    final id = msg['id'];
    if (id is! int) {
      return;
    }
    final done = _jobs.remove(id);
    if (done == null || done.isCompleted) {
      return;
    }
    if (msg['ok'] == true && msg['result'] is Map) {
      done.complete(
          _resultFromMsg(Map<Object?, Object?>.from(msg['result'] as Map)));
    } else {
      done.completeError(
          Exception('${msg['error'] ?? 'On-device STT failed.'}'));
    }
  }

  Future<TranscriptResult> transcribe({
    required File wav,
    required DateTime startedAt,
    SpeechExtract? speech,
  }) async {
    await ensureModel();
    await _ensureWorker();
    final cmd = _cmd;
    final replies = _replies;
    if (cmd == null || replies == null) {
      throw Exception('Qwen3-ASR worker failed to start.');
    }
    final id = ++_jobId;
    final done = Completer<TranscriptResult>();
    _jobs[id] = done;
    cmd.send({
      'op': 'transcribe',
      'id': id,
      'replies': replies.sendPort,
      'wav': wav.path,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'conv': (await convFile()).path,
      'encoder': (await encoderFile()).path,
      'decoder': (await decoderFile()).path,
      'tok': (await _tok()).path,
      'speech': _speechToMsg(speech),
    });
    return done.future;
  }
}

Map<String, Object?>? _speechToMsg(SpeechExtract? speech) {
  if (speech == null) {
    return null;
  }
  return {
    'speechDurationS': speech.speechDurationS,
    'originalDurationS': speech.originalDurationS,
    'regions': [
      for (final r in speech.regions)
        {
          'origStartS': r.origStartS,
          'origEndS': r.origEndS,
          'concatStartS': r.concatStartS,
          'concatEndS': r.concatEndS,
        },
    ],
  };
}

SpeechExtract? _speechFromMsg(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final m = Map<Object?, Object?>.from(raw);
  final regions = <SpeechRegion>[];
  final list = m['regions'];
  if (list is List) {
    for (final item in list) {
      if (item is! Map) {
        continue;
      }
      final r = Map<Object?, Object?>.from(item);
      regions.add(
        SpeechRegion(
          origStartS: (r['origStartS'] as num?)?.toDouble() ?? 0,
          origEndS: (r['origEndS'] as num?)?.toDouble() ?? 0,
          concatStartS: (r['concatStartS'] as num?)?.toDouble() ?? 0,
          concatEndS: (r['concatEndS'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
  }
  return SpeechExtract(
    speechPcm: const [],
    originalDurationS: (m['originalDurationS'] as num?)?.toDouble() ?? 0,
    speechDurationS: (m['speechDurationS'] as num?)?.toDouble() ?? 0,
    regions: regions,
  );
}

Map<String, Object?> _resultToMsg(TranscriptResult r) {
  return {
    'text': r.text,
    'model': r.model,
    'costUsd': r.costUsd,
    'inputTokens': r.inputTokens,
    'outputTokens': r.outputTokens,
    'segments': [
      for (final s in r.segments)
        {
          'startS': s.startS,
          'endS': s.endS,
          'spokenAt': s.spokenAt.toUtc().toIso8601String(),
          'text': s.text,
          'rawText': s.rawText,
        },
    ],
  };
}

TranscriptResult _resultFromMsg(Map<Object?, Object?> m) {
  final segs = <TranscriptSegment>[];
  final list = m['segments'];
  if (list is List) {
    for (final item in list) {
      if (item is! Map) {
        continue;
      }
      final s = Map<Object?, Object?>.from(item);
      segs.add(
        TranscriptSegment(
          startS: (s['startS'] as num?)?.toDouble() ?? 0,
          endS: (s['endS'] as num?)?.toDouble() ?? 0,
          spokenAt:
              DateTime.tryParse('${s['spokenAt']}') ?? DateTime.now().toUtc(),
          text: '${s['text'] ?? ''}',
          rawText: '${s['rawText'] ?? ''}',
        ),
      );
    }
  }
  return TranscriptResult(
    text: '${m['text'] ?? ''}',
    model: '${m['model'] ?? qwen3AsrModelId}',
    segments: segs,
    inputTokens: (m['inputTokens'] as num?)?.toInt() ?? 0,
    outputTokens: (m['outputTokens'] as num?)?.toInt() ?? 0,
    costUsd: (m['costUsd'] as num?)?.toDouble() ?? 0,
  );
}

void _qwen3IsolateMain(SendPort handshake) {
  unawaited(_qwen3IsolateLoop(handshake));
}

Future<void> _qwen3IsolateLoop(SendPort handshake) async {
  final cmds = ReceivePort();
  handshake.send(cmds.sendPort);
  sherpa.initBindings();
  sherpa.OfflineRecognizer? rec;
  var conv = '';
  var encoder = '';
  var decoder = '';
  var tok = '';
  SendPort? replies;
  await for (final raw in cmds) {
    if (raw is! Map) {
      continue;
    }
    final msg = Map<Object?, Object?>.from(raw);
    if (msg['op'] == 'stop') {
      rec?.free();
      cmds.close();
      break;
    }
    replies = (msg['replies'] as SendPort?) ?? replies;
    final id = msg['id'];
    try {
      final nConv = '${msg['conv']}';
      final nEnc = '${msg['encoder']}';
      final nDec = '${msg['decoder']}';
      final nTok = '${msg['tok']}';
      if (rec == null ||
          nConv != conv ||
          nEnc != encoder ||
          nDec != decoder ||
          nTok != tok) {
        rec?.free();
        conv = nConv;
        encoder = nEnc;
        decoder = nDec;
        tok = nTok;
        rec = sherpa.OfflineRecognizer(_workerCfg(conv, encoder, decoder, tok));
      }
      final wav = '${msg['wav']}';
      final startedAt = DateTime.parse('${msg['startedAt']}');
      final result = _workerTranscribe(
        rec: rec,
        wav: wav,
        startedAt: startedAt,
        speech: _speechFromMsg(msg['speech']),
      );
      replies?.send({
        'id': id,
        'ok': true,
        'result': _resultToMsg(result),
      });
    } catch (e) {
      replies?.send({
        'id': id,
        'ok': false,
        'error': '$e',
      });
    }
  }
}

sherpa.OfflineRecognizerConfig _workerCfg(
  String conv,
  String encoder,
  String decoder,
  String tok,
) {
  final threads = Platform.isIOS ? 4 : 2;
  return sherpa.OfflineRecognizerConfig(
    feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 128),
    model: sherpa.OfflineModelConfig(
      qwen3Asr: sherpa.OfflineQwen3AsrModelConfig(
        convFrontend: conv,
        encoder: encoder,
        decoder: decoder,
        tokenizer: tok,
        maxNewTokens: 384,
      ),
      tokens: '',
      numThreads: threads,
      debug: false,
      provider: 'cpu',
    ),
  );
}

TranscriptResult _workerTranscribe({
  required sherpa.OfflineRecognizer rec,
  required String wav,
  required DateTime startedAt,
  SpeechExtract? speech,
}) {
  final wave = sherpa.readWave(wav);
  if (wave.samples.isEmpty || wave.sampleRate <= 0) {
    throw Exception('Could not read speech WAV for on-device STT.');
  }
  final stream = rec.createStream();
  try {
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    rec.decode(stream);
    final out = rec.getResult(stream);
    return whisperToTranscript(
      text: out.text,
      tokens: [for (final t in out.tokens) t.toString()],
      timestamps: out.timestamps,
      startedAt: startedAt,
      speech: speech,
      model: qwen3AsrModelId,
    );
  } finally {
    stream.free();
  }
}
