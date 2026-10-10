// Browser-only services behind one interface. Non-web builds get the inert version, so the rest of the app
// can call these without checking the platform first.
export 'browser_types.dart';
export 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart';
