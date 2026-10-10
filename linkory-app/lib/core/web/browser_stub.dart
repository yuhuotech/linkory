import 'dart:typed_data';

import 'browser_types.dart';

/// The origin that served the page ('' outside a browser).
String browserOrigin() => '';

/// e.g. "Chrome · macOS": how this browser is named in the device list.
String browserLabel() => '';

/// Ask the browser not to evict this site's storage (the device identity lives there).
Future<void> browserPersistStorage() async {}

/// Page is visible and focused / not. Fires once with the current state, then on every change.
void browserWatchActive(void Function(bool active) onChange) {}

void browserSetTitle(String title) {}

bool browserNotifySupported() => false;
bool browserNotifyGranted() => false;

/// Must run inside a user gesture on some browsers (Safari).
Future<bool> browserNotifyRequest() async => false;

void browserNotifyShow({required String tag, required String title, required String body, required void Function() onClick}) {}
void browserNotifyClose(String tag) {}

/// One tab per browser profile may talk to the server (a device has a single live connection). Returns false when another
/// tab already holds the lock; [onLost] fires if a later tab takes it over.
Future<bool> browserLockAcquire({required void Function() onLost, bool steal = false}) async => true;

void browserReload() {}

Future<List<BrowserFile>> browserPickFiles() async => const [];

/// Turn a blob: URL (from drag and drop) into a file.
Future<BrowserFile?> browserFileFromUrl(String url, String name) async => null;

Stream<Uint8List> browserReadChunks(BrowserFile f, {int chunk = 4 << 20}) => const Stream.empty();

BrowserUpload browserUpload(String url, Map<String, String> headers, BrowserFile f) => BrowserUpload(Future.value(0), () {});

Future<BrowserResponse> browserFetch(String url, Map<String, String> headers) async =>
    BrowserResponse(0, const Stream.empty(), () {});

/// null = the user cancelled. Throws [StateError] when the file is too big for this browser.
Future<BrowserSaveTarget?> browserOpenSaveTarget(String name, int size) async => null;
