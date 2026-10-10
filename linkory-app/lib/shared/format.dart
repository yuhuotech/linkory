String fmtBytes(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  var v = b.toDouble();
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 || v >= 100 ? 0 : 1)} ${u[i]}';
}

String two(int n) => n.toString().padLeft(2, '0');

String fmtClock(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

/// Conversation-list style time: today → HH:mm, yesterday → 昨天, this week → 星期X, else MM/dd.
String fmtListTime(DateTime t, [DateTime? now]) {
  now ??= DateTime.now();
  final d0 = DateTime(now.year, now.month, now.day);
  final d1 = DateTime(t.year, t.month, t.day);
  final diff = d0.difference(d1).inDays;
  if (diff <= 0) return fmtClock(t);
  if (diff == 1) return '昨天';
  if (diff < 7) return '星期${'一二三四五六日'[t.weekday - 1]}';
  return '${two(t.month)}/${two(t.day)}';
}

String fmtSeparator(DateTime t, [DateTime? now]) {
  final l = fmtListTime(t, now);
  return l.contains(':') ? l : '$l ${fmtClock(t)}';
}

String fmtLastSeen(DateTime? t) => t == null ? '从未在线' : '最近在线 ${fmtSeparator(t)}';

String deviceTypeLabel(String t) => switch (t) {
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      'web' => '浏览器',
      _ => t,
    };

String fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

/// Day divider inside a conversation: today → "10:18", yesterday → "昨天 10:18",
/// this week → "星期三 10:18", older → "3月14日 10:18" (previous years include the year).
String fmtDaySeparator(DateTime t, [DateTime? now]) {
  now ??= DateTime.now();
  final d0 = DateTime(now.year, now.month, now.day);
  final d1 = DateTime(t.year, t.month, t.day);
  final diff = d0.difference(d1).inDays;
  final clock = fmtClock(t);
  if (diff <= 0) return clock;
  if (diff == 1) return '昨天 $clock';
  if (diff < 7) return '星期${'一二三四五六日'[t.weekday - 1]} $clock';
  final date = t.year == now.year ? '${t.month}月${t.day}日' : '${t.year}年${t.month}月${t.day}日';
  return '$date $clock';
}
