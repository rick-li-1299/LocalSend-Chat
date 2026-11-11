import 'dart:convert';

import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/chat_store_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/server/controller/receive_controller.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/chat_transfer_adapter.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

class _ReceivePersistence extends MockPersistenceService {
  @override
  bool getAlwaysOnTop() => false;
}

const file = FileDto(id: 'f', fileName: 'hello.txt', size: 5, fileType: FileType.text, hash: null, preview: 'hello', metadata: null);
final peer = Device.empty.copyWith(fingerprint: 'certificate', alias: 'Peer');
final created = DateTime.utc(2026);
SendSessionState send(SessionStatus status) => SendSessionState(
  sessionId: 'session',
  remoteSessionId: null,
  background: true,
  status: status,
  target: peer,
  files: {'f': const SendingFile(file: file, token: null, thumbnail: null, asset: null, path: '/source/hello.txt', bytes: null, errorMessage: null)},
  hashedFileCount: 1,
  startTime: null,
  endTime: null,
  sendingTasks: [],
  errorMessage: null,
);
ReceiveSessionState receive(SessionStatus status) => ReceiveSessionState(
  sessionId: 'session',
  status: status,
  sender: peer,
  senderAlias: 'Display alias',
  files: {
    'f': const ReceivingFile(
      file: file,
      token: null,
      desiredName: 'hello.txt',
      path: '/received/hello.txt',
      savedToGallery: false,
      errorMessage: null,
    ),
  },
  startTime: null,
  endTime: null,
  destinationDirectory: '/received',
  cacheDirectory: '/cache',
  saveToGallery: false,
  createdDirectories: {},
);

FileDto binaryFile(String id) => FileDto(id: id, fileName: '$id.bin', size: 5, fileType: FileType.other, hash: null, preview: null, metadata: null);
SendSessionState subsetSend(SessionStatus status) => send(status).copyWith(
  files: {
    'a': send(status).files['f']!.copyWith(file: binaryFile('a'), token: 'accepted-a'),
    'b': send(status).files['f']!.copyWith(file: binaryFile('b'), token: null),
    'c': send(status).files['f']!.copyWith(file: binaryFile('c'), token: 'accepted-c'),
  },
);

void main() {
  test('a legacy history write failure cannot leave a saved receive session active', () async {
    final persistence = _ReceivePersistence();
    when(persistence.getAlias()).thenReturn('Receiver');
    when(persistence.getShareViaLinkAutoAccept()).thenReturn(false);
    when(persistence.getReceiveViaLinkAutoAccept()).thenReturn(false);
    when(persistence.getCreateChecksums()).thenReturn(false);
    when(persistence.getVerifyChecksums()).thenReturn(false);
    when(persistence.getAdvancedSettingsEnabled()).thenReturn(false);
    when(persistence.getDiscoveryTimeout()).thenReturn(2000);
    when(persistence.isSaveToHistory()).thenReturn(true);
    when(persistence.setReceiveHistory(any)).thenThrow(StateError('simulated history write failure'));
    final ref = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(persistence)]);
    ServerState? current = ServerState(alias: 'Receiver', port: 53317, https: true, session: receive(SessionStatus.sending), web: null);
    final controller = ReceiveController(
      ServerUtils(refFunc: () => ref, getState: () => current!, getStateOrNull: () => current, setState: (update) => current = update(current)),
    );
    await controller.onFileUploadResult(
      HttpServerFileUploadResultEvent(sessionId: 'session', fileId: 'f', path: '/received/hello.txt', savedToGallery: false, error: null),
    );
    expect(current!.session!.status, SessionStatus.finished);
    expect(current!.session!.files['f']!.path, '/received/hello.txt');
    verify(persistence.setReceiveHistory(any)).called(1);
  });

  test('group invitations are bound to the TLS owner and an existing roster cannot be replaced', () {
    final owner = 'A' * 64;
    final member = 'B' * 64;
    final another = 'C' * 64;
    final group = ChatGroup(
      id: 'aabbccdd-0000-4000-8000-000000000000',
      name: '办公室',
      owner: owner,
      members: {owner: 'Owner', member: 'Member', another: 'Another'},
    );
    final packet = ChatGroupPacket.decode(ChatGroupPacket(groupId: group.id, messageId: group.id, invitation: group).encode())!;
    expect(authorizesChatGroupPacket(packet: packet, certificate: owner, ownFingerprint: member, knownGroup: null), isTrue);
    expect(authorizesChatGroupPacket(packet: packet, certificate: another, ownFingerprint: member, knownGroup: null), isFalse);
    expect(authorizesChatGroupPacket(packet: packet, certificate: owner, ownFingerprint: 'D' * 64, knownGroup: null), isFalse);
    final changed = ChatGroup(id: group.id, name: 'Changed', owner: owner, members: group.members);
    expect(authorizesChatGroupPacket(packet: packet, certificate: owner, ownFingerprint: member, knownGroup: changed), isFalse);
    final message = ChatGroupPacket(groupId: group.id, messageId: group.id, text: '你好');
    expect(authorizesChatGroupPacket(packet: message, certificate: another, ownFingerprint: member, knownGroup: group), isTrue);
    expect(authorizesChatGroupPacket(packet: message, certificate: null, ownFingerprint: member, knownGroup: group), isFalse);
    expect(authorizesChatGroupPacket(packet: message, certificate: 'D' * 64, ownFingerprint: member, knownGroup: group), isFalse);
  });

  test('group carrier is kept out of files and maps the message to the shared chat', () {
    const groupId = 'aabbccdd-0000-4000-8000-000000000000';
    const messageId = 'aabbccdd-0000-4000-8000-000000000001';
    final payload = const ChatGroupPacket(groupId: groupId, messageId: messageId, text: '附件说明').encode();
    final carrier = FileDto(
      id: 'f',
      fileName: chatGroupCarrierName,
      size: utf8.encode(payload).length,
      fileType: FileType.text,
      hash: null,
      preview: payload,
      metadata: null,
    );
    final source = receive(SessionStatus.finished).files['f']!;
    final session = receive(SessionStatus.finished).copyWith(
      files: {
        'f': source.copyWith(file: carrier),
        'a': source.copyWith(file: binaryFile('a'), desiredName: 'a.bin', path: '/received/a.bin'),
      },
    );
    expect(chatFilesToAccept(session), {'a': 'a.bin'});
    final entry = chatEntryFromReceive(session, createdAt: created);
    expect(entry.groupId, groupId);
    expect(entry.groupMessageId, messageId);
    expect(entry.text, '附件说明');
    expect(entry.attachments.single.path, '/received/a.bin');
  });

  test('subset acceptance records skipped files instead of delivered files', () {
    final entry = chatEntryFromSend(
      subsetSend(SessionStatus.finished),
      createdAt: created,
      fileStatuses: {'a': FileStatus.finished, 'b': FileStatus.skipped, 'c': FileStatus.finished},
    );
    expect(entry.attachments.map((a) => a.status), [
      ChatAttachmentStatus.transferred,
      ChatAttachmentStatus.skipped,
      ChatAttachmentStatus.transferred,
    ]);
    final fallback = chatEntryFromSend(subsetSend(SessionStatus.finished), createdAt: created);
    expect(fallback.attachments.map((a) => a.status), entry.attachments.map((a) => a.status));
    final allSkipped = subsetSend(SessionStatus.finished).copyWith(
      files: {
        for (final f in subsetSend(SessionStatus.finished).files.entries) f.key: f.value.copyWith(token: null),
      },
    );
    expect(chatEntryFromSend(allSkipped, createdAt: created).attachments.every((a) => a.status == ChatAttachmentStatus.skipped), isTrue);
  });
  test('mixed send results survive provider cleanup and retained local source paths', () async {
    final store = ChatStoreService(read: () => null, write: (_) async {});
    final ref = RefenaContainer(overrides: [chatStoreProvider.overrideWithNotifier((_) => store)]);
    final original = subsetSend(SessionStatus.finishedWithErrors);
    final session = original.copyWith(
      files: {
        ...original.files,
        'c': original.files['c']!.copyWith(errorMessage: 'Disk read failed'),
      },
    );
    final transfer = ref.notifier(fileTransferProvider);
    transfer.setStatuses(sessionId: session.sessionId, statuses: {'a': FileStatus.finished, 'b': FileStatus.skipped, 'c': FileStatus.failed});
    recordChatSendChanges(ref, {}, {'session': session});
    final before = ref.read(chatStoreProvider).entry('out:session')!;
    expect(before.attachments.map((a) => a.status), [ChatAttachmentStatus.transferred, ChatAttachmentStatus.skipped, ChatAttachmentStatus.failed]);
    expect(before.attachments.last.error, 'Disk read failed');
    // Local source paths must never imply delivery of canceled/failed sends.
    expect(before.attachments.last.path, '/source/hello.txt');
    transfer.removeSession(session.sessionId);
    recordChatSendChanges(ref, {'session': session}, {});
    expect(ref.read(chatStoreProvider).entry('out:session')!.toJson(), before.toJson());
    await store.flush();
    ref.dispose(chatStoreProvider);
    ref.dispose(fileTransferProvider);
  });
  test('receive outcomes use real saved paths, selection, and per-file errors', () {
    final source = receive(SessionStatus.finishedWithErrors).files['f']!;
    final session = receive(SessionStatus.finishedWithErrors).copyWith(
      files: {
        'a': source.copyWith(file: binaryFile('a'), desiredName: 'a.bin', path: '/received/a.bin'),
        'b': source.copyWith(file: binaryFile('b'), desiredName: null, path: null),
        'c': source.copyWith(file: binaryFile('c'), desiredName: 'c.bin', path: null, errorMessage: 'Checksum mismatch'),
      },
    );
    final entry = chatEntryFromReceive(session, createdAt: created);
    expect(entry.attachments.map((a) => a.status), [ChatAttachmentStatus.transferred, ChatAttachmentStatus.skipped, ChatAttachmentStatus.failed]);
    expect(entry.attachments.last.error, 'Checksum mismatch');
    final none = session.copyWith(status: SessionStatus.finished, files: {'b': session.files['b']!});
    expect(chatEntryFromReceive(none, createdAt: created).attachments.single.status, ChatAttachmentStatus.skipped);
  });
  test('acceptance alone does not prove delivery after cancellation or mixed failure', () {
    for (final status in [SessionStatus.canceledBySender, SessionStatus.canceledByReceiver, SessionStatus.finishedWithErrors]) {
      final entry = chatEntryFromSend(subsetSend(status), createdAt: created, removed: true);
      expect(entry.attachments.first.status, ChatAttachmentStatus.pending);
    }
    final active = subsetSend(SessionStatus.sending);
    final entry = chatEntryFromSend(
      active,
      createdAt: created,
      fileStatuses: {'a': FileStatus.finished, 'b': FileStatus.skipped, 'c': FileStatus.sending},
    );
    final canceled = chatEntryFromSend(
      active.copyWith(status: SessionStatus.canceledBySender),
      createdAt: created,
      removed: true,
      previous: entry,
    );
    expect(canceled.attachments.first.status, ChatAttachmentStatus.transferred);
    expect(canceled.attachments[1].status, ChatAttachmentStatus.skipped);
    expect(canceled.attachments.last.status, ChatAttachmentStatus.pending);
  });
  test('history hooks retain terminal results, stable time and skip bookkeeping writes', () async {
    var writes = 0;
    final store = ChatStoreService(
      read: () => null,
      write: (_) async {
        writes++;
      },
    );
    final ref = RefenaContainer(overrides: [chatStoreProvider.overrideWithNotifier((_) => store)]);
    final pending = send(SessionStatus.waiting);
    recordChatSendChanges(ref, {}, {'session': pending});
    final firstTime = ref.read(chatStoreProvider).entries.single.createdAt;
    final hashed = pending.copyWith(hashedFileCount: 0);
    recordChatSendChanges(ref, {'session': pending}, {'session': hashed});
    await store.flush();
    expect(writes, 2); // One semantic update plus the explicit flush.
    final finished = hashed.copyWith(status: SessionStatus.finished);
    recordChatSendChanges(ref, {'session': hashed}, {'session': finished});
    recordChatSendChanges(ref, {'session': finished}, {});
    expect(ref.read(chatStoreProvider).entries.single.status, ChatTransferStatus.succeeded);
    expect(ref.read(chatStoreProvider).entries.single.createdAt, firstTime);
    final canceled = receive(SessionStatus.canceledBySender);
    recordChatReceiveChanges(ref, null, canceled);
    recordChatReceiveChanges(ref, canceled, null);
    expect(ref.read(chatStoreProvider).entry('in:session')!.status, ChatTransferStatus.canceled);
    final active = receive(SessionStatus.sending).copyWith(sessionId: 'other');
    recordChatReceiveChanges(ref, null, active);
    recordChatReceiveChanges(ref, active, null);
    expect(ref.read(chatStoreProvider).entry('in:other')!.status, ChatTransferStatus.interrupted);
    await store.flush();
    ref.dispose(chatStoreProvider);
  });
  test('all protocol terminal states map truthfully', () {
    expect(chatStatusForSession(SessionStatus.waiting), ChatTransferStatus.pending);
    expect(chatStatusForSession(SessionStatus.sending), ChatTransferStatus.transferring);
    expect(chatStatusForSession(SessionStatus.finished), ChatTransferStatus.succeeded);
    expect(chatStatusForSession(SessionStatus.declined), ChatTransferStatus.declined);
    for (final s in [SessionStatus.finishedWithErrors, SessionStatus.recipientBusy, SessionStatus.tooManyAttempts]) {
      expect(chatStatusForSession(s), ChatTransferStatus.failed);
    }
    for (final s in [SessionStatus.canceledBySender, SessionStatus.canceledByReceiver]) {
      expect(chatStatusForSession(s, removed: true), ChatTransferStatus.canceled);
    }
  });
  test('removed background transfers cannot become false successes', () {
    for (final s in [SessionStatus.waiting, SessionStatus.sending]) {
      expect(chatEntryFromSend(send(s), createdAt: created, removed: true).status, ChatTransferStatus.interrupted);
    }
    expect(chatEntryFromSend(send(SessionStatus.finished), createdAt: created, removed: true).status, ChatTransferStatus.succeeded);
    expect(chatEntryFromSend(send(SessionStatus.canceledBySender), createdAt: created, removed: true).status, ChatTransferStatus.canceled);
  });
  test('history uses stable IDs, certificate identity and inline preview', () {
    final out = chatEntryFromSend(send(SessionStatus.waiting), createdAt: created);
    final incoming = chatEntryFromReceive(receive(SessionStatus.finished), createdAt: created);
    expect(out.id, 'out:session');
    expect(incoming.id, 'in:session');
    expect(incoming.peerFingerprint, 'certificate');
    expect(incoming.peerAlias, 'Display alias');
    expect(out.text, 'hello');
    expect(incoming.text, 'hello');
    expect(out.createdAt, created);
    expect(out.attachments, isEmpty);
  });
  test('ordinary file paths and file errors survive mapping', () {
    const binary = FileDto(id: 'f', fileName: 'a.bin', size: 5, fileType: FileType.other, hash: null, preview: null, metadata: null);
    final outgoing = send(SessionStatus.finishedWithErrors);
    final incoming = receive(SessionStatus.finished);
    final out = chatEntryFromSend(
      outgoing.copyWith(
        files: {'f': outgoing.files['f']!.copyWith(file: binary, errorMessage: 'failed')},
      ),
      createdAt: created,
    );
    final received = chatEntryFromReceive(
      incoming.copyWith(files: {'f': incoming.files['f']!.copyWith(file: binary)}),
      createdAt: created,
    );
    expect(out.attachments.single.path, '/source/hello.txt');
    expect(out.error, 'failed');
    expect(received.attachments.single.path, '/received/hello.txt');
  });
  test('auto acceptance requires current explicit trust AND matching certificate', () {
    const trusted = ChatDevicePreferences(fingerprint: 'certificate', trusted: true);
    bool allowed(String? cert, ChatDevicePreferences prefs) => canAutoAcceptChat(certFingerprint: cert, preferences: prefs);
    expect(allowed('certificate', trusted), isTrue);
    expect(allowed(null, trusted), isFalse);
    expect(allowed('', trusted), isFalse);
    expect(allowed('spoofed', trusted), isFalse);

    expect(allowed('certificate', trusted.copyWith(trusted: false)), isFalse);
    expect(allowed('certificate', const ChatDevicePreferences(fingerprint: 'certificate', pinned: true, alias: 'Trusted name')), isFalse);
  });
  test('caption and binary attachment map to one entry without saving a synthetic text file', () {
    const caption = '中文\n🙂';
    const carrier = FileDto(
      id: 'f',
      fileName: 'message.txt',
      size: 11,
      fileType: FileType.text,
      hash: null,
      preview: '$chatCaptionPrefix$caption',
      metadata: null,
    );
    const binary = FileDto(id: 'b', fileName: 'payload.bin', size: 5, fileType: FileType.other, hash: null, preview: null, metadata: null);
    final outgoing = send(SessionStatus.sending);
    final incoming = receive(SessionStatus.sending);
    final mixedSend = outgoing.copyWith(
      remoteSessionId: 'accepted',
      files: {
        'f': outgoing.files['f']!.copyWith(file: carrier, token: null),
        'b': outgoing.files['f']!.copyWith(file: binary, token: 'upload-token'),
      },
    );
    final mixedReceive = incoming.copyWith(
      files: {
        'f': incoming.files['f']!.copyWith(file: carrier, desiredName: null),
        'b': incoming.files['f']!.copyWith(file: binary, desiredName: binary.fileName),
      },
    );
    final sent = chatEntryFromSend(mixedSend, createdAt: created, fileStatuses: {'f': FileStatus.skipped, 'b': FileStatus.sending});
    final received = chatEntryFromReceive(mixedReceive, createdAt: created);
    expect(chatFilesToAccept(mixedReceive), {'b': 'payload.bin'});
    expect(chatFilesToAccept(incoming), isEmpty);
    expect(sent.text, caption);
    expect(sent.textDelivered, isTrue);
    expect(sent.attachments.single.name, 'payload.bin');
    expect(received.text, caption);
    expect(received.attachments.single.name, 'payload.bin');
    expect(
      chatCaptionCarrier([
        const FileDto(
          id: 'f',
          fileName: 'message.txt',
          size: 12,
          fileType: FileType.text,
          hash: null,
          preview: '$chatCaptionPrefix$caption',
          metadata: null,
        ),
        binary,
      ]),
      isNull,
    );
    expect(chatCaptionCarrier([carrier, carrier, binary]), isNull);
  });
}
