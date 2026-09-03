class PcmChunk {
  PcmChunk({required this.seq, required this.bytes});
  final int seq;
  final List<int> bytes;
}

/// Reassemble GATT notify payloads: seq_le16 | frag | frag_count | pcm.
class PcmReassembler {
  final Map<int, Map<int, List<int>>> _frags = {};
  final Map<int, int> _counts = {};
  int? _lastSeq;
  int notifyCount = 0;
  int seqGaps = 0;
  int pcmByteLength = 0;
  List<int> lastComplete = const [];
  final List<PcmChunk> complete = [];

  void addNotify(List<int> data) {
    if (data.length < 4) {
      return;
    }
    final seq = data[0] | (data[1] << 8);
    final frag = data[2];
    final fragCount = data[3];
    if (fragCount < 1 || frag >= fragCount) {
      return;
    }
    final payload = data.sublist(4);
    notifyCount++;
    final slots = _frags.putIfAbsent(seq, () => <int, List<int>>{});
    slots[frag] = payload;
    _counts[seq] = fragCount;
    if (slots.length != fragCount) {
      _trimStale(seq);
      return;
    }
    for (var i = 0; i < fragCount; i++) {
      if (!slots.containsKey(i)) {
        return;
      }
    }
    final bytes = <int>[];
    for (var i = 0; i < fragCount; i++) {
      bytes.addAll(slots[i]!);
    }
    _frags.remove(seq);
    _counts.remove(seq);
    complete.add(PcmChunk(seq: seq, bytes: bytes));
    lastComplete = complete.last.bytes;
    pcmByteLength += lastComplete.length;
    if (_lastSeq != null && seq != ((_lastSeq! + 1) & 0xffff)) {
      seqGaps++;
    }
    _lastSeq = seq;
  }

  void _trimStale(int newest) {
    if (_frags.length <= 8) {
      return;
    }
    final stale = _frags.keys.where((s) => s != newest).toList();
    for (final s in stale.take(_frags.length - 8)) {
      _frags.remove(s);
      _counts.remove(s);
    }
  }

  List<int> pcmBytes() {
    final out = <int>[];
    for (final c in complete) {
      out.addAll(c.bytes);
    }
    return out;
  }

  void reset() {
    _frags.clear();
    _counts.clear();
    complete.clear();
    _lastSeq = null;
    notifyCount = 0;
    seqGaps = 0;
    pcmByteLength = 0;
    lastComplete = const [];
  }

  void replaceWith(List<int> pcm) {
    reset();
    if (pcm.isEmpty) {
      return;
    }
    complete.add(PcmChunk(seq: 0, bytes: List<int>.from(pcm)));
    lastComplete = complete.last.bytes;
    pcmByteLength = pcm.length;
  }

  void addRaw(List<int> pcm) {
    if (pcm.isEmpty) {
      return;
    }
    final seq = ((_lastSeq ?? -1) + 1) & 0xffff;
    complete.add(PcmChunk(seq: seq, bytes: List<int>.from(pcm)));
    lastComplete = complete.last.bytes;
    pcmByteLength += pcm.length;
    _lastSeq = seq;
  }
}
