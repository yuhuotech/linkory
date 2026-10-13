import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linkory_app/core/api.dart';
import 'package:linkory_app/core/realtime.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Channel implements WebSocketChannel {
  _Channel({bool ready = true}) {
    if (ready) readyCompleter.complete();
  }

  final readyCompleter = Completer<void>();
  final controller = StreamController<dynamic>(sync: true);
  final sent = <dynamic>[];
  int closes = 0;
  bool failWrites = false;
  void Function(dynamic)? frameCallback;
  void Function()? doneCallback;
  Function? errorCallback;

  @override
  Future<void> get ready => readyCompleter.future;
  @override
  String? get protocol => null;
  @override
  int? get closeCode => 1000;
  @override
  String? get closeReason => '';
  @override
  Stream<dynamic> get stream => _Stream(this);
  @override
  late final WebSocketSink sink = _Sink(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  // Queued callbacks may still execute after teardown; test the generation guard too.
  void lateDone() => doneCallback?.call();
  void lateError() {
    if (errorCallback != null) Function.apply(errorCallback!, [StateError('old connection')]);
  }

  void lateFrame(String frame) => frameCallback?.call(frame);
}

class _Stream extends Stream<dynamic> {
  _Stream(this.channel);
  final _Channel channel;
  @override
  StreamSubscription<dynamic> listen(void Function(dynamic)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    channel.frameCallback = onData;
    channel.errorCallback = onError;
    channel.doneCallback = onDone;
    return channel.controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

class _Sink implements WebSocketSink {
  _Sink(this.channel);
  final _Channel channel;
  @override
  void add(dynamic data) {
    if (channel.failWrites) throw StateError('socket write failed');
    channel.sent.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => throw error;
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> get done => channel.controller.done;
  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    channel.closes++;
    // web_socket_channel can call onDone synchronously from sink.close().
    channel.lateDone();
    return channel.controller.close();
  }
}

class _Fixture {
  _Fixture({Future<http.Response> Function(int)? response, _Channel Function(int)? channel}) {
    api = ApiClient(
      baseUrl: 'https://example.test',
      client: MockClient((_) async {
        requests++;
        return response == null ? http.Response('{}', 200) : response(requests);
      }),
    );
    rt = Realtime(
      api,
      now: () => TestWidgetsFlutterBinding.instance.clock.now(),
      channelFactory: (_, _) {
        final ch = channel?.call(channels.length) ?? _Channel();
        channels.add(ch);
        return ch;
      },
    );
    subscription = rt.stateStream.listen(states.add);
    addTearDown(() async {
      rt.dispose();
      await subscription.cancel();
      api.raw.close();
    });
  }

  late final ApiClient api;
  late final Realtime rt;
  late final StreamSubscription<LinkState> subscription;
  int requests = 0;
  final channels = <_Channel>[];
  final states = <LinkState>[];

  Future<void> elapse(WidgetTester t, Duration duration) async {
    await t.pump(duration);
    await t.pump();
  }

  Future<void> dispose(WidgetTester t) async {
    rt.dispose();
    await t.pump();
  }
}

void main() {
  testWidgets('one heartbeat timeout makes one retry, including a slow REST preflight', (t) async {
    final pending = Completer<http.Response>();
    final f = _Fixture(response: (n) async => n == 2 ? pending.future : http.Response('{}', 200));
    f.rt.start();
    await t.pump();
    expect(f.rt.state, LinkState.connected);

    await f.elapse(t, const Duration(seconds: 100));
    expect(f.channels.single.closes, 1);
    final oldPings = f.channels.first.sent.length;
    expect(f.states.where((s) => s == LinkState.reconnecting), hasLength(1));
    await f.elapse(t, const Duration(seconds: 1));
    expect(f.requests, 2);
    f.channels.first.lateDone();
    f.channels.first.lateError();
    await f.elapse(t, const Duration(seconds: 5));
    expect(f.requests, 2);
    pending.complete(http.Response('{}', 200));
    await t.pump();
    expect(f.channels, hasLength(2));
    expect(f.rt.state, LinkState.connected);
    await f.elapse(t, const Duration(seconds: 30));
    expect(f.channels.last.sent.where((frame) => jsonDecode(frame as String)['type'] == 'ping'), hasLength(1));
    expect(f.channels.first.sent, hasLength(oldPings));
    await f.dispose(t);
  });

  testWidgets('old frames and close callbacks cannot affect a replacement connection', (t) async {
    final f = _Fixture();
    f.rt.start();
    await t.pump();
    final old = f.channels.single;
    old.lateDone();
    await f.elapse(t, const Duration(seconds: 1));
    expect(f.rt.state, LinkState.connected);
    final events = <WsEvent>[];
    final sub = f.rt.events.listen(events.add);
    addTearDown(sub.cancel);
    old.lateFrame('{"type":"message.receive","data":{}}');
    old.lateDone();
    old.lateError();
    await t.pump();
    expect(events, isEmpty);
    expect(f.channels.last.closes, 0);
    await f.elapse(t, const Duration(seconds: 5));
    expect(f.requests, 2);
    expect(f.rt.state, LinkState.connected);
    await f.dispose(t);
  });

  testWidgets('repeated start is idempotent while connecting and connected', (t) async {
    final f = _Fixture();
    f.rt.start();
    f.rt.start();
    await t.pump();
    f.rt.start();
    await t.pump();
    expect(f.requests, 1);
    expect(f.channels, hasLength(1));
    expect(f.states, [LinkState.connecting, LinkState.connected]);
    await f.dispose(t);
  });

  testWidgets('stop during REST preflight cannot restore a connection', (t) async {
    final pending = Completer<http.Response>();
    final f = _Fixture(response: (_) => pending.future);
    f.rt.start();
    await t.pump();
    f.rt.stop();
    pending.complete(http.Response('{}', 200));
    await t.pump();
    await f.elapse(t, const Duration(minutes: 2));
    expect(f.channels, isEmpty);
    expect(f.requests, 1);
    expect(f.rt.state, LinkState.closed);
    await f.dispose(t);
  });

  testWidgets('late REST failure from a stopped session cannot drop a new connection', (t) async {
    final pending = Completer<http.Response>();
    final f = _Fixture(response: (n) async => n == 1 ? pending.future : http.Response('{}', 200));
    f.rt.start();
    await t.pump();
    f.rt.stop();
    f.rt.start();
    await t.pump();
    pending.complete(http.Response('{"code":"network","message":"failed"}', 503));
    await t.pump();
    await f.elapse(t, const Duration(seconds: 5));
    expect(f.channels, hasLength(1));
    expect(f.channels.single.closes, 0);
    expect(f.rt.state, LinkState.connected);
    expect(f.requests, 2);
    await f.dispose(t);
  });

  testWidgets('late handshake success cannot overwrite a restarted session', (t) async {
    final old = _Channel(ready: false);
    final f = _Fixture(channel: (n) => n == 0 ? old : _Channel());
    f.rt.start();
    await t.pump();
    f.rt.stop();
    f.rt.start();
    await t.pump();
    old.readyCompleter.complete();
    old.lateDone();
    await t.pump();
    expect(f.channels, hasLength(2));
    expect(old.closes, 1);
    expect(f.channels.last.closes, 0);
    expect(f.states.where((s) => s == LinkState.connected), hasLength(1));
    expect(f.rt.state, LinkState.connected);
    await f.dispose(t);
  });

  testWidgets('handshake stream and future errors share one backoff retry', (t) async {
    final first = _Channel(ready: false);
    final second = _Channel(ready: false);
    final f = _Fixture(
      channel: (n) => n == 0
          ? first
          : n == 1
          ? second
          : _Channel(),
    );
    f.rt.start();
    await t.pump();
    first.controller.addError(StateError('handshake failed'));
    first.readyCompleter.completeError(StateError('handshake failed'));
    await t.pump();
    await f.elapse(t, const Duration(seconds: 1));
    expect(f.requests, 2);
    second.readyCompleter.completeError(StateError('handshake failed again'));
    await t.pump();
    await f.elapse(t, const Duration(seconds: 1));
    expect(f.requests, 2);
    await f.elapse(t, const Duration(seconds: 1));
    expect(f.requests, 3);
    expect(f.rt.state, LinkState.connected);
    expect(f.states.where((s) => s == LinkState.reconnecting), hasLength(1));
    await f.dispose(t);
  });

  testWidgets('extended network failure keeps the retry delay bounded and recovers', (t) async {
    var healthy = false;
    final f = _Fixture(response: (_) async => http.Response(healthy ? '{}' : '{"code":"network","message":"unavailable"}', healthy ? 200 : 503));
    f.rt.start();
    await t.pump();
    expect(f.requests, 1);
    for (final seconds in [1, 2, 4, 8, 16, 32, 60, 60]) {
      final requests = f.requests;
      await f.elapse(t, Duration(seconds: seconds - 1));
      expect(f.requests, requests);
      await f.elapse(t, const Duration(seconds: 1));
      expect(f.requests, requests + 1);
    }
    healthy = true;
    await f.elapse(t, const Duration(seconds: 60));
    expect(f.rt.state, LinkState.connected);
    expect(f.channels, hasLength(1));
    await f.dispose(t);
  });

  testWidgets('heartbeat write failure schedules one retry without throwing', (t) async {
    final f = _Fixture();
    f.rt.start();
    await t.pump();
    f.channels.single.failWrites = true;
    await f.elapse(t, const Duration(seconds: 30));
    expect(f.rt.state, LinkState.reconnecting);
    expect(f.channels.single.closes, 1);
    await f.elapse(t, const Duration(seconds: 1));
    expect(f.requests, 2);
    expect(f.rt.state, LinkState.connected);
    await f.dispose(t);
  });

  testWidgets('dispose cancels a queued retry and ignores late callbacks', (t) async {
    final f = _Fixture();
    f.rt.start();
    await t.pump();
    final old = f.channels.single;
    old.lateDone();
    f.rt.dispose();
    old.lateDone();
    old.lateError();
    old.lateFrame('{"type":"message.receive","data":{}}');
    f.rt.start();
    await f.elapse(t, const Duration(minutes: 2));
    expect(f.requests, 1);
    expect(f.rt.state, LinkState.closed);
    await f.dispose(t);
  });
}
