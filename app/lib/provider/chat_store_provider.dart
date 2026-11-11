import 'dart:convert';

import 'package:localsend_app/model/chat/chat_group.dart';
import 'package:localsend_app/model/chat/chat_models.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

export 'package:localsend_app/model/chat/chat_group.dart';
export 'package:localsend_app/model/chat/chat_models.dart';

final chatStoreProvider = NotifierProvider<ChatStoreService, ChatStoreState>((ref) {
  final persistence = ref.read(persistenceProvider);
  return ChatStoreService(read: persistence.getChatWorkspace, write: persistence.setChatWorkspace);
});

/// Metadata only: clearing history never deletes any transferred file.
class ChatStoreService extends Notifier<ChatStoreState> {
  final String? Function() _read;
  final Future<void> Function(String) _write;
  final int maxTerminalEntries;
  Future<void> _pending = Future.value();
  final _updatingGroups = <String>{};
  bool _blocked = false;

  bool get requiresReset => _blocked;

  ChatStoreService({required String? Function() read, required Future<void> Function(String) write, this.maxTerminalEntries = 1000})
    : _read = read,
      _write = write;

  @override
  ChatStoreState init() {
    try {
      final raw = _read();
      if (raw == null) return ChatStoreState();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException('Unsupported chat storage version');
      final entries = <String, ChatEntry>{};
      for (final value in json['entries'] as List) {
        var entry = ChatEntry.fromJson(Map<String, dynamic>.from(value as Map));
        if (entry.status.isActive) entry = entry.copyWith(status: ChatTransferStatus.interrupted);
        entry = entry.copyWith(createdAt: entries[entry.id]?.createdAt ?? entry.createdAt);
        entries[entry.id] = entry;
      }
      final devices = <String, ChatDevicePreferences>{};
      for (final value in json['devices'] as List) {
        final device = ChatDevicePreferences.fromJson(Map<String, dynamic>.from(value as Map));
        devices[device.fingerprint] = device;
      }
      final groups = <String, ChatGroup>{};
      for (final value in json['groups'] as List? ?? const []) {
        final group = ChatGroup.fromJson(Map<String, dynamic>.from(value as Map));
        groups[group.id] = group;
      }
      return ChatStoreState(entries: _limit(entries.values), devices: devices, groups: groups);
    } catch (_) {
      // Do not expose decoder exceptions: they can contain private chat text.
      _blocked = true;
      return ChatStoreState(persistenceError: 'Chat history could not be read. Existing data is preserved; reset history to enable saving.');
    }
  }

  List<ChatEntry> _limit(Iterable<ChatEntry> entries) {
    final sorted = entries.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var remaining = maxTerminalEntries;
    return sorted.reversed.where((entry) => entry.status.isActive || remaining-- > 0).toList().reversed.toList();
  }

  Future<void> upsertEntry(ChatEntry entry, {String? replaces}) {
    final old = state.entry(entry.id);
    final updated = entry.copyWith(createdAt: old?.createdAt ?? entry.createdAt);
    state = ChatStoreState(
      entries: _limit([...state.entries.where((e) => e.id != entry.id && e.id != replaces), updated]),
      devices: state.devices,
      groups: state.groups,
      persistenceError: state.persistenceError,
    );
    return _save();
  }

  Future<void> setDevice(ChatDevicePreferences device) {
    state = ChatStoreState(
      entries: state.entries,
      devices: {...state.devices, device.fingerprint: device},
      groups: state.groups,
      persistenceError: state.persistenceError,
    );
    return _save();
  }

  Future<void> clearConversation(String fingerprint) {
    state = ChatStoreState(
      entries: state.entries.where((e) => e.groupId != null || e.peerFingerprint != fingerprint).toList(),
      devices: state.devices,
      groups: state.groups,
      persistenceError: state.persistenceError,
    );
    return _save();
  }

  Future<void> addGroup(ChatGroup group) async {
    if (_blocked) throw StateError('Chat storage is unavailable');
    if (state.groups.containsKey(group.id)) return;
    state = ChatStoreState(entries: state.entries, devices: state.devices, groups: {...state.groups, group.id: group});
    await _save();
    if (state.persistenceError != null) {
      final groups = {...state.groups}..remove(group.id);
      state = ChatStoreState(entries: state.entries, devices: state.devices, groups: groups, persistenceError: state.persistenceError);
      await _save();
      throw StateError('Group could not be saved');
    }
  }

  Future<bool> updateGroup(ChatGroup expected, ChatGroup next) async {
    if (_blocked || !identical(state.groups[expected.id], expected) || !_updatingGroups.add(expected.id)) return false;
    try {
      state = ChatStoreState(entries: state.entries, devices: state.devices, groups: {...state.groups, next.id: next});
      await _save();
      if (state.persistenceError == null) return true;
      if (identical(state.groups[next.id], next)) {
        state = ChatStoreState(
          entries: state.entries,
          devices: state.devices,
          groups: {...state.groups, expected.id: expected},
          persistenceError: state.persistenceError,
        );
        await _save();
      }
      return false;
    } finally {
      _updatingGroups.remove(expected.id);
    }
  }

  Future<void> leaveGroup(String id) {
    final groups = {...state.groups}..remove(id);
    state = ChatStoreState(entries: state.entries, devices: state.devices, groups: groups, persistenceError: state.persistenceError);
    return _save();
  }

  /// Explicit destructive recovery; callers must obtain the user's confirmation.
  Future<void> resetCorruptStore() {
    if (!_blocked) return Future.value();
    _blocked = false;
    state = ChatStoreState();
    return _save();
  }

  /// Also retries a failed write and persists restart normalization.
  Future<void> flush() => _save();

  Future<void> _save() {
    if (_blocked) return _pending;
    final snapshot = jsonEncode({
      'version': 1,
      'entries': state.entries.map((e) => e.toJson()).toList(),
      'devices': state.devices.values.map((e) => e.toJson()).toList(),
      if (state.groups.isNotEmpty) 'groups': state.groups.values.map((group) => group.toJson()).toList(),
    });
    _pending = _pending.then((_) async {
      try {
        await _write(snapshot);
        if (state.persistenceError != null) state = ChatStoreState(entries: state.entries, devices: state.devices, groups: state.groups);
      } catch (_) {
        state = ChatStoreState(
          entries: state.entries,
          devices: state.devices,
          groups: state.groups,
          persistenceError: 'Chat history could not be saved. Retry saving.',
        );
      }
    });
    return _pending;
  }
}
