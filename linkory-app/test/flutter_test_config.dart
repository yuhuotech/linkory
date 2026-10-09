import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Golden screenshots are rendered with this machine's fonts (macOS: Arial Unicode for CJK), so on CI
/// runners (`CI=true`) their pixels legitimately differ. CI still runs every other assertion; pixel
/// comparison stays a local check (`flutter test`, `--update-goldens`).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.environment['CI'] == 'true') {
    goldenFileComparator = _AcceptAnyGolden();
  }
  await testMain();
}

class _AcceptAnyGolden extends GoldenFileComparator {
  @override
  Future<bool> compare(List<int> imageBytes, Uri golden) async => true;
  @override
  Future<void> update(Uri golden, List<int> imageBytes) async {}
}
