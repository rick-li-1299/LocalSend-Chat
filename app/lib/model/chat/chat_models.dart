import 'package:localsend_app/model/chat/chat_group.dart';
import 'package:localsend_isolates/model/file_type.dart';

const _unset = Object();

enum ChatTransferStatus {
  pending,
  transferring,
  succeeded,
  failed,
  canceled,
  interrupted,
  declined
  ;

  bool get isActive => this == pending || this == transferring;
}

enum ChatAttachmentStatus { pending, transferred, skipped, failed }

class ChatAttachment {
  final String name;
  final int size;
  final String? path;
  final FileType fileType;
  final ChatAttachmentStatus status;
  final String? error;

  const ChatAttachment({
    required this.name,
    required this.size,
    this.path,
    required this.fileType,
    this.status = ChatAttachmentStatus.pending,
    this.error,
  });

  ChatAttachment copyWith({
    String? name,
    int? size,
    Object? path = _unset,
    FileType? fileType,
    ChatAttachmentStatus? status,
    Object? error = _unset,
  }) => ChatAttachment(
    name: name ?? this.name,
    size: size ?? this.size,
    path: identical(path, _unset) ? this.path : path as String?,
    fileType: fileType ?? this.fileType,
    status: status ?? this.status,
    error: identical(error, _unset) ? this.error : error as String?,
  );

  Map<String, dynamic> toJson() => {'name': name, 'size': size, 'path': path, 'fileType': fileType.name, 'status': status.name, 'error': error};

  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    final size = json['size'] as int;
    if (size < 0) throw const FormatException('Invalid attachment size');
    return ChatAttachment(
      name: json['name'] as String,
      size: size,
      path: json['path'] as String?,
      fileType: FileType.values.byName(json['fileType'] as String),
      status: json.containsKey('status') ? ChatAttachmentStatus.values.byName(json['status'] as String) : ChatAttachmentStatus.pending,
      error: json['error'] as String?,
    );
  }
}

class ChatEntry {
  final String id;
  final String peerFingerprint;
  final String peerAlias;
  final bool outgoing;
  final DateTime createdAt;
  final ChatTransferStatus status;
  final List<ChatAttachment> attachments;
  final String? text;
  final bool textDelivered;
  final String? error;
  final String? groupId;
  final String? groupMessageId;
  final ChatReply? reply;
  final List<String> mentions;
  final bool groupInvitation;

  ChatEntry({
    required this.id,
    required this.peerFingerprint,
    required this.peerAlias,
    required this.outgoing,
    required this.createdAt,
    required this.status,
    List<ChatAttachment> attachments = const [],
    this.text,
    this.textDelivered = false,
    this.error,
    this.groupId,
    this.groupMessageId,
    this.reply,
    List<String> mentions = const [],
    this.groupInvitation = false,
  }) : attachments = List.unmodifiable(attachments),
       mentions = List.unmodifiable(mentions);

  ChatEntry copyWith({
    String? id,
    String? peerFingerprint,
    String? peerAlias,
    bool? outgoing,
    DateTime? createdAt,
    ChatTransferStatus? status,
    List<ChatAttachment>? attachments,
    Object? text = _unset,
    bool? textDelivered,
    Object? error = _unset,
    String? groupId,
    String? groupMessageId,
  }) => ChatEntry(
    id: id ?? this.id,
    peerFingerprint: peerFingerprint ?? this.peerFingerprint,
    peerAlias: peerAlias ?? this.peerAlias,
    outgoing: outgoing ?? this.outgoing,
    createdAt: createdAt ?? this.createdAt,
    status: status ?? this.status,
    attachments: attachments ?? this.attachments,
    text: identical(text, _unset) ? this.text : text as String?,
    textDelivered: textDelivered ?? this.textDelivered,
    error: identical(error, _unset) ? this.error : error as String?,
    groupId: groupId ?? this.groupId,
    groupMessageId: groupMessageId ?? this.groupMessageId,
    reply: reply,
    mentions: mentions,
    groupInvitation: groupInvitation,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'peerFingerprint': peerFingerprint,
    'peerAlias': peerAlias,
    'outgoing': outgoing,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'attachments': attachments.map((e) => e.toJson()).toList(),
    'text': text,
    'textDelivered': textDelivered,
    'error': error,
    if (groupId != null) 'groupId': groupId,
    if (groupMessageId != null) 'groupMessageId': groupMessageId,
    if (reply != null) 'reply': reply!.toJson(),
    if (mentions.isNotEmpty) 'mentions': mentions,
    if (groupInvitation) 'groupInvitation': true,
  };

  factory ChatEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final outgoing = json['outgoing'] as bool;
    final prefix = outgoing ? 'out:' : 'in:';
    final fingerprint = json['peerFingerprint'] as String;
    if (!id.startsWith(prefix) || id.length == prefix.length || fingerprint.isEmpty) {
      throw const FormatException('Invalid chat identity');
    }
    return ChatEntry(
      id: id,
      peerFingerprint: fingerprint,
      peerAlias: json['peerAlias'] as String,
      outgoing: outgoing,
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: ChatTransferStatus.values.byName(json['status'] as String),
      attachments: (json['attachments'] as List).map((e) => ChatAttachment.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
      text: json['text'] as String?,
      textDelivered: json['textDelivered'] as bool? ?? false,
      error: json['error'] as String?,
      groupId: json['groupId'] as String?,
      groupMessageId: json['groupMessageId'] as String?,
      reply: json['reply'] == null ? null : ChatReply.fromJson(json['reply'] as Map<String, dynamic>),
      mentions: List<String>.from(json['mentions'] as List? ?? const []),
      groupInvitation: json['groupInvitation'] as bool? ?? false,
    );
  }
}

class ChatDevicePreferences {
  final String fingerprint;
  final String? alias;
  final bool pinned;
  final bool trusted;
  final String? receiveDirectory;
  final bool muted;

  const ChatDevicePreferences({
    required this.fingerprint,
    this.alias,
    this.pinned = false,
    this.trusted = false,
    this.receiveDirectory,
    this.muted = false,
  });

  ChatDevicePreferences copyWith({
    String? fingerprint,
    Object? alias = _unset,
    bool? pinned,
    bool? trusted,
    Object? receiveDirectory = _unset,
    bool? muted,
  }) => ChatDevicePreferences(
    fingerprint: fingerprint ?? this.fingerprint,
    alias: identical(alias, _unset) ? this.alias : alias as String?,
    pinned: pinned ?? this.pinned,
    trusted: trusted ?? this.trusted,
    receiveDirectory: identical(receiveDirectory, _unset) ? this.receiveDirectory : receiveDirectory as String?,
    muted: muted ?? this.muted,
  );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'alias': alias,
    'pinned': pinned,
    'trusted': trusted,
    if (receiveDirectory != null) 'receiveDirectory': receiveDirectory,
    if (muted) 'muted': true,
  };

  factory ChatDevicePreferences.fromJson(Map<String, dynamic> json) {
    final fingerprint = json['fingerprint'] as String;
    if (fingerprint.isEmpty) throw const FormatException('Invalid device identity');
    return ChatDevicePreferences(
      fingerprint: fingerprint,
      alias: json['alias'] as String?,
      pinned: json['pinned'] as bool? ?? false,
      trusted: json['trusted'] as bool? ?? false,
      receiveDirectory: json['receiveDirectory'] as String?,
      muted: json['muted'] as bool? ?? false,
    );
  }
}

class ChatStoreState {
  final List<ChatEntry> entries;
  final Map<String, ChatDevicePreferences> devices;
  final Map<String, ChatGroup> groups;
  final String? persistenceError;

  ChatStoreState({
    List<ChatEntry> entries = const [],
    Map<String, ChatDevicePreferences> devices = const {},
    Map<String, ChatGroup> groups = const {},
    this.persistenceError,
  }) : entries = List.unmodifiable(entries),
       devices = Map.unmodifiable(devices),
       groups = Map.unmodifiable(groups);

  ChatDevicePreferences preferencesFor(String fingerprint) => devices[fingerprint] ?? ChatDevicePreferences(fingerprint: fingerprint);

  ChatEntry? entry(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  ChatEntry? receivedGroupMessage(String groupId, String sender, String messageId) {
    for (final entry in entries.reversed) {
      if (!entry.outgoing && entry.groupId == groupId && entry.peerFingerprint == sender && entry.groupMessageId == messageId) return entry;
    }
    return null;
  }
}
