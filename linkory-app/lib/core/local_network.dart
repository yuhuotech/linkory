import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lan/lan.dart';

/// Refresh while a local device's details are visible (e.g. after switching Wi-Fi).
final localIpAddressesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final refresh = Timer(const Duration(seconds: 30), ref.invalidateSelf);
  ref.onDispose(refresh.cancel);
  return (await localLanAddresses()).toSet().toList()..sort();
});
