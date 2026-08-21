import 'package:flutter/material.dart';

/// Renders a small Markdown subset (`**bold**`, newlines) for chat answers.
class MdText extends StatelessWidget {
  const MdText(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return SelectableText.rich(
      TextSpan(style: style, children: _spans(data, style)),
    );
  }
}

List<InlineSpan> _spans(String raw, TextStyle base) {
  final bold = base.copyWith(fontWeight: FontWeight.w700);
  final out = <InlineSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*');
  var i = 0;
  for (final m in re.allMatches(raw)) {
    if (m.start > i) {
      out.add(TextSpan(text: raw.substring(i, m.start)));
    }
    out.add(TextSpan(text: m.group(1), style: bold));
    i = m.end;
  }
  if (i < raw.length) {
    out.add(TextSpan(text: raw.substring(i)));
  }
  if (out.isEmpty) {
    out.add(TextSpan(text: raw));
  }
  return out;
}
