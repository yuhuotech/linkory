import 'dart:typed_data';

/// A file chosen in the browser. The bytes stay with the browser (disk-backed); [handle] is its Blob.
class BrowserFile {
  BrowserFile(this.name, this.size, this.handle);
  final String name;
  final int size;
  final Object handle;
}

/// Where a received file goes. Writing streams to a file the user picked (File System Access API) or, in browsers
/// without it, into memory-backed Blobs that are handed to the download manager at [finish].
/// Nothing is kept unless [finish] is called, so a file that fails verification never reaches the user.
abstract class BrowserSaveTarget {
  Future<void> write(Uint8List chunk);
  Future<void> finish();
  Future<void> abort();
}

class BrowserResponse {
  BrowserResponse(this.status, this.body, this.abort);
  final int status;
  final Stream<Uint8List> body;
  final void Function() abort;
}

class BrowserUpload {
  BrowserUpload(this.status, this.abort);

  /// HTTP status once the request ends (0 = network error, -1 = aborted).
  final Future<int> status;
  final void Function() abort;
}

/// Without the File System Access API (Firefox, Safari) a received file is assembled in memory first.
const browserMemorySaveLimit = 1 << 30;
