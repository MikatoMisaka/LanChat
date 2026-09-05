import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('releases an acquired multicast lock during dispose', () async {
    const channel = MethodChannel('lanchat/test/multicast-cleanup');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final appState = AppState(multicastChannel: channel);

    await appState.acquireMulticastLockForTesting();
    appState.dispose();
    await pumpEventQueue();

    expect(calls, ['acquire', 'release']);
  });

  test(
    'releases a multicast lock when acquire completes after dispose',
    () async {
      const channel = MethodChannel('lanchat/test/multicast-race');
      final calls = <String>[];
      final acquireStarted = Completer<void>();
      final acquireResult = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'acquire') {
              acquireStarted.complete();
              return acquireResult.future;
            }
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final appState = AppState(multicastChannel: channel);
      final acquiring = appState.acquireMulticastLockForTesting();

      await acquireStarted.future;
      appState.dispose();
      acquireResult.complete(true);
      await acquiring;
      await pumpEventQueue();

      expect(calls, ['acquire', 'release']);
    },
  );

  test(
    'does not mutate or notify after disposal during the first IP lookup',
    () async {
      final lookupStarted = Completer<void>();
      final lookupResult = Completer<List<String>>();
      final appState = AppState(
        selfIpsLookup: () {
          if (!lookupStarted.isCompleted) lookupStarted.complete();
          return lookupResult.future;
        },
      );
      var notificationCount = 0;
      appState.addListener(() => notificationCount++);

      final pruning = appState.pruneOfflineForTesting();
      await lookupStarted.future;
      appState.dispose();
      lookupResult.complete(['192.168.1.2']);
      await pruning;

      expect(appState.selfIp, isEmpty);
      expect(appState.selfIps, isEmpty);
      expect(notificationCount, 0);
    },
  );

  test(
    'does not mutate or notify after disposal during the second IP lookup',
    () async {
      final lookupStarted = Completer<void>();
      final secondLookupResult = Completer<List<String>>();
      var lookupCount = 0;
      final appState = AppState(
        selfIpsLookup: () {
          lookupCount++;
          if (lookupCount == 2) {
            lookupStarted.complete();
            return secondLookupResult.future;
          }
          return Future<List<String>>.value(['192.168.1.2']);
        },
      );
      var notificationCount = 0;
      appState.addListener(() => notificationCount++);

      final pruning = appState.pruneOfflineForTesting();
      await lookupStarted.future;
      expect(appState.selfIp, '192.168.1.2');
      expect(notificationCount, 1);

      appState.dispose();
      secondLookupResult.complete(['192.168.1.3']);
      await pruning;

      expect(appState.selfIp, '192.168.1.2');
      expect(appState.selfIps, isEmpty);
      expect(notificationCount, 1);
    },
  );
}
