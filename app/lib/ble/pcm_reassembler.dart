class PcmChunk {
  PcmChunk({required this.seq, required this.bytes});
  final int seq;
  final List<int> bytes;
}

/// Reassemble GATT notify payloads: seq_le16 | frag | frag_count | pcm.
class PcmReassembler {
  final Map<int, List<int>> _partial = {};
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
    final payload = data.sublist(4);
    notifyCount++;
    final buf = _partial.putIfAbsent(seq, () => <int>[]);
    if (frag == 0) {
      buf.clear();
    }
    buf.addAll(payload);
    if (frag + 1 == fragCount) {
      complete.add(PcmChunk(seq: seq, bytes: List<int>.from(buf)));
      lastComplete = complete.last.bytes;
      pcmByteLength += lastComplete.length;
      _partial.remove(seq);
      if (_lastSeq != null && seq != ((_lastSeq! + 1) & 0xffff)) {
        seqGaps++;
      }
      _lastSeq = seq;
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
    _partial.clear();
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
    pcmByteLength += lastComplete.length;
    _lastSeq = seq;
  }
}
