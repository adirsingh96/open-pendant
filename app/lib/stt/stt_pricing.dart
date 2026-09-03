/// Published OpenAI file-transcription rates (per billed minute of audio).
/// Token rates used when the API returns `usage` token counts.
class SttPricing {
  static const transcribePerMin = 0.0045;
  static const miniPerMin = 0.003;
  static const whisperPerMin = 0.006;

  /// Catalogue: ₹30/h transcribe, ₹45/h with diarization. Approx USD for the spend UI.
  static const inrPerUsd = 87.0;
  static const saarasInrPerHour = 30.0;
  static const saarasDiarizeInrPerHour = 45.0;
  static const miniInputPerMTok = 1.25;
  static const miniOutputPerMTok = 5.0;
  static const defaultInputPerMTok = 2.50;
  static const defaultOutputPerMTok = 10.0;

  static double perMinute(String model) {
    if (model.startsWith('whisper:') ||
        model.startsWith('indicconformer:') ||
        model.startsWith('qwen3-asr:')) {
      return 0;
    }
    if (model.contains('saaras')) {
      final inr =
          model.contains('diar') ? saarasDiarizeInrPerHour : saarasInrPerHour;
      return inr / inrPerUsd / 60.0;
    }
    if (model.contains('diarize')) {
      return whisperPerMin;
    }
    if (model == 'gpt-transcribe') {
      return transcribePerMin;
    }
    if (model.contains('mini')) {
      return miniPerMin;
    }
    return whisperPerMin;
  }

  static double usd({
    required String model,
    required double billedSeconds,
    int inputTokens = 0,
    int outputTokens = 0,
  }) {
    // gpt-transcribe is billed per minute only (no published token rates).
    if (model.startsWith('whisper:') ||
        model.startsWith('indicconformer:') ||
        model.startsWith('qwen3-asr:')) {
      return 0;
    }
    if (model != 'gpt-transcribe' &&
        !model.contains('diarize') &&
        !model.contains('saaras') &&
        (inputTokens > 0 || outputTokens > 0)) {
      final inRate =
          model.contains('mini') ? miniInputPerMTok : defaultInputPerMTok;
      final outRate =
          model.contains('mini') ? miniOutputPerMTok : defaultOutputPerMTok;
      return inputTokens / 1e6 * inRate + outputTokens / 1e6 * outRate;
    }
    return billedSeconds / 60.0 * perMinute(model);
  }

  static String formatUsd(double v) {
    if (v <= 0) {
      return '\$0.00';
    }
    if (v < 0.01) {
      return '\$${v.toStringAsFixed(5)}';
    }
    return '\$${v.toStringAsFixed(4)}';
  }
}
