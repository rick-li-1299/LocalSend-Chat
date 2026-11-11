import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/provider/chat_store_provider.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

ChatEntry entry(String id, {ChatTransferStatus status = ChatTransferStatus.succeeded, String peer = 'fingerprint', int day = 1}) => ChatEntry(
  id: 'out:$id',
  peerFingerprint: peer,
  peerAlias: 'Peer',
  outgoing: true,
  createdAt: DateTime.utc(2026, 1, day),
  status: status,
  text: 'Hello 世界',
  attachments: const [ChatAttachment(name: 'file.txt', size: 7, path: '/keep/file.txt', fileType: FileType.text)],
);

String encode(List<ChatEntry> entries, [List<ChatDevicePreferences> devices = const []]) => jsonEncode({
  'version': 1,
  'entries': entries.map((e) => e.toJson()).toList(),
  'devices': devices.map((e) => e.toJson()).toList(),
});

void main() {
  test('models roundtrip immutable collections and nullable copy fields', () {
    final original = entry('one').copyWith(error: 'error');
    expect(ChatEntry.fromJson(jsonDecode(jsonEncode(original.toJson()))).toJson(), original.toJson());
    expect(original.copyWith(text: null, error: null).text, isNull);
    expect(original.copyWith(text: null, error: null).error, isNull);
    expect(original.attachments.single.copyWith(path: null).path, isNull);
    expect(() => original.attachments.clear(), throwsUnsupportedError);
    const prefs = ChatDevicePreferences(fingerprint: 'f', alias: 'My PC', pinned: true);
    expect(ChatDevicePreferences.fromJson(prefs.toJson()).toJson(), prefs.toJson());
    expect(prefs.copyWith(alias: null).alias, isNull);
  });

  test('attachment outcomes roundtrip and copyWith can clear errors', () {
    const attachment = ChatAttachment(name: 'file.txt', size: 7, fileType: FileType.text);
    expect(attachment.status, ChatAttachmentStatus.pending);
    expect(attachment.error, isNull);
    for (final status in ChatAttachmentStatus.values) {
      final updated = attachment.copyWith(status: status, error: 'Transfer error');
      final restored = ChatAttachment.fromJson(jsonDecode(jsonEncode(updated.toJson())));
      expect(restored.toJson(), updated.toJson());
      expect(restored.copyWith().status, status);
      expect(restored.copyWith().error, 'Transfer error');
      expect(restored.copyWith(error: null).error, isNull);
      expect(restored.copyWith(status: ChatAttachmentStatus.transferred).status, ChatAttachmentStatus.transferred);
    }
  });

  test('legacy attachments load as pending without claiming delivery', () {
    final legacy = entry('legacy').toJson();
    final attachment = (legacy['attachments'] as List).single as Map<String, dynamic>;
    attachment.remove('status');
    attachment.remove('error');
    final service = ChatStoreService(
      read: () => jsonEncode({
        'version': 1,
        'entries': [legacy],
        'devices': [],
      }),
      write: (_) async {},
    );
    final restored = service.init();
    expect(restored.persistenceError, isNull);
    expect(restored.entries.single.status, ChatTransferStatus.succeeded);
    expect(restored.entries.single.attachments.single.status, ChatAttachmentStatus.pending);
    expect(restored.entries.single.attachments.single.error, isNull);
  });

  test('restart interrupts active sessions and deduplicates preserving original timestamp', () {
    final service = ChatStoreService(
      read: () => encode([entry('a', status: ChatTransferStatus.pending), entry('a', status: ChatTransferStatus.transferring, day: 2)]),
      write: (_) async {},
    );
    final state = service.init();
    expect(state.entries, hasLength(1));
    expect(state.entries.single.status, ChatTransferStatus.interrupted);
    expect(state.entries.single.createdAt, DateTime.utc(2026, 1, 1));
  });

  test('duplicate update is synchronous and keeps session creation time', () async {
    final gate = Completer<void>();
    final service = ChatStoreService(read: () => null, write: (_) => gate.future);
    final testStore = Notifier.test(notifier: service, initialState: service.init());
    final first = service.upsertEntry(entry('a', status: ChatTransferStatus.pending));
    final second = service.upsertEntry(entry('a', day: 2));
    expect(testStore.state.entries, hasLength(1));
    expect(testStore.state.entries.single.status, ChatTransferStatus.succeeded);
    expect(testStore.state.entries.single.createdAt, DateTime.utc(2026, 1, 1));
    gate.complete();
    await Future.wait([first, second]);
  });

  test('rename retains identity and pin is separate from opt-in trust', () async {
    String? saved;
    final service = ChatStoreService(read: () => null, write: (raw) async => saved = raw);
    final store = Notifier.test(notifier: service, initialState: service.init());
    expect(store.state.preferencesFor('f').trusted, isFalse);
    await service.setDevice(store.state.preferencesFor('f').copyWith(alias: 'Desk', pinned: true));
    expect(store.state.preferencesFor('f').trusted, isFalse);
    await service.setDevice(store.state.preferencesFor('f').copyWith(alias: 'Renamed', trusted: true));
    final reloaded = ChatStoreService(read: () => saved, write: (_) async {}).init();
    expect(reloaded.devices.keys, ['f']);
    expect(reloaded.preferencesFor('f').alias, 'Renamed');
    expect(reloaded.preferencesFor('f').pinned, isTrue);
    expect(reloaded.preferencesFor('f').trusted, isTrue);
    expect(reloaded.preferencesFor('different').trusted, isFalse);
  });

  test('chat receive folder persists per device and can be reset independently of trust', () async {
    String? saved;
    final service = ChatStoreService(read: () => null, write: (raw) async => saved = raw);
    final store = Notifier.test(notifier: service, initialState: service.init());
    await service.setDevice(const ChatDevicePreferences(fingerprint: 'a', trusted: true, receiveDirectory: r'C:\Chat A'));
    await service.setDevice(const ChatDevicePreferences(fingerprint: 'b', receiveDirectory: r'D:\Chat B'));
    final reloaded = ChatStoreService(read: () => saved, write: (_) async {}).init();
    expect(reloaded.preferencesFor('a').receiveDirectory, r'C:\Chat A');
    expect(reloaded.preferencesFor('b').receiveDirectory, r'D:\Chat B');
    expect(reloaded.preferencesFor('other').receiveDirectory, isNull);
    await service.setDevice(store.state.preferencesFor('a').copyWith(receiveDirectory: null));
    final reset = ChatStoreService(read: () => saved, write: (_) async {}).init();
    expect(reset.preferencesFor('a').receiveDirectory, isNull);
    expect(reset.preferencesFor('a').trusted, isTrue);
    expect(reset.preferencesFor('b').receiveDirectory, r'D:\Chat B');
  });

  test('cap retains newest terminal entries and all active entries', () async {
    final service = ChatStoreService(read: () => null, write: (_) async {}, maxTerminalEntries: 2);
    final store = Notifier.test(notifier: service, initialState: service.init());
    await service.upsertEntry(entry('active', status: ChatTransferStatus.transferring));
    for (var i = 1; i <= 5; i++) {
      await service.upsertEntry(entry('$i', day: i));
    }
    expect(store.state.entries.map((e) => e.id), ['out:active', 'out:4', 'out:5']);
  });

  test('writes are serialized and flush retries errors without throwing', () async {
    final gate = Completer<void>();
    final writes = <String>[];
    var fail = true;
    final service = ChatStoreService(
      read: () => null,
      write: (raw) async {
        writes.add(raw);
        await gate.future;
        if (fail) throw StateError('private contents must not appear in error');
      },
    );
    final store = Notifier.test(notifier: service, initialState: service.init());
    final first = service.upsertEntry(entry('a'));
    final second = service.upsertEntry(entry('b'));
    await Future<void>.delayed(Duration.zero);
    expect(writes, hasLength(1));
    gate.complete();
    await Future.wait([first, second]);
    expect(writes, hasLength(2));
    expect((jsonDecode(writes.last)['entries'] as List), hasLength(2));
    expect(store.state.persistenceError, isNotNull);
    expect(store.state.persistenceError, isNot(contains('private contents')));
    fail = false;
    await service.flush();
    expect(store.state.persistenceError, isNull);
    expect(writes, hasLength(3));
  });

  test('clear removes only peer metadata and preserves preferences and other conversations', () async {
    String? saved;
    final service = ChatStoreService(read: () => null, write: (raw) async => saved = raw);
    final store = Notifier.test(notifier: service, initialState: service.init());
    await service.upsertEntry(entry('a'));
    await service.upsertEntry(entry('b', peer: 'other'));
    await service.setDevice(const ChatDevicePreferences(fingerprint: 'fingerprint', alias: 'Desk', trusted: true));
    await service.clearConversation('fingerprint');
    expect(store.state.entries.single.peerFingerprint, 'other');
    expect(store.state.preferencesFor('fingerprint').trusted, isTrue);
    expect((jsonDecode(saved!)['entries'] as List), hasLength(1));
  });

  for (final raw in ['broken private text', '{"version":2}', '{"version":1,"entries":[{}],"devices":[]}']) {
    test('corrupt or unsupported storage blocks overwrites until explicit reset: $raw', () async {
      final writes = <String>[];
      final service = ChatStoreService(read: () => raw, write: (raw) async => writes.add(raw));
      final store = Notifier.test(notifier: service, initialState: service.init());
      expect(store.state.persistenceError, isNotNull);
      await service.upsertEntry(entry('new'));
      await service.clearConversation('fingerprint');
      await service.flush();
      expect(writes, isEmpty);
      expect(store.state.persistenceError, isNotNull);
      await service.resetCorruptStore();
      expect(writes, hasLength(1));
      expect(store.state.persistenceError, isNull);
    });
  }
}
