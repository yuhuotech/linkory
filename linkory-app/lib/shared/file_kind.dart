import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/tokens.dart';

enum FileKind { image, video, audio, archive, doc, sheet, code, other }

FileKind fileKindOf(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  const m = <FileKind, List<String>>{
    FileKind.image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'svg'],
    FileKind.video: ['mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'],
    FileKind.audio: ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg'],
    FileKind.archive: ['zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'dmg', 'iso'],
    FileKind.doc: ['pdf', 'doc', 'docx', 'txt', 'md', 'rtf', 'ppt', 'pptx', 'key', 'pages'],
    FileKind.sheet: ['xls', 'xlsx', 'csv', 'numbers'],
    FileKind.code: ['dart', 'go', 'rs', 'js', 'ts', 'py', 'java', 'kt', 'swift', 'c', 'cc', 'cpp', 'h', 'json', 'yaml', 'yml', 'xml', 'html', 'css', 'sh', 'sql'],
  };
  for (final e in m.entries) {
    if (e.value.contains(ext)) return e.key;
  }
  return FileKind.other;
}

extension FileKindX on FileKind {
  IconData get icon => switch (this) {
        FileKind.image => LucideIcons.fileImage,
        FileKind.video => LucideIcons.fileVideo,
        FileKind.audio => LucideIcons.fileAudio,
        FileKind.archive => LucideIcons.fileArchive,
        FileKind.doc => LucideIcons.fileText,
        FileKind.sheet => LucideIcons.fileSpreadsheet,
        FileKind.code => LucideIcons.fileCode,
        FileKind.other => LucideIcons.file,
      };

  /// Soft tile colours from the semantic tokens (no ad-hoc palette).
  (Color bg, Color fg) tones(LinkoryColors c) => switch (this) {
        FileKind.image => (c.directSoft, c.directText),
        FileKind.video => (c.warningSoft, c.warningText),
        FileKind.audio => (c.actionSoft, c.actionText),
        FileKind.archive => (c.warningSoft, c.warningText),
        FileKind.doc => (c.bgSubtle, c.text2),
        FileKind.sheet => (c.successSoft, c.successText),
        FileKind.code => (c.bgSubtle, c.text2),
        FileKind.other => (c.bgSubtle, c.text2),
      };
}
