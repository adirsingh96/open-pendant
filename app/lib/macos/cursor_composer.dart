import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class CursorPasteResult {
  CursorPasteResult({required this.ok, this.detail = ''});

  final bool ok;
  final String detail;
}

const _channel = MethodChannel('openpendant/cursor');

/// Paste the current clipboard into Cursor via Accessibility Cmd+V.
/// Does not use Automation / osascript (those never list OpenPendant).
Future<CursorPasteResult> pasteIntoCursorComposer({bool autoSend = false}) async {
  if (!Platform.isMacOS) {
    return CursorPasteResult(ok: false, detail: 'macOS only');
  }
  try {
    await _channel
        .invokeMethod('pasteClipboard', {'autoSend': autoSend})
        .timeout(const Duration(seconds: 8));
    return CursorPasteResult(ok: true);
  } on PlatformException catch (e) {
    return CursorPasteResult(
      ok: false,
      detail: (e.message ?? e.code).trim(),
    );
  } catch (e) {
    return CursorPasteResult(ok: false, detail: '$e');
  }
}
