import 'dart:convert';

const chatGroupCarrierName = '.localsend-group-v1.json';
const chatReplyCarrierName = '.localsend-reply-v1.json';
const chatGroupDeviceMarker = ' [LocalSend Chat Groups v1]';
const chatAdvancedDeviceMarker = ' [LocalSend Chat Groups v2]';
const chatGroupPacketLimit = 65536;

final _uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
final _fingerprint = RegExp(r'^[0-9A-Fa-f]{64}$');

bool supportsAdvancedChat(String? model) => model?.contains('$chatAdvancedDeviceMarker$chatGroupDeviceMarker') ?? false;

class ChatReply {
  final String author;
  final String excerpt;

  const ChatReply({required this.author, required this.excerpt});

  Map<String, String> toJson() => {'author': author, 'excerpt': excerpt};

  factory ChatReply.fromJson(Map<String, dynamic> json) {
    final author = json['author'] as String;
    final excerpt = json['excerpt'] as String;
    if (author.isEmpty || author.length > 160 || excerpt.trim().isEmpty || excerpt.length > 500) {
      throw const FormatException('Invalid reply');
    }
    return ChatReply(author: author, excerpt: excerpt);
  }
}

class ChatGroup {
  final String id;
  final String name;
  final String owner;
  final Map<String, String> members;
  final Set<String> admins;
  final Set<String> removed;
  final Set<String> added;
  final int revision;
  final String announcement;

  ChatGroup({
    required this.id,
    required this.name,
    required this.owner,
    required Map<String, String> members,
    Set<String> admins = const {},
    Set<String> removed = const {},
    Set<String> added = const {},
    this.revision = 0,
    this.announcement = '',
  }) : members = Map.unmodifiable(members),
       admins = Set.unmodifiable(admins),
       removed = Set.unmodifiable(removed),
       added = Set.unmodifiable(added);

  String get conversationId => 'group:$id';

  bool canManage(String member) => member == owner || admins.contains(member);

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'owner': owner,
    'members': members,
    if (revision != 0) 'revision': revision,
    if (admins.isNotEmpty) 'admins': (admins.toList()..sort()),
    if (removed.isNotEmpty) 'removed': (removed.toList()..sort()),
    if (added.isNotEmpty) 'added': (added.toList()..sort()),
    if (announcement.isNotEmpty) 'announcement': announcement,
  };

  factory ChatGroup.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final name = json['name'] as String;
    final owner = json['owner'] as String;
    final members = Map<String, String>.from(json['members'] as Map);
    final admins = Set<String>.from(json['admins'] as List? ?? const []);
    final removed = Set<String>.from(json['removed'] as List? ?? const []);
    final added = Set<String>.from(json['added'] as List? ?? const []);
    final revision = json['revision'] as int? ?? 0;
    final announcement = json['announcement'] as String? ?? '';
    if (!_uuid.hasMatch(id) ||
        name.trim().isEmpty ||
        name.length > 160 ||
        members.length < (revision == 0 ? 3 : 1) ||
        members.length > 32 ||
        !members.containsKey(owner) ||
        members.entries.any((member) => !_fingerprint.hasMatch(member.key) || member.value.length > 160 || member.value.trim().isEmpty) ||
        admins.any((id) => id == owner || !members.containsKey(id)) ||
        removed.any((id) => members.containsKey(id) || !_fingerprint.hasMatch(id)) ||
        added.any((id) => id == owner || !members.containsKey(id)) ||
        revision < 0 ||
        (revision == 0 && (admins.isNotEmpty || removed.isNotEmpty || added.isNotEmpty || announcement.isNotEmpty)) ||
        announcement.length > 2000) {
      throw const FormatException('Invalid chat group');
    }
    return ChatGroup(
      id: id,
      name: name,
      owner: owner,
      members: members,
      admins: admins,
      removed: removed,
      added: added,
      revision: revision,
      announcement: announcement,
    );
  }

  ChatGroup? apply(ChatGroupChange change, String actor) {
    if (!canManage(actor) || change.baseRevision != revision) return null;
    final members = {...this.members};
    final admins = {...this.admins};
    final removed = {...this.removed};
    final added = {...this.added};
    var announcement = this.announcement;
    final target = change.target;
    final value = change.value;
    switch (change.action) {
      case ChatGroupAction.add:
        if (target == null ||
            !_fingerprint.hasMatch(target) ||
            members.containsKey(target) ||
            members.length >= 32 ||
            value == null ||
            value.trim().isEmpty ||
            value.length > 160) {
          return null;
        }
        members[target] = value;
        removed.remove(target);
        added.add(target);
      case ChatGroupAction.remove:
        if (target == null || target == owner || !members.containsKey(target) || (actor != owner && admins.contains(target))) return null;
        members.remove(target);
        admins.remove(target);
        removed.add(target);
        added.remove(target);
      case ChatGroupAction.promote:
        if (actor != owner || target == null || target == owner || !members.containsKey(target) || !admins.add(target)) return null;
      case ChatGroupAction.demote:
        if (actor != owner || !admins.remove(target)) return null;
      case ChatGroupAction.announce:
        if (value == null || value.length > 2000 || announcement == value.trim()) return null;
        announcement = value.trim();
    }
    final updated = ChatGroup(
      id: id,
      name: name,
      owner: owner,
      members: members,
      admins: admins,
      removed: removed,
      added: added,
      revision: revision + 1,
      announcement: announcement,
    );
    return utf8.encode(jsonEncode(updated.toJson())).length < chatGroupPacketLimit - 512 ? updated : null;
  }
}

enum ChatGroupAction { add, remove, promote, demote, announce }

class ChatGroupChange {
  final ChatGroupAction action;
  final int baseRevision;
  final String? target;
  final String? value;

  const ChatGroupChange(this.action, this.baseRevision, {this.target, this.value});

  Map<String, Object?> toJson() => {'action': action.name, 'base': baseRevision, 'target': target, 'value': value};

  factory ChatGroupChange.fromJson(Map<String, dynamic> json) => ChatGroupChange(
    ChatGroupAction.values.byName(json['action'] as String),
    json['base'] as int,
    target: json['target'] as String?,
    value: json['value'] as String?,
  );
}

class ChatGroupPacket {
  final String groupId;
  final String messageId;
  final ChatGroup? invitation;
  final ChatGroup? snapshot;
  final ChatGroupChange? change;
  final String? text;
  final ChatReply? reply;
  final List<String> mentions;
  final int revision;
  final bool deduplicate;

  const ChatGroupPacket({
    required this.groupId,
    required this.messageId,
    this.invitation,
    this.snapshot,
    this.change,
    this.text,
    this.reply,
    this.mentions = const [],
    this.revision = 0,
    this.deduplicate = false,
  });

  bool get isControl => snapshot != null || change != null;
  bool get isDirectReply => groupId.isEmpty;

  String encode() => jsonEncode({
    'group': groupId,
    'message': messageId,
    if (invitation != null) 'invitation': invitation!.toJson(),
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
    if (change != null) 'change': change!.toJson(),
    if (text != null) 'text': text,
    if (reply != null) 'reply': reply!.toJson(),
    if (mentions.isNotEmpty) 'mentions': mentions,
    if (revision != 0) 'revision': revision,
    if (deduplicate) 'deduplicate': true,
  });

  static ChatGroupPacket? decode(String value) {
    if (value.length > chatGroupPacketLimit || utf8.encode(value).length > chatGroupPacketLimit) return null;
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      final group = json['group'] as String;
      final message = json['message'] as String;
      if ((group.isNotEmpty && !_uuid.hasMatch(group)) || !_uuid.hasMatch(message)) return null;
      final invitation = json['invitation'] == null ? null : ChatGroup.fromJson(json['invitation'] as Map<String, dynamic>);
      final snapshot = json['snapshot'] == null ? null : ChatGroup.fromJson(json['snapshot'] as Map<String, dynamic>);
      final change = json['change'] == null ? null : ChatGroupChange.fromJson(json['change'] as Map<String, dynamic>);
      final text = json['text'] as String?;
      final reply = json['reply'] == null ? null : ChatReply.fromJson(json['reply'] as Map<String, dynamic>);
      final mentions = List<String>.from(json['mentions'] as List? ?? const []);
      final revision = json['revision'] as int? ?? 0;
      final deduplicate = json['deduplicate'] as bool? ?? false;
      if (mentions.length > 32 || mentions.any((id) => !_fingerprint.hasMatch(id)) || revision < 0) return null;
      final controls = [invitation, snapshot, change].whereType<Object>().length;
      if (controls > 1 ||
          (controls == 1 && (group.isEmpty || text != null || reply != null || mentions.isNotEmpty || revision != 0 || deduplicate)) ||
          (invitation != null && invitation.id != group) ||
          (snapshot != null && snapshot.id != group) ||
          (group.isEmpty && (reply == null || mentions.isNotEmpty || revision != 0 || deduplicate))) {
        return null;
      }
      return ChatGroupPacket(
        groupId: group,
        messageId: message,
        invitation: invitation,
        snapshot: snapshot,
        change: change,
        text: text,
        reply: reply,
        mentions: List.unmodifiable(mentions),
        revision: revision,
        deduplicate: deduplicate,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
