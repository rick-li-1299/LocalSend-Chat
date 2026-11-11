import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/provider/chat_store_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

ChatTransferStatus chatStatusForSession(SessionStatus status, {bool removed = false}) {
  return switch (status) {
    SessionStatus.waiting => removed ? ChatTransferStatus.interrupted : ChatTransferStatus.pending,
    SessionStatus.sending => removed ? ChatTransferStatus.interrupted : ChatTransferStatus.transferring,
    SessionStatus.finished => ChatTransferStatus.succeeded,
    SessionStatus.declined => ChatTransferStatus.declined,
    SessionStatus.canceledBySender || SessionStatus.canceledByReceiver => ChatTransferStatus.canceled,
    SessionStatus.finishedWithErrors || SessionStatus.recipientBusy || SessionStatus.tooManyAttempts => ChatTransferStatus.failed,
  };
}

/// The existing LocalSend text preview carries a versioned caption in a mixed
/// transfer. Legacy receivers can still download its UTF-8 message.txt.
const chatCaptionPrefix = 'localsend-chat-caption-v1:';

// Older builds inferred application/json from the filename on the wire.
bool isChatGroupCarrier(FileDto file) =>
    file.fileName == chatGroupCarrierName && (file.fileType == FileType.text || file.fileType == FileType.other) && file.preview != null;
bool isChatReplyCarrier(FileDto file) => file.fileName == chatReplyCarrierName && file.fileType == FileType.text && file.preview != null;

FileDto? chatGroupCarrier(Iterable<FileDto> files) {
  final matches = files.where((file) => isChatGroupCarrier(file) || isChatReplyCarrier(file));
  return matches.length == 1 ? matches.single : null;
}

ChatGroupPacket? chatGroupPacket(Iterable<FileDto> files) {
  final carrier = chatGroupCarrier(files);
  if (carrier == null || carrier.size > 65536 || carrier.preview!.length > 65536 || utf8.encode(carrier.preview!).length != carrier.size) return null;
  final packet = ChatGroupPacket.decode(carrier.preview!);
  return packet != null && packet.isDirectReply == isChatReplyCarrier(carrier) ? packet : null;
}

ChatGroupPacket? chatGroupRequest(ReceiveSessionState session) => chatGroupPacket(session.files.values.map((file) => file.file));

bool authorizesChatGroupPacket({
  required ChatGroupPacket packet,
  required String? certificate,
  required String ownFingerprint,
  required ChatGroup? knownGroup,
}) {
  if (certificate == null || certificate == ownFingerprint) return false;
  if (packet.isDirectReply) return true;
  final invitation = packet.invitation;
  if (invitation != null) {
    return invitation.owner == certificate &&
        invitation.members.containsKey(ownFingerprint) &&
        (knownGroup == null ||
            (knownGroup.owner == certificate &&
                (invitation.revision > knownGroup.revision || const DeepCollectionEquality().equals(invitation.toJson(), knownGroup.toJson()))));
  }
  if (knownGroup == null) return false;
  if (packet.snapshot case final snapshot?) {
    return certificate == knownGroup.owner &&
        snapshot.owner == knownGroup.owner &&
        snapshot.revision > 0 &&
        (snapshot.members.containsKey(ownFingerprint) || snapshot.removed.contains(ownFingerprint)) &&
        (snapshot.revision > knownGroup.revision || const DeepCollectionEquality().equals(snapshot.toJson(), knownGroup.toJson()));
  }
  if (packet.change != null) return ownFingerprint == knownGroup.owner && knownGroup.canManage(certificate);
  return knownGroup.members.containsKey(certificate) &&
      knownGroup.members.containsKey(ownFingerprint) &&
      packet.revision <= knownGroup.revision &&
      (knownGroup.revision == 0 || packet.deduplicate) &&
      packet.mentions.every((id) => knownGroup.members.containsKey(id) || knownGroup.removed.contains(id));
}

bool matchesGroupRetry(ChatGroupPacket packet, Iterable<FileDto> files, ChatEntry previous) {
  final attachments = files.where((file) => !isChatGroupCarrier(file)).sortedBy((file) => file.id);
  return packet.text == previous.text &&
      const DeepCollectionEquality().equals(packet.reply?.toJson(), previous.reply?.toJson()) &&
      const DeepCollectionEquality().equals(packet.mentions, previous.mentions) &&
      attachments.length == previous.attachments.length &&
      attachments.indexed.every(
        (item) =>
            item.$2.fileName == previous.attachments[item.$1].name &&
            item.$2.size == previous.attachments[item.$1].size &&
            item.$2.fileType == previous.attachments[item.$1].fileType,
      );
}

FileDto? chatCaptionCarrier(Iterable<FileDto> files) {
  if (files.length < 2) return null;
  final matches = files.where((file) {
    final preview = file.preview;
    if (file.fileType != FileType.text || file.fileName != 'message.txt' || preview == null || !preview.startsWith(chatCaptionPrefix)) {
      return false;
    }
    final caption = preview.substring(chatCaptionPrefix.length);
    return caption.trim().isNotEmpty && file.size <= 65536 && utf8.encode(caption).length == file.size;
  });
  return matches.length == 1 ? matches.single : null;
}

String? chatRequestText(ReceiveSessionState session) {
  final group = chatGroupRequest(session);
  if (group != null) return group.text;
  return session.message ?? chatCaptionCarrier(session.files.values.map((f) => f.file))?.preview?.substring(chatCaptionPrefix.length);
}

Map<String, String> chatFilesToAccept(ReceiveSessionState session) {
  if (session.message != null) return {};
  final files = session.files.values.map((f) => f.file);
  final carrier = chatGroupCarrier(files) ?? chatCaptionCarrier(files);
  final ordered = chatGroupRequest(session)?.deduplicate == true ? session.files.values.sortedBy((file) => file.file.id) : session.files.values;
  return {
    for (final f in ordered)
      if (f.file.id != carrier?.id) f.file.id: f.file.fileName,
  };
}

/// A pinned conversation or a self-reported fingerprint is not consent.
bool canAutoAcceptChat({required String? certFingerprint, required ChatDevicePreferences preferences}) {
  return certFingerprint != null && certFingerprint.isNotEmpty && preferences.fingerprint == certFingerprint && preferences.trusted;
}

/// Persist explicit per-file results, never infer delivery from session closure.
/// A terminal live status is authoritative. While the provider is being cleaned
/// up, reuse the last recorded result before considering conservative fallbacks.
ChatAttachmentStatus chatAttachmentStatus({
  required SessionStatus sessionStatus,
  required bool selected,
  required bool received,
  String? receivedPath,
  String? error,
  FileStatus? liveStatus,
  ChatAttachmentStatus? previousStatus,
}) {
  if (liveStatus == FileStatus.finished) return ChatAttachmentStatus.transferred;
  if (liveStatus == FileStatus.failed) return ChatAttachmentStatus.failed;
  if (liveStatus == FileStatus.skipped) return ChatAttachmentStatus.skipped;
  if (error != null) return ChatAttachmentStatus.failed;
  if (received && receivedPath != null) return ChatAttachmentStatus.transferred;
  final selectionKnown = const {SessionStatus.sending, SessionStatus.finished, SessionStatus.finishedWithErrors}.contains(sessionStatus);
  if (selectionKnown && !selected) return ChatAttachmentStatus.skipped;
  // Missing live state during removal is not a fresh queued transfer.
  if (liveStatus == null && previousStatus != null && previousStatus != ChatAttachmentStatus.pending) return previousStatus;
  if (sessionStatus == SessionStatus.finished && selected) return ChatAttachmentStatus.transferred;
  // On mixed failures or cancellation, a token alone proves acceptance, not
  // delivery. Unknown outcomes stay pending (the entry itself is terminal).
  return ChatAttachmentStatus.pending;
}

ChatEntry chatEntryFromSend(
  SendSessionState session, {
  required DateTime createdAt,
  bool removed = false,
  Map<String, FileStatus> fileStatuses = const {},
  ChatEntry? previous,
}) {
  final files = session.files.values;
  final group = chatGroupPacket(files.map((f) => f.file));
  final groupCarrier = group == null ? null : chatGroupCarrier(files.map((f) => f.file));
  final carrier = chatCaptionCarrier(files.map((f) => f.file));
  final text = group != null
      ? group.text
      : (carrier?.preview?.substring(chatCaptionPrefix.length) ??
            (files.length == 1 && files.first.file.fileType == FileType.text ? files.first.file.preview : null));
  final accepted =
      session.status == SessionStatus.finished ||
      (carrier != null && session.remoteSessionId != null && fileStatuses[carrier.id] == FileStatus.skipped) ||
      (carrier != null && fileStatuses[carrier.id] == FileStatus.finished);
  return ChatEntry(
    id: 'out:${session.sessionId}',
    peerFingerprint: session.target.fingerprint,
    peerAlias: session.target.alias,
    outgoing: true,
    createdAt: createdAt,
    status: chatStatusForSession(session.status, removed: removed),
    groupId: group?.isDirectReply == false ? group!.groupId : null,
    groupMessageId: group?.isDirectReply == false ? group!.messageId : null,
    groupInvitation: group?.invitation != null,
    reply: group?.reply,
    mentions: group?.mentions ?? const [],
    text: text,
    textDelivered: text != null && (accepted || previous?.textDelivered == true),
    attachments: files.where((f) => f.file.id != (groupCarrier ?? carrier)?.id && !(group == null && carrier == null && text != null)).indexed.map((
      item,
    ) {
      final (index, f) = item;
      return ChatAttachment(
        name: f.file.fileName,
        size: f.file.size,
        path: f.path,
        fileType: f.file.fileType,
        status:
            group?.deduplicate == true &&
                ((session.status == SessionStatus.finished && session.remoteSessionId == null) ||
                    (session.remoteSessionId != null && fileStatuses[f.file.id] == FileStatus.skipped))
            ? ChatAttachmentStatus.transferred
            : chatAttachmentStatus(
                sessionStatus: session.status,
                selected: f.token != null,
                received: false,
                error: f.errorMessage,
                liveStatus: fileStatuses[f.file.id],
                previousStatus: previous?.attachments.elementAtOrNull(index)?.status,
              ),
        error: f.errorMessage,
      );
    }).toList(),

    error:
        session.errorMessage ??
        files.map((f) => f.errorMessage).whereType<String>().firstOrNull ??
        switch (session.status) {
          SessionStatus.recipientBusy => 'The recipient is busy.',
          SessionStatus.tooManyAttempts => 'Too many attempts. Try again later.',
          _ => null,
        },
  );
}

ChatEntry chatEntryFromReceive(
  ReceiveSessionState session, {
  required DateTime createdAt,
  bool removed = false,
  Map<String, FileStatus> fileStatuses = const {},
  ChatEntry? previous,
}) {
  final text = chatRequestText(session);
  final group = chatGroupRequest(session);
  final files = session.files.values.map((f) => f.file);
  final carrier = chatGroupCarrier(files) ?? chatCaptionCarrier(files);
  final ordered = group?.deduplicate == true ? session.files.values.sortedBy((file) => file.file.id) : session.files.values;
  return ChatEntry(
    id: 'in:${session.sessionId}',
    peerFingerprint: session.sender.fingerprint,
    peerAlias: session.senderAlias,
    outgoing: false,
    createdAt: createdAt,
    status: chatStatusForSession(session.status, removed: removed),
    groupId: group?.isDirectReply == false ? group!.groupId : null,
    groupMessageId: group?.isDirectReply == false ? group!.messageId : null,
    reply: group?.reply,
    mentions: group?.mentions ?? const [],
    text: text,
    attachments: session.message == null
        ? ordered.where((f) => f.file.id != carrier?.id).indexed.map((item) {
            final (index, f) = item;
            final prior = previous?.attachments.elementAtOrNull(index);
            if (group?.deduplicate == true && prior?.status == ChatAttachmentStatus.transferred && f.desiredName == null) return prior!;
            return ChatAttachment(
              name: group?.deduplicate == true ? f.file.fileName : f.desiredName ?? f.file.fileName,
              size: f.file.size,
              path: f.path,
              fileType: f.file.fileType,
              status: chatAttachmentStatus(
                sessionStatus: session.status,
                selected: f.desiredName != null,
                received: true,
                receivedPath: f.path,
                error: f.errorMessage,
                liveStatus: fileStatuses[f.file.id],
                previousStatus: previous?.attachments.elementAtOrNull(index)?.status,
              ),
              error: f.errorMessage,
            );
          }).toList()
        : [],
    error: session.files.values.map((f) => f.errorMessage).whereType<String>().firstOrNull,
  );
}

Map<String, FileStatus> _liveStatuses(Ref ref, String sessionId, Iterable<String> fileIds) {
  final transfers = ref.read(fileTransferProvider);
  if (transfers.getStatuses(sessionId).isEmpty) return const {};
  return {for (final id in fileIds) id: transfers.getStatus(sessionId: sessionId, fileId: id)};
}

void recordChatSendChanges(Ref ref, Map<String, SendSessionState> previous, Map<String, SendSessionState> next) {
  for (final id in {...previous.keys, ...next.keys}) {
    if (identical(previous[id], next[id])) continue;
    final session = next[id] ?? previous[id]!;
    final existing = ref.read(chatStoreProvider).entry('out:$id');
    if (chatGroupPacket(session.files.values.map((file) => file.file))?.isControl == true) continue;
    _record(
      ref,
      chatEntryFromSend(
        session,
        createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
        removed: !next.containsKey(id),
        fileStatuses: _liveStatuses(ref, id, session.files.keys),
        previous: existing,
      ),
      existing,
    );
  }
}

void recordChatReceiveChanges(Ref ref, ReceiveSessionState? previous, ReceiveSessionState? next) {
  if (identical(previous, next)) return;
  if (previous != null && previous.sessionId != next?.sessionId && chatGroupRequest(previous)?.invitation == null) {
    final existing = ref.read(chatStoreProvider).entry('in:${previous.sessionId}');
    _record(
      ref,
      chatEntryFromReceive(
        previous,
        createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
        removed: true,
        fileStatuses: _liveStatuses(ref, previous.sessionId, previous.files.keys),
        previous: existing,
      ),
      existing,
    );
  }
  if (next != null && chatGroupRequest(next)?.invitation == null) {
    final history = ref.read(chatStoreProvider);
    final packet = chatGroupRequest(next);
    final existing =
        history.entry('in:${next.sessionId}') ??
        (packet?.deduplicate == true ? history.receivedGroupMessage(packet!.groupId, next.sender.fingerprint, packet.messageId) : null);
    _record(
      ref,
      chatEntryFromReceive(
        next,
        createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
        fileStatuses: _liveStatuses(ref, next.sessionId, next.files.keys),
        previous: existing,
      ),
      existing,
    );
  }
}

void _record(Ref ref, ChatEntry entry, ChatEntry? existing) {
  // Byte progress lives in fileTransferProvider. Checksum/task bookkeeping must
  // not cause disk writes either. Store changes synchronously before awaiting IO.
  if (existing != null && const DeepCollectionEquality().equals(existing.toJson(), entry.toJson())) return;
  unawaited(ref.notifier(chatStoreProvider).upsertEntry(entry, replaces: existing?.id));
}
