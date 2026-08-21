import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ble/pendant_ble.dart';
import '../db/models.dart';
import '../stt/stt_pricing.dart';
import '../stt/vad_cal.dart';

class DeveloperLive extends ChangeNotifier {
  bool connected = false;
  bool armed = false;
  int bytes = 0;
  PendantStatus? dbg;
  int sttQueue = 0;
  double totalCostUsd = 0;
  double totalBilledS = 0;
  int totalInTok = 0;
  int totalOutTok = 0;
  List<TranscriptSegment> segments = const [];

  DateTime? _lastNotify;

  void sync({
    required bool connected,
    required bool armed,
    required int bytes,
    required PendantStatus? dbg,
    required int sttQueue,
    required double totalCostUsd,
    required double totalBilledS,
    required int totalInTok,
    required int totalOutTok,
    required List<TranscriptSegment> segments,
    bool force = false,
  }) {
    this.connected = connected;
    this.armed = armed;
    this.bytes = bytes;
    this.dbg = dbg;
    this.sttQueue = sttQueue;
    this.totalCostUsd = totalCostUsd;
    this.totalBilledS = totalBilledS;
    this.totalInTok = totalInTok;
    this.totalOutTok = totalOutTok;
    this.segments = segments;
    final now = DateTime.now();
    if (!force &&
        _lastNotify != null &&
        now.difference(_lastNotify!) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }
}

class DeveloperPage extends StatelessWidget {
  const DeveloperPage({
    super.key,
    required this.live,
    required this.rangeBar,
  });

  final DeveloperLive live;
  final Widget rangeBar;

  String _batteryLine(PendantStatus s) {
    final mv = s.batteryMv;
    final mvLabel = (mv != null && mv > 0)
        ? '  rail ${(mv / 1000).toStringAsFixed(2)} V'
        : '';
    if (s.usbPowered) {
      return 'Power: USB$mvLabel  (SoC only when unplugged — charger looks like a full cell)';
    }
    final pct = s.batteryPct;
    if (pct == null || mv == null) {
      return 'Battery: not seen';
    }
    final warn = pct <= 20 ? '  — charge soon' : '';
    return 'Battery: ~$pct%  (${(mv / 1000).toStringAsFixed(2)} V)$warn';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) {
        final s = live.dbg;
        final imuLabel = !live.connected
            ? '—'
            : (s == null)
                ? 'waiting (flash IMU firmware if this stays empty)'
                : s.imuSleep
                    ? 'SLEEP'
                    : 'AWAKE';
        final clock = DateFormat.Hms();
        return Scaffold(
          appBar: AppBar(title: const Text('Developer')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'STT + cleanup ${SttPricing.formatUsd(live.totalCostUsd)}  ·  '
                '${live.totalBilledS.toStringAsFixed(1)}s billed'
                '${(live.totalInTok + live.totalOutTok) > 0 ? '  ·  ${live.totalInTok} in / ${live.totalOutTok} out tok' : ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              Text('Link: ${live.connected ? 'connected' : 'down'}'),
              Text('Mode: ${live.armed ? 'armed (notify on)' : 'idle'}'),
              Text('STT queue: ${live.sttQueue}'),
              if (live.armed) Text('PCM bytes: ${live.bytes}'),
              Text(VadCal.statusLine()),
              Text('IMU: $imuLabel'),
              if (s != null) ...[
                Text(_batteryLine(s)),
                Text('Mic: ${s.micRunning ? 'running' : 'stopped'}'),
                Text(
                  'Chip: ${s.imuReady ? 'LSM6DS3 ready' : 'not ready (sleep will not start)'}',
                ),
                Text(
                  'IMU read: ${s.imuFetchOk ? 'ok' : 'fail (still meter stays 0)'}',
                ),
                Text('Still meter: ${s.stillHits}/10  (10 still polls → sleep)'),
                Text(
                  'Mic level: ${s.volume}  (info only; host VAD filters noise)',
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Armed: LED stays solid. Sit still ~10s → IMU SLEEP cuts a chunk '
                '(no OpenAI if quiet). Move and talk → next chunk. '
                'Lines below are raw STT plus cleaned text, live as chunks finish.',
              ),
              const SizedBox(height: 16),
              Text('Time range', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              rangeBar,
              const SizedBox(height: 16),
              Text(
                'Live transcript (${live.segments.length} lines)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (live.segments.isEmpty)
                const Text(
                  'No lines in this range yet. After OpenAI finishes a chunk, '
                  'raw and cleaned text show up here.',
                )
              else
                for (final seg in live.segments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [
                            clock.format(seg.spokenAt.toLocal()),
                            if ((seg.speaker ?? '').trim().isNotEmpty)
                              seg.speaker!.trim(),
                          ].join('  '),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        SelectableText(
                          seg.text.trim().isEmpty ? '(dropped)' : seg.text,
                        ),
                        if (seg.rawText.trim().isNotEmpty &&
                            seg.rawText.trim() != seg.text.trim())
                          Text(
                            'Raw: ${seg.rawText}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}
