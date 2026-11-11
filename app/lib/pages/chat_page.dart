import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' as picker;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/chat_store_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/chat_transfer_adapter.dart';
import 'package:localsend_app/util/chat_updater.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

enum _AttachmentAction { forward, open, saveAs, showInFolder }

const _chatGreen = Color(0xff07a562);
const _groupPrefix = 'group:';

bool _supportsGroups(Device device) => device.https && (device.deviceModel?.endsWith(chatGroupDeviceMarker) ?? false);
String _conversationId(ChatEntry entry) => entry.groupId == null ? entry.peerFingerprint : '$_groupPrefix${entry.groupId}';

/// Desktop workspace. Selection remains shared with native share/open callbacks.
class ChatPage extends StatefulWidget {
  final VoidCallback onSettings;
  const ChatPage({required this.onSettings, super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with Refena {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _search = TextEditingController();
  final _historySearch = TextEditingController();
  final _historySearchFocus = FocusNode();
  final _nameController = TextEditingController();
  bool _editingName = false;
  bool _savingName = false;
  String? _nameError;
  final _updater = ChatUpdater();
  Timer? _updateTimer;
  ChatUpdate? _availableUpdate;
  bool _checkingUpdate = false;
  bool _updating = false;
  double _updateProgress = 0;
  bool _historySearchOpen = false;
  bool _historyFilesOnly = false;
  String? _selected;
  bool _devicesOnly = false;
  bool _busy = false;
  bool _sending = false;
  String? _activeGroupMessageId;
  final _drafts = <String, (TextEditingValue, List<CrossFile>, ChatReply?, Map<String, String>)>{};
  ChatReply? _reply;
  Map<String, String> _draftMentions = {};
  bool _pickingMention = false;
  Timer? _groupSyncTimer;
  bool _syncingGroups = false;
  final _groupSync = <(String, String), ({int revision, DateTime? retryAfter})>{};
  final _offeredInvitations = <(String, String)>{};
  final _openedAt = DateTime.now();
  final _readThrough = <String, DateTime>{};

  void _selectPeer(String? next) {
    if (_busy || next == _selected) return;
    final current = _selected;
    if (current != null) _drafts[current] = (_composer.value, ref.read(selectedSendingFilesProvider), _reply, _draftMentions);
    final now = DateTime.now();
    if (current != null) _readThrough[current] = now;
    if (next != null) _readThrough[next] = now;
    final (text, files, reply, mentions) = _drafts.remove(next) ?? (TextEditingValue.empty, <CrossFile>[], null, <String, String>{});
    if (current != null || files.isNotEmpty) {
      final unassigned = current == null ? ref.read(selectedSendingFilesProvider) : const <CrossFile>[];
      ref.redux(selectedSendingFilesProvider).dispatch(ReplaceSelectedFilesAction([...files, ...unassigned]));
    }
    setState(() {
      _selected = next;
      _reply = reply;
      _draftMentions = mentions;
      _historySearchOpen = false;
      _historyFilesOnly = false;
      _historySearch.clear();
    });
    _composer.value = text;
    if (next != null) _composerFocus.requestFocus();
  }

  bool _deciding = false;
  bool _dragging = false;
  String s(String en, String zh) => Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    _groupSyncTimer = Timer.periodic(const Duration(seconds: 12), (_) => unawaited(_syncGroups()));
    if (kReleaseMode && Platform.isWindows) {
      _updateTimer = Timer(const Duration(seconds: 5), () {
        unawaited(_checkUpdates());
        _updateTimer = Timer.periodic(const Duration(hours: 6), (_) => unawaited(_checkUpdates()));
      });
    }
  }

  @override
  void dispose() {
    _groupSyncTimer?.cancel();
    _updateTimer?.cancel();
    _composer.dispose();
    _composerFocus.dispose();
    _search.dispose();
    _historySearch.dispose();
    _historySearchFocus.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _checkUpdates({bool manual = false}) async {
    if (_checkingUpdate || _updating || !Platform.isWindows) return;
    setState(() => _checkingUpdate = true);
    try {
      final update = await _updater.check();
      if (!mounted) return;
      setState(() => _availableUpdate = update);
      if (manual && update == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s('Chat $chatVersion is up to date.', '聊天版 $chatVersion 已是最新版本。'))));
      }
    } catch (error) {
      if (manual) _error(s('Could not check for updates. Try again later. ($error)', '暂时无法检查更新，请稍后重试。($error)'));
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  bool _canRestartForUpdate() {
    bool active(SessionStatus? status) => status == SessionStatus.waiting || status == SessionStatus.sending;
    final server = ref.read(serverProvider);
    return !_sending &&
        !_editingName &&
        !_savingName &&
        !_syncingGroups &&
        server?.web == null &&
        !active(server?.session?.status) &&
        !ref.read(sendProvider).values.any((session) => active(session.status)) &&
        !ref.read(chatStoreProvider).entries.any((entry) => entry.status.isActive) &&
        _composer.text.isEmpty &&
        ref.read(selectedSendingFilesProvider).isEmpty &&
        _drafts.values.every((draft) => draft.$1.text.isEmpty && draft.$2.isEmpty);
  }

  Future<void> _installUpdate() async {
    final update = _availableUpdate;
    if (update == null || _busy || _updating) return;
    if (!_canRestartForUpdate() || _editingName) {
      _error(s('Finish transfers and send or clear drafts before updating.', '请先完成传输、保存名称，并发送或清空草稿，再更新。'));
      return;
    }
    setState(() {
      _busy = true;
      _updating = true;
      _updateProgress = 0;
    });
    try {
      final prepared = await _updater.prepare(update, (progress) {
        if (mounted) setState(() => _updateProgress = progress);
      });
      if (!mounted || !_canRestartForUpdate()) {
        await prepared.directory.delete(recursive: true);
        if (mounted) _error(s('A transfer or draft is active. Please update later.', '有新的传输或草稿，请稍后更新。'));
        return;
      }
      await prepared.launch();
      if (!mounted || !_canRestartForUpdate()) {
        await prepared.cancel();
        throw StateError(s('A transfer started; update postponed.', '有新传输开始，更新已推迟。'));
      }
      exit(0);
    } catch (error) {
      if (mounted) _error(s('Update failed; the app remains open. ($error)', '更新未完成，应用保持打开。($error)'));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _updating = false;
        });
      }
    }
  }

  void _editName() {
    if (_savingName) return;
    final alias = ref.read(settingsProvider).alias;
    _nameController.value = TextEditingValue(
      text: alias,
      selection: TextSelection(baseOffset: 0, extentOffset: alias.length),
    );
    setState(() {
      _editingName = true;
      _nameError = null;
    });
  }

  Future<void> _saveName() async {
    if (!_editingName || _savingName) return;
    final alias = _nameController.text.trim();
    if (alias.isEmpty) {
      setState(() => _nameError = s('Name cannot be empty', '名称不能为空'));
      return;
    }
    setState(() => _savingName = true);
    try {
      if (alias != ref.read(settingsProvider).alias) {
        await ref.notifier(settingsProvider).setAlias(alias);
        if (mounted && ref.read(serverProvider) != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s('Name saved. Restart the app to update your LAN name.', '名称已保存，重启应用后局域网名称生效。'))),
          );
        }
      }
      if (mounted) setState(() => _editingName = false);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Widget _ownName(String alias) {
    if (_editingName) {
      return Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && !_savingName) {
            setState(() => _editingName = false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          key: const ValueKey('own-name-input'),
          controller: _nameController,
          autofocus: true,
          readOnly: _savingName,
          style: Theme.of(context).textTheme.bodySmall,
          decoration: InputDecoration(
            isDense: true,
            hintText: s('Device name', '设备名称'),
            errorText: _nameError,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          onSubmitted: (_) => _saveName(),
          onTapOutside: (_) => _saveName(),
        ),
      );
    }
    return Tooltip(
      message: s('Double-click to rename this device', '双击修改本机名称'),
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
          key: const ValueKey('own-name'),
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _editName,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(alias, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      ),
    );
  }

  void _openHistorySearch() {
    if (_selected == null) return;
    setState(() => _historySearchOpen = true);
    _historySearchFocus.requestFocus();
  }

  void _closeHistorySearch() {
    setState(() {
      _historySearchOpen = false;
      _historyFilesOnly = false;
      _historySearch.clear();
    });
    _composerFocus.requestFocus();
  }

  Widget _historySearchBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('history-search-input'),
            controller: _historySearch,
            focusNode: _historySearchFocus,
            decoration: _inputDecoration(s('Message or file name', '消息内容或文件名')).copyWith(
              prefixIcon: const Icon(Icons.search, size: 19),
              suffixIcon: _historySearch.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: s('Clear keyword', '清空关键词'),
                      onPressed: () => setState(_historySearch.clear),
                      icon: const Icon(Icons.backspace_outlined, size: 18),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        FilterChip(
          label: Text(s('Files only', '只看文件')),
          selected: _historyFilesOnly,
          onSelected: (selected) => setState(() => _historyFilesOnly = selected),
        ),
        IconButton(
          tooltip: s('Close history search', '关闭聊天记录搜索'),
          onPressed: _closeHistorySearch,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );

  bool _matchesHistory(ChatEntry entry, String query) =>
      (!_historyFilesOnly || entry.attachments.isNotEmpty) &&
      (query.isEmpty ||
          (entry.text?.toLowerCase().contains(query) ?? false) ||
          entry.attachments.any((file) => file.name.toLowerCase().contains(query)));

  void _error(Object error) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s('Cancel', '取消'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s('Confirm', '确认'))),
          ],
        ),
      ) ??
      false;

  Future<void> _stage(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  CrossFile _textFile(String text) {
    final bytes = utf8.encode(text);
    if (bytes.length > 65536) {
      throw FormatException(s('Text is limited to 64 KiB. Attach a text file for longer content.', '文字上限为 64 KiB，更长内容请作为文件发送。'));
    }
    return CrossFile(
      name: 'message.txt',
      fileType: FileType.text,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );
  }

  Future<void> _send({ChatEntry? retry, ({String peer, ChatAttachment attachment})? forward}) async {
    if (_busy || _sending) return;
    final fingerprint = forward?.peer ?? retry?.peerFingerprint ?? _selected;
    final group = _groupFor(fingerprint, ref.read(chatStoreProvider));
    if (group != null) {
      await _sendGroup(group, forwarded: forward?.attachment);
      return;
    }
    final target = ref.read(nearbyDevicesProvider).devices[fingerprint];
    if (target == null) {
      _error(s('Device unavailable. Refresh discovery and try again.', '设备不可用，请刷新发现后重试。'));
      return;
    }
    final draft = _composer.text;
    final staged = List<CrossFile>.of(ref.read(selectedSendingFilesProvider));
    final isDraft = retry == null && forward == null;
    final text = isDraft ? draft : (retry == null || retry.textDelivered ? '' : retry.text ?? '');
    final reply = isDraft ? _reply : retry?.reply;
    final structuredReply = reply != null && target.https && supportsAdvancedChat(target.deviceModel);
    var preparing = true;
    setState(() => _busy = true);
    try {
      final files = <CrossFile>[
        if (structuredReply)
          _chatPacketFile(ChatGroupPacket(groupId: '', messageId: const Uuid().v4(), text: text.trim().isEmpty ? null : text, reply: reply))
        else if (text.trim().isNotEmpty || reply != null)
          _textFile(reply == null ? text : '> ${reply.author}\n> ${reply.excerpt}\n\n$text'),
      ];
      if (isDraft) {
        files.addAll(staged);
      } else {
        final attachments = forward == null ? retry!.attachments.where((a) => a.status != ChatAttachmentStatus.transferred) : [forward.attachment];
        for (final attachment in attachments) {
          final path = attachment.path;
          if (path == null || !await File(path).exists()) {
            throw FileSystemException(s('Source file is missing. Choose it again.', '源文件丢失，请重新选择。'), path);
          }
          final file = await CrossFileConverters.convertFile(File(path));
          files.add(file.copyWith(name: forward == null ? attachment.name : p.posix.basename(attachment.name.replaceAll('\\', '/'))));
        }
      }
      if (files.isEmpty) return;
      for (final file in files) {
        if (file.path != null) {
          final handle = await File(file.path!).open();
          await handle.close();
        }
      }
      if (!mounted) return;
      final transfer = ref.notifier(sendProvider).startSession(target: target, files: files, background: true);
      if (isDraft) {
        if (_composer.text == draft) _composer.clear();
        _reply = null;
        final current = ref.read(selectedSendingFilesProvider);
        ref.redux(selectedSendingFilesProvider).dispatch(ReplaceSelectedFilesAction(current.where((file) => !staged.contains(file)).toList()));
      }
      setState(() {
        _busy = false;
        _sending = true;
      });
      preparing = false;
      await transfer;
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) {
        setState(() {
          if (preparing) _busy = false;
          _sending = false;
        });
      }
    }
  }

  ChatGroup? _groupFor(String? conversation, ChatStoreState store) {
    if (conversation == null || !conversation.startsWith(_groupPrefix)) return null;
    final group = store.groups[conversation.substring(_groupPrefix.length)];
    return group?.members.containsKey(ref.read(securityProvider).certificateHash) == true ? group : null;
  }

  String _deviceName(Device device, ChatStoreState store) => store.preferencesFor(device.fingerprint).alias ?? device.alias;

  Future<void> _createGroup() async {
    if (_busy || _sending) return;
    if (!ref.read(settingsProvider).https) {
      _error(s('Turn on encrypted transfer to create a group.', '请先开启加密传输，再创建群聊。'));
      return;
    }
    final store = ref.read(chatStoreProvider);
    final candidates = ref.read(nearbyDevicesProvider).devices.values.where(_supportsGroups).toList()
      ..sort((a, b) => _deviceName(a, store).compareTo(_deviceName(b, store)));
    if (candidates.length < 2) {
      _error(s('A group needs two other online devices running the group-chat version.', '建群需要至少两台已更新到群聊版的在线设备。'));
      return;
    }
    final selected = <Device>{};
    var name = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(s('New group', '新建群聊')),
          content: SizedBox(
            width: 420,
            height: MediaQuery.sizeOf(context).height * .46,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: s('Group name', '群聊名称')),
                  onChanged: (value) => update(() => name = value.trim()),
                ),
                Text(s('Group messages and files from members are accepted automatically.', '群成员发来的群消息和文件会自动接收。')),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final device in candidates)
                        CheckboxListTile(
                          value: selected.contains(device),
                          title: Text(_deviceName(device, store)),
                          onChanged: selected.length >= 31 && !selected.contains(device)
                              ? null
                              : (checked) => update(() {
                                  if (checked == true) {
                                    selected.add(device);
                                  } else {
                                    selected.remove(device);
                                  }
                                }),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Cancel', '取消'))),
            FilledButton(
              onPressed: name.isEmpty || selected.length < 2 ? null : () => Navigator.pop(context, true),
              child: Text(s('Create and invite', '创建并邀请')),
            ),
          ],
        ),
      ),
    );
    if (!mounted || confirmed != true || _busy || _sending) return;
    final own = ref.read(securityProvider).certificateHash;
    String memberName(String label) {
      final value = label.trim();
      return value.isEmpty ? s('Device', '设备') : String.fromCharCodes(value.runes.take(80));
    }

    final group = ChatGroup(
      id: const Uuid().v4(),
      name: name,
      owner: own,
      members: {
        own: memberName(ref.read(settingsProvider).alias),
        for (final device in selected) device.fingerprint: memberName(_deviceName(device, store)),
      },
    );
    try {
      await ref.notifier(chatStoreProvider).addGroup(group);
      if (!mounted) return;
      _selectPeer(group.conversationId);
      await _sendGroup(group, invite: true);
    } catch (e) {
      _error(e);
    }
  }

  bool _canSendToGroupDevice(ChatGroup group, Device device) =>
      _supportsGroups(device) && (group.revision == 0 || supportsAdvancedChat(device.deviceModel));

  CrossFile _chatPacketFile(ChatGroupPacket packet) {
    final file = _textFile(packet.encode());
    if (file.size > chatGroupPacketLimit) {
      throw FormatException(s('The message is too long.', '消息太长，请分段发送。'));
    }
    return file.copyWith(name: packet.isDirectReply ? chatReplyCarrierName : chatGroupCarrierName);
  }

  Future<void> _syncGroups({ChatGroup? only, bool interactive = false}) async {
    if (_syncingGroups || _updating || !mounted || !ref.read(settingsProvider).https) return;
    final own = ref.read(securityProvider).certificateHash;
    final groups = ref
        .read(chatStoreProvider)
        .groups
        .values
        .where((group) => group.owner == own && group.revision > 0 && (only == null || only.id == group.id))
        .toList();
    if (groups.isEmpty) return;
    _syncingGroups = true;
    final devices = ref.read(nearbyDevicesProvider).devices;
    final sender = ref.notifier(sendProvider);
    try {
      for (final group in groups) {
        for (final member in {...group.members.keys, ...group.removed}) {
          if (!mounted || ref.read(chatStoreProvider).groups[group.id]?.revision != group.revision) break;
          final device = devices[member];
          if (member == own || device == null || !_canSendToGroupDevice(group, device)) continue;
          final key = (group.id, member);
          final attempt = _groupSync[key];
          final now = DateTime.now();
          if (attempt != null &&
              attempt.revision == group.revision &&
              (attempt.retryAfter == null || (!interactive && attempt.retryAfter!.isAfter(now)))) {
            continue;
          }
          final response = await sender.sendGroupControl(
            device,
            ChatGroupPacket(
              groupId: group.id,
              messageId: const Uuid().v4(),
              snapshot: group,
            ),
            interactive: interactive,
          );
          if (response == 204) {
            _groupSync[key] = (revision: group.revision, retryAfter: null);
          } else {
            _groupSync[key] = (revision: group.revision, retryAfter: now.add(const Duration(seconds: 35)));
            if (response == 403 && group.added.contains(member) && (interactive || _offeredInvitations.add(key))) {
              final invitation = sender
                  .sendGroupControl(
                    device,
                    ChatGroupPacket(
                      groupId: group.id,
                      messageId: const Uuid().v4(),
                      invitation: group,
                    ),
                    interactive: interactive,
                  )
                  .then((status) {
                    if (status == 204 && _groupSync[key]?.revision == group.revision) {
                      _groupSync[key] = (revision: group.revision, retryAfter: null);
                    }
                  });
              if (interactive) {
                await invitation;
              } else {
                unawaited(invitation);
              }
            }
          }
        }
      }
    } finally {
      _syncingGroups = false;
    }
  }

  Future<void> _changeGroup(ChatGroup group, ChatGroupAction action, {String? target, String? value}) async {
    if (_busy || _sending) return;
    final change = ChatGroupChange(action, group.revision, target: target, value: value);
    final own = ref.read(securityProvider).certificateHash;
    final update = group.apply(change, own);
    if (update == null) {
      _error(s('This group change could not be applied. Reopen group details and try again.', '无法修改群设置，请重新打开群详情后再试。'));
      return;
    }
    setState(() => _busy = true);
    try {
      if (own == group.owner) {
        if (!await ref.notifier(chatStoreProvider).updateGroup(group, update)) {
          _error(s('The group changed or could not be saved. Try again.', '群设置已变化或保存失败，请重试。'));
          return;
        }
        if (action == ChatGroupAction.add) _offeredInvitations.remove((group.id, target!));
        unawaited(_syncGroups(only: update));
      } else {
        final owner = ref.read(nearbyDevicesProvider).devices[group.owner];
        if (owner == null || !_canSendToGroupDevice(group, owner) || !supportsAdvancedChat(owner.deviceModel)) {
          _error(s('The group owner must be online and updated.', '请等群主上线并更新到新版后再操作。'));
          return;
        }
        final status = await ref
            .notifier(sendProvider)
            .sendGroupControl(
              owner,
              ChatGroupPacket(groupId: group.id, messageId: const Uuid().v4(), change: change),
              interactive: true,
            );
        if (status != 204) {
          _error(s('The owner did not accept the change. Refresh group details and try again.', '群主设备未接受修改，请刷新群详情后重试。'));
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s('Saved by the owner. Waiting for group sync.', '群主设备已保存，等待群设置同步。'))));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAnnouncement(ChatGroup group) async {
    final field = TextEditingController(text: group.announcement);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s('Group announcement', '群公告')),
        content: TextField(controller: field, autofocus: true, minLines: 3, maxLines: 6, maxLength: 2000),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Cancel', '取消'))),
          FilledButton(onPressed: () => Navigator.pop(context, field.text), child: Text(s('Save announcement', '保存公告'))),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose());
    if (mounted && value != null && value.trim() != group.announcement) await _changeGroup(group, ChatGroupAction.announce, value: value);
  }

  Future<void> _readAnnouncement(ChatGroup group) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s('Group announcement', '群公告')),
      content: SingleChildScrollView(child: SelectableText(group.announcement.isEmpty ? s('No announcement', '暂无公告') : group.announcement)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Close', '关闭')))],
    ),
  );

  Future<void> _addGroupMember(ChatGroup group) async {
    final candidates = ref
        .read(nearbyDevicesProvider)
        .devices
        .values
        .where((device) => !group.members.containsKey(device.fingerprint) && device.https && supportsAdvancedChat(device.deviceModel))
        .toList();
    if (candidates.isEmpty) {
      _error(s('No nearby devices running the new version.', '附近没有可添加的新版设备。'));
      return;
    }
    final device = await showDialog<Device>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(s('Add group member', '添加群成员')),
        children: [
          for (final device in candidates) SimpleDialogOption(onPressed: () => Navigator.pop(context, device), child: Text(device.alias)),
        ],
      ),
    );
    if (mounted && device != null) await _changeGroup(group, ChatGroupAction.add, target: device.fingerprint, value: device.alias);
  }

  Future<void> _toggleMuted(String conversation) async {
    final preferences = ref.read(chatStoreProvider).preferencesFor(conversation);
    await ref.notifier(chatStoreProvider).setDevice(preferences.copyWith(muted: !preferences.muted));
  }

  void _quote(ChatEntry entry, String author) {
    final excerpt = entry.text?.trim().isNotEmpty == true ? entry.text! : entry.attachments.map((file) => file.name).join(', ');
    if (excerpt.trim().isEmpty) return;
    setState(() => _reply = ChatReply(author: _truncate(author, 160), excerpt: _truncate(excerpt, 500)));
    _composerFocus.requestFocus();
  }

  String _truncate(String text, int maximum) {
    if (text.length <= maximum) return text;
    // Avoid cutting a UTF-16 surrogate pair in the middle.
    final end = text.codeUnitAt(maximum - 1) >= 0xd800 && text.codeUnitAt(maximum - 1) <= 0xdbff ? maximum - 1 : maximum;
    return text.substring(0, end);
  }

  Future<void> _pickMention(ChatGroup group, {bool replaceAt = false}) async {
    if (_pickingMention || _busy || _sending) return;
    final own = ref.read(securityProvider).certificateHash;
    final before = _composer.value;
    _pickingMention = true;
    try {
      final member = await showDialog<MapEntry<String, String>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(s('Mention a member', '@群成员')),
          children: [
            for (final member in group.members.entries)
              if (member.key != own) SimpleDialogOption(onPressed: () => Navigator.pop(context, member), child: Text(member.value)),
          ],
        ),
      );
      if (!mounted || member == null || _selected != group.conversationId || _composer.value != before) return;
      final offset = before.selection.isValid ? before.selection.start : before.text.length;
      final start = replaceAt ? offset - 1 : offset;
      final label = '@${member.value}';
      final next = before.text.replaceRange(start, before.selection.isValid ? before.selection.end : offset, '$label ');
      _draftMentions[member.key] = label;
      _composer.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + label.length + 1),
      );
    } finally {
      _pickingMention = false;
      if (mounted && _selected == group.conversationId) _composerFocus.requestFocus();
    }
  }

  Future<void> _groupDetails(ChatGroup group) async {
    final own = ref.read(securityProvider).certificateHash;
    final nearby = ref.read(nearbyDevicesProvider).devices;
    final muted = ref.read(chatStoreProvider).preferencesFor(group.conversationId).muted;
    final canManage = group.canManage(own);
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(group.name),
        content: SizedBox(
          width: 380,
          height: MediaQuery.sizeOf(context).height * .42,
          child: ListView(
            shrinkWrap: true,
            children: [
              SwitchListTile(
                value: muted,
                secondary: const Icon(Icons.notifications_off_outlined),
                title: Text(s('Mute notifications', '消息免打扰')),
                onChanged: (_) => Navigator.pop(context, 'mute'),
              ),
              ListTile(
                leading: const Icon(Icons.campaign_outlined),
                title: Text(s('Group announcement', '群公告')),
                subtitle: Text(
                  group.announcement.isEmpty ? s('No announcement', '暂无公告') : group.announcement,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, canManage ? 'announce' : 'read-announcement'),
              ),
              if (canManage)
                ListTile(
                  leading: const Icon(Icons.person_add_outlined),
                  title: Text(s('Add group member', '添加群成员')),
                  onTap: () => Navigator.pop(context, 'add'),
                ),
              if (own == group.owner && group.revision > 0)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: Text(s('Sync group settings', '同步群设置')),
                  onTap: () => Navigator.pop(context, 'sync'),
                ),
              for (final member in group.members.entries)
                ListTile(
                  leading: _peerAvatar(member.value),
                  title: Text(member.value),
                  subtitle: Text(
                    [
                      if (member.key == own) s('You', '你'),
                      if (member.key == group.owner) s('Owner', '群主'),
                      if (group.admins.contains(member.key)) s('Admin', '管理员'),
                      if (member.key != own) nearby.containsKey(member.key) ? s('Nearby', '附近设备') : s('Not discovered', '未发现设备'),
                    ].join(' · '),
                  ),
                  trailing: canManage && member.key != own && member.key != group.owner && (own == group.owner || !group.admins.contains(member.key))
                      ? PopupMenuButton<ChatGroupAction>(
                          tooltip: s('Manage member', '管理成员'),
                          onSelected: (action) => Navigator.pop(context, '${action.name}:${member.key}'),
                          itemBuilder: (_) => [
                            if (own == group.owner)
                              group.admins.contains(member.key)
                                  ? PopupMenuItem(value: ChatGroupAction.demote, child: Text(s('Remove admin role', '取消管理员')))
                                  : PopupMenuItem(value: ChatGroupAction.promote, child: Text(s('Make admin', '设为管理员'))),
                            PopupMenuItem(value: ChatGroupAction.remove, child: Text(s('Remove from group', '移出群聊'))),
                          ],
                        )
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Close', '关闭'))),
          TextButton(onPressed: () => Navigator.pop(context, 'leave'), child: Text(s('Leave group', '退出群聊'))),
          if (group.owner == own) FilledButton(onPressed: () => Navigator.pop(context, 'invite'), child: Text(s('Resend invitations', '重新发送邀请'))),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'invite') await _sendGroup(group, invite: true);
    if (action == 'mute') await _toggleMuted(group.conversationId);
    if (action == 'announce') await _editAnnouncement(group);
    if (action == 'read-announcement') await _readAnnouncement(group);
    if (action == 'add') await _addGroupMember(group);
    if (action == 'sync') await _syncGroups(only: group, interactive: true);
    if (action != null && action.contains(':')) {
      final [operation, target] = action.split(':');
      final kind = ChatGroupAction.values.byName(operation);
      if (kind != ChatGroupAction.remove || await _confirm(s('Remove this member?', '移出这位成员？'), group.members[target] ?? target)) {
        if (mounted) await _changeGroup(group, kind, target: target);
      }
    }
    if (action == 'leave' &&
        await _confirm(
          s('Leave this group?', '退出这个群聊？'),
          s('This device will stop receiving new messages and files from the group.', '退出后，这台设备将停止接收该群的新消息和文件。'),
        )) {
      if (!mounted || _busy || _sending) return;
      await ref.notifier(chatStoreProvider).leaveGroup(group.id);
      if (mounted && _selected == group.conversationId) _selectPeer(null);
    }
  }

  Future<void> _sendGroup(ChatGroup group, {bool invite = false, ChatAttachment? forwarded}) async {
    if (_busy || _sending) return;
    final settings = ref.read(settingsProvider);
    final own = ref.read(securityProvider).certificateHash;
    if (!settings.https || !group.members.containsKey(own) || (invite && group.owner != own)) {
      _error(s('Encrypted group transfer is unavailable.', '当前无法进行加密群聊传输。'));
      return;
    }
    final usesDraft = !invite && forwarded == null;
    final draft = usesDraft ? _composer.text : '';
    final staged = usesDraft ? List<CrossFile>.of(ref.read(selectedSendingFilesProvider)) : <CrossFile>[];
    if (usesDraft && draft.trim().isEmpty && staged.isEmpty) return;
    final messageId = const Uuid().v4();
    final reply = usesDraft ? _reply : null;
    final mentions = usesDraft
        ? _draftMentions.entries
              .where((member) => group.members.containsKey(member.key) && draft.contains(member.value))
              .map((member) => member.key)
              .toList()
        : <String>[];
    ChatGroupPacket packetFor(bool advanced) => ChatGroupPacket(
      groupId: group.id,
      messageId: messageId,
      invitation: invite ? group : null,
      text: draft.trim().isEmpty ? null : draft,
      reply: advanced ? reply : null,
      mentions: advanced ? mentions : const [],
      revision: invite ? 0 : group.revision,
      deduplicate: advanced && !invite,
    );
    final packet = packetFor(true);
    setState(() => _busy = true);
    try {
      if (forwarded != null) {
        final path = forwarded.path!;
        if (!await File(path).exists()) throw FileSystemException(s('Source file is missing.', '原文件已丢失。'), path);
        final file = await CrossFileConverters.convertFile(File(path));
        staged.add(file.copyWith(name: p.posix.basename(forwarded.name.replaceAll('\\', '/'))));
      }
      for (final file in staged) {
        if (file.path != null) {
          final handle = await File(file.path!).open();
          await handle.close();
        }
      }
      final advancedCarrier = _chatPacketFile(packet);
      final legacyCarrier = group.revision == 0 ? _chatPacketFile(packetFor(false)) : null;
      if (!mounted) return;
      if (usesDraft) {
        if (_composer.text == draft) _composer.clear();
        _reply = null;
        _draftMentions = {};
        final current = ref.read(selectedSendingFilesProvider);
        ref.redux(selectedSendingFilesProvider).dispatch(ReplaceSelectedFilesAction(current.where((file) => !staged.contains(file)).toList()));
      }
      final devices = ref.read(nearbyDevicesProvider).devices;
      final store = ref.notifier(chatStoreProvider);
      final sender = ref.notifier(sendProvider);
      final unavailable = s('Offline or group chat unsupported', '离线或未升级到群聊版');
      setState(() {
        _busy = false;
        _sending = true;
        _activeGroupMessageId = packet.messageId;
      });
      Future<void> deliver(MapEntry<String, String> member) async {
        if (!mounted) return;
        final current = ref.read(chatStoreProvider).groups[group.id];
        if (current == null || !current.members.containsKey(own) || !current.members.containsKey(member.key)) return;
        final device = devices[member.key];
        String? error;
        if (device != null && _canSendToGroupDevice(group, device)) {
          try {
            final carrier = supportsAdvancedChat(device.deviceModel) ? advancedCarrier : legacyCarrier!;
            await sender.startSession(target: device, files: [carrier, ...staged], background: true);
            return;
          } catch (e) {
            error = e.toString();
          }
        }
        await store.upsertEntry(
          ChatEntry(
            id: 'out:${const Uuid().v4()}',
            peerFingerprint: member.key,
            peerAlias: member.value,
            outgoing: true,
            createdAt: DateTime.now(),
            status: ChatTransferStatus.failed,
            text: packet.text,
            groupId: packet.groupId,
            groupMessageId: packet.messageId,
            groupInvitation: invite,
            reply: packet.reply,
            mentions: packet.mentions,
            error: error ?? unavailable,
            attachments: [
              for (final file in staged)
                ChatAttachment(
                  name: file.name,
                  size: file.size,
                  path: file.path,
                  fileType: file.fileType,
                  status: ChatAttachmentStatus.failed,
                ),
            ],
          ),
        );
      }

      final members = group.members.entries.where((member) => member.key != own).toList();
      for (var i = 0; i < members.length; i += 4) {
        await Future.wait(members.skip(i).take(4).map(deliver));
      }
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sending = false;
          _activeGroupMessageId = null;
        });
      }
    }
  }

  Future<void> _acceptChat(String sessionId, {bool trust = false}) async {
    if (_deciding) return;
    setState(() => _deciding = true);
    try {
      final session = ref.read(serverProvider)?.session;
      final invitation = session?.sessionId == sessionId ? chatGroupRequest(session!)?.invitation : null;
      await ref.notifier(serverProvider).acceptChatRequest(sessionId, trust: trust);
      if (mounted && invitation != null && ref.read(chatStoreProvider).groups.containsKey(invitation.id)) {
        setState(() => _devicesOnly = false);
        _selectPeer(invitation.conversationId);
      }
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _deciding = false);
    }
  }

  Future<void> _details(String fingerprint, String name, Device? device) async {
    final preferences = ref.read(chatStoreProvider).preferencesFor(fingerprint);
    final alias = TextEditingController(text: preferences.alias ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(name),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: alias,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: s('Local nickname', '本地备注名')),
                ),
                const SizedBox(height: 16),
                Text(s('Certificate fingerprint', '证书指纹'), style: Theme.of(context).textTheme.labelLarge),
                SelectableText(fingerprint),
                const SizedBox(height: 12),
                Text(
                  device == null
                      ? s('Not discovered', '未发现设备')
                      : '${device.deviceModel?.replaceFirst(chatAdvancedDeviceMarker, '').replaceFirst(chatGroupDeviceMarker, '') ?? ''}\n${device.ip}:${device.port}\n${device.https ? 'HTTPS' : 'HTTP (unencrypted)'}',
                ),
                const SizedBox(height: 12),
                Text(s('Verify this fingerprint on the other device before trusting it.', '信任前，请在对方设备上核对指纹。')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Cancel', '取消'))),
          FilledButton(onPressed: () => Navigator.pop(context, alias.text.trim()), child: Text(s('Save nickname', '保存备注'))),
        ],
      ),
    );
    alias.dispose();
    if (!mounted || result == null) return;
    final latest = ref.read(chatStoreProvider).preferencesFor(fingerprint);
    await ref.notifier(chatStoreProvider).setDevice(latest.copyWith(alias: result.isEmpty ? null : result));
  }

  Future<void> _configureReceiveDirectory(String fingerprint) async {
    final custom = ref.read(chatStoreProvider).preferencesFor(fingerprint).receiveDirectory;
    final defaultDirectory = ref.read(settingsProvider).destination;
    final change = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s('Save location for this chat', '此聊天的保存位置')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(custom ?? s('Using the default folder: ${defaultDirectory ?? 'Downloads'}', '使用默认文件夹：${defaultDirectory ?? '下载'}')),
            const SizedBox(height: 8),
            Text(s('Applies to future files received over HTTPS.', '适用于此设备以后通过 HTTPS 发来的文件。')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Cancel', '取消'))),
          if (custom != null) TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s('Use default folder', '使用默认文件夹'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(s('Choose folder…', '选择文件夹…'))),
        ],
      ),
    );
    if (!mounted || change == null) return;
    try {
      final directory = change ? await picker.getDirectoryPath(initialDirectory: custom ?? defaultDirectory) : null;
      if (!mounted || (change && directory == null)) return;
      final latest = ref.read(chatStoreProvider).preferencesFor(fingerprint);
      await ref.notifier(chatStoreProvider).setDevice(latest.copyWith(receiveDirectory: directory));
    } on Exception {
      _error(s('Could not change the save location.', '无法更改保存位置。'));
    }
  }

  Future<void> _forwardAttachment(ChatAttachment file) async {
    final store = ref.read(chatStoreProvider);
    final nearby = ref.read(nearbyDevicesProvider).devices;
    final recipients = {
      for (final device in nearby.values) device.fingerprint: _deviceName(device, store),
      for (final group in store.groups.values)
        if (group.members.keys.any((peer) => nearby[peer] != null && _supportsGroups(nearby[peer]!))) group.conversationId: group.name,
    }.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    if (recipients.isEmpty) {
      _error(s('No devices available to forward to.', '没有可转发的设备。'));
      return;
    }
    String? selected;
    final target = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(s('Forward file', '转发文件')),
          content: SizedBox(
            width: 380,
            height: MediaQuery.sizeOf(context).height * .42,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                Flexible(
                  child: RadioGroup<String>(
                    groupValue: selected,
                    onChanged: (value) => setDialogState(() => selected = value),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final recipient in recipients)
                          RadioListTile(
                            value: recipient.key,
                            title: Text(recipient.value),
                            secondary: recipient.key.startsWith(_groupPrefix) ? const Icon(Icons.groups_outlined) : null,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Cancel', '取消'))),
            FilledButton(onPressed: selected == null ? null : () => Navigator.pop(context, selected), child: Text(s('Forward', '转发'))),
          ],
        ),
      ),
    );
    if (mounted && target != null) await _send(forward: (peer: target, attachment: file));
  }

  List<PopupMenuEntry<_AttachmentAction>> _attachmentMenu(String path, {required bool outgoing}) => [
    PopupMenuItem(enabled: !_busy && !_sending, value: _AttachmentAction.forward, child: Text(s('Forward…', '转发…'))),
    if (!outgoing) ...[
      if (chatCanOpenFile(path)) PopupMenuItem(value: _AttachmentAction.open, child: Text(s('Open file', '打开文件'))),
      PopupMenuItem(value: _AttachmentAction.saveAs, child: Text(s('Save as…', '另存为…'))),
      PopupMenuItem(value: _AttachmentAction.showInFolder, child: Text(s('Show in folder', '在文件夹中显示'))),
    ],
  ];

  Future<void> _showAttachmentMenu(TapDownDetails details, ChatAttachment file, String path, {required bool outgoing}) async {
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(details.globalPosition);
    final action = await showMenu<_AttachmentAction>(
      context: context,
      position: RelativeRect.fromSize(position & Size.zero, overlay.size),
      items: _attachmentMenu(path, outgoing: outgoing),
    );
    if (mounted && action != null) await _runAttachmentAction(action, file, path);
  }

  Future<void> _runAttachmentAction(_AttachmentAction action, ChatAttachment file, String path) async {
    final source = File(path);
    try {
      if (!await source.exists()) {
        _error(s('File no longer exists at its saved location.', '文件已不在原保存位置。'));
        return;
      }
      if (!mounted) return;
      switch (action) {
        case _AttachmentAction.forward:
          await _forwardAttachment(file);
        case _AttachmentAction.open:
          await openFile(context, file.fileType, path);
        case _AttachmentAction.showInFolder:
          await openFolder(folderPath: p.dirname(path), fileName: p.basename(path));
        case _AttachmentAction.saveAs:
          final selection = await picker.getSaveLocation(initialDirectory: p.dirname(path), suggestedName: p.basename(path));
          if (!mounted || selection == null) return;
          final destination = selection.path;
          if (p.equals(path, destination)) return;
          if (await File(destination).exists() && await FileSystemEntity.identical(path, destination)) return;

          // Copy completely before replacing an existing file selected in the save dialog.
          final staging = await Directory(p.dirname(destination)).createTemp('.localsend-');
          try {
            final copy = await source.copy(p.join(staging.path, 'attachment'));
            await copy.rename(destination);
          } finally {
            await staging.delete(recursive: true);
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s('Copy saved.', '副本已保存。'))));
      }
    } on Exception {
      _error(
        switch (action) {
          _AttachmentAction.forward => s('Could not forward this file.', '无法转发此文件。'),
          _AttachmentAction.saveAs => s('Could not save a copy of this file.', '无法保存文件副本。'),
          _ => s('Could not open the saved file location.', '无法打开已保存的文件位置。'),
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch(chatStoreProvider);
    final nearby = context.watch(nearbyDevicesProvider).devices;
    final incoming = context.watch(serverProvider)?.session;
    final transfers = context.watch(fileTransferProvider);
    context.watch(sendProvider);
    final staged = context.watch(selectedSendingFilesProvider);
    final ownAlias = context.watch(settingsProvider).alias;
    final own = ref.read(securityProvider).certificateHash;
    final names = <String, String>{
      for (final entry in store.entries)
        if (entry.groupId == null) entry.peerFingerprint: entry.peerAlias,
      for (final device in nearby.values) device.fingerprint: device.alias,
      if (incoming != null) incoming.sender.fingerprint: incoming.senderAlias,
      for (final group in store.groups.values)
        if (group.members.containsKey(own)) group.conversationId: group.name,
    };
    for (final preference in store.devices.values) {
      if (preference.fingerprint.startsWith(_groupPrefix)) continue;
      names.putIfAbsent(preference.fingerprint, () => s('Saved device', '已保存设备'));
      if (preference.alias != null) names[preference.fingerprint] = preference.alias!;
    }
    final latest = <String, ChatEntry>{for (final entry in store.entries) _conversationId(entry): entry};
    final unread = <String, int>{
      if (incoming?.status == SessionStatus.waiting && incoming?.sender.fingerprint != _selected) incoming!.sender.fingerprint: 1,
    };
    final mentioned = <String>{};
    for (final entry in store.entries) {
      final peer = _conversationId(entry);
      if (!entry.outgoing && !entry.status.isActive && peer != _selected && entry.createdAt.isAfter(_readThrough[peer] ?? _openedAt)) {
        unread.update(peer, (count) => count + 1, ifAbsent: () => 1);
        if (entry.mentions.contains(own)) mentioned.add(peer);
      }
    }
    final wideWindow = MediaQuery.sizeOf(context).width >= 760;
    final query = _search.text.trim().toLowerCase();
    final peers =
        names.keys.where((id) => (!wideWindow || !_devicesOnly || nearby.containsKey(id)) && names[id]!.toLowerCase().contains(query)).toList()
          ..sort((a, b) {
            final pinned = (store.preferencesFor(b).pinned ? 1 : 0).compareTo(store.preferencesFor(a).pinned ? 1 : 0);
            if (pinned != 0) return pinned;
            final recent = (latest[b]?.createdAt.millisecondsSinceEpoch ?? 0).compareTo(latest[a]?.createdAt.millisecondsSinceEpoch ?? 0);
            return recent != 0 ? recent : names[a]!.toLowerCase().compareTo(names[b]!.toLowerCase());
          });
    final colors = Theme.of(context).colorScheme;
    final selectedGroup = _groupFor(_selected, store);
    final selected = _selected?.startsWith(_groupPrefix) == true && selectedGroup == null ? null : _selected;
    final groupAvailable =
        selectedGroup != null &&
        selectedGroup.members.keys.any((peer) => peer != own && nearby[peer] != null && _canSendToGroupDevice(selectedGroup, nearby[peer]!));
    final invitation = incoming == null ? null : chatGroupRequest(incoming)?.invitation;
    final incomingText = incoming == null ? null : chatRequestText(incoming);
    final incomingCount = incoming == null ? 0 : chatFilesToAccept(incoming).length;
    final workspace = Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (!wideWindow && selected == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(14)),
                      child: Icon(Icons.forum_outlined, color: colors.onPrimaryContainer),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s('LocalSend Chat', 'LocalSend 聊天'),
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          _ownName(ownAlias),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: s('Refresh discovery', '刷新设备发现'),
                      onPressed: () => ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan()),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(tooltip: s('Settings', '设置'), onPressed: widget.onSettings, icon: const Icon(Icons.settings_outlined)),
                  ],
                ),
              ),
            if (!wideWindow && selected == null) const Divider(height: 1),
            if (store.persistenceError != null)
              Material(
                color: colors.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(store.persistenceError!, style: TextStyle(color: colors.onErrorContainer)),
                      ),
                      if (!ref.notifier(chatStoreProvider).requiresReset)
                        TextButton(
                          onPressed: () => ref.notifier(chatStoreProvider).flush(),
                          child: Text(s('Retry saving', '重试保存')),
                        ),
                      if (ref.notifier(chatStoreProvider).requiresReset)
                        TextButton(
                          onPressed: () async {
                            if (await _confirm(
                              s('Reset local history?', '重置本地历史？'),
                              s('This clears chat metadata and device preferences. Transferred files are not deleted.', '这将清除聊天记录和设备偏好，不会删除传输的文件。'),
                            )) {
                              await ref.notifier(chatStoreProvider).resetCorruptStore();
                            }
                          },
                          child: Text(s('Reset', '重置')),
                        ),
                    ],
                  ),
                ),
              ),
            if (_availableUpdate != null)
              MaterialBanner(
                content: Text(
                  _updating
                      ? s('Downloading update… ${(_updateProgress * 100).round()}%', '正在下载更新… ${(_updateProgress * 100).round()}%')
                      : s(
                          'Chat ${_availableUpdate!.version} is available. Updating will restart the app.',
                          '聊天版 ${_availableUpdate!.version} 可更新，更新后会自动重启。',
                        ),
                ),
                actions: [
                  TextButton(onPressed: _updating ? null : () => setState(() => _availableUpdate = null), child: Text(s('Later', '稍后'))),
                  FilledButton(onPressed: _updating || _busy ? null : _installUpdate, child: Text(s('Update now', '立即更新'))),
                ],
              ),
            if (incoming != null && incoming.status == SessionStatus.waiting && incoming.sender.fingerprint != selected)
              Material(
                color: colors.secondaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.download),
                  title: Text(
                    invitation == null
                        ? s('Incoming request from ${incoming.senderAlias}', '来自 ${incoming.senderAlias} 的传输请求')
                        : s('${incoming.senderAlias} invites you to ${invitation.name}', '${incoming.senderAlias} 邀请你加入「${invitation.name}」'),
                  ),
                  trailing: TextButton(onPressed: () => _selectPeer(incoming.sender.fingerprint), child: Text(s('Review', '查看'))),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  final list = Material(
                    color: colors.surfaceContainerLow,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (wide)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 12, 0),
                            child: Text(
                              _devicesOnly ? s('Nearby devices', '附近设备') : s('Chats', '聊天'),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        if (wide)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _ownName(ownAlias),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('chat-search'),
                                  controller: _search,
                                  onChanged: (_) => setState(() {}),
                                  decoration: _inputDecoration(s('Search chats', '搜索聊天')).copyWith(
                                    prefixIcon: const Icon(Icons.search, size: 20),
                                    suffixIcon: query.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: s('Clear search', '清空搜索'),
                                            onPressed: () => setState(_search.clear),
                                            icon: const Icon(Icons.close, size: 18),
                                          ),
                                  ),
                                ),
                              ),
                              if (Theme.of(context).platform == TargetPlatform.windows)
                                IconButton(
                                  tooltip: s('New group', '新建群聊'),
                                  onPressed: _busy || _sending ? null : _createGroup,
                                  icon: const Icon(Icons.group_add_outlined),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: peers.isEmpty
                              ? _empty(
                                  query.isEmpty ? Icons.radar : Icons.search_off,
                                  query.isEmpty ? s('Find your devices', '发现你的设备') : s('No matching chats', '没有匹配的聊天'),
                                  query.isEmpty
                                      ? s('Open LocalSend on another device on the same network, then refresh.', '在同一网络的另一台设备上打开 LocalSend，然后刷新。')
                                      : s('Try another device name or nickname.', '试试其他设备名或备注名。'),
                                )
                              : ListView.builder(
                                  itemCount: peers.length,
                                  itemBuilder: (context, index) {
                                    final id = peers[index];
                                    final preference = store.preferencesFor(id);
                                    final online = nearby.containsKey(id);
                                    final last = latest[id];
                                    final group = _groupFor(id, store);
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: ListTile(
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                        selected: id == selected,
                                        selectedColor: colors.onSurface,
                                        selectedTileColor: Color.alphaBlend(_chatGreen.withValues(alpha: .18), colors.surfaceContainerLow),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 9),
                                        leading: group == null ? _peerAvatar(names[id]!, online: online) : const Icon(Icons.groups, size: 38),
                                        title: Row(
                                          children: [
                                            Expanded(child: Text(names[id]!, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                            if (last != null) Text(_chatTime(last.createdAt), style: Theme.of(context).textTheme.labelSmall),
                                          ],
                                        ),
                                        subtitle: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                group != null && last == null
                                                    ? s('${group.members.length} members', '${group.members.length} 位成员')
                                                    : _preview(last, online),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (preference.pinned) const Icon(Icons.push_pin, size: 14),
                                            if (preference.muted) Icon(Icons.notifications_off_outlined, size: 14, semanticLabel: s('Muted', '已免打扰')),
                                            if (mentioned.contains(id) && !preference.muted)
                                              Text(s('@You', '@我'), style: TextStyle(color: colors.error)),
                                            if (unread[id] case final int count)
                                              Padding(
                                                padding: const EdgeInsets.only(left: 4),
                                                child: Badge(
                                                  backgroundColor: preference.muted ? colors.outline : colors.error,
                                                  textColor: colors.onError,
                                                  label: preference.muted ? null : Text(count > 99 ? '99+' : '$count'),
                                                ),
                                              ),
                                          ],
                                        ),
                                        onTap: () => _selectPeer(id),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  );
                  final detail = selected == null
                      ? _empty(
                          Icons.chat_bubble_outline,
                          s('A conversation for every device', '每台设备，一个会话'),
                          s(
                            'Choose a device to share text, files and folders.\nYour transfer history stays on this device.',
                            '选择设备，发送文字、文件和文件夹。\n传输记录保留在本机。',
                          ),
                        )
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                              child: Row(
                                children: [
                                  if (!wide)
                                    IconButton(
                                      tooltip: s('Devices', '设备'),
                                      onPressed: () => _selectPeer(null),
                                      icon: const Icon(Icons.arrow_back),
                                    ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          names[selected] ?? selected,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleMedium,
                                        ),
                                        Text(
                                          selectedGroup != null
                                              ? s('${selectedGroup.members.length} members', '${selectedGroup.members.length} 位成员')
                                              : [
                                                  nearby.containsKey(selected) ? s('Nearby', '附近设备') : s('Not discovered', '未发现设备'),
                                                  if (store.preferencesFor(selected).trusted) s('Auto-receive on', '自动接收已开启'),
                                                ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: s('Search conversation history', '搜索聊天记录'),
                                    onPressed: _openHistorySearch,
                                    icon: const Icon(Icons.search),
                                  ),
                                  if (selectedGroup != null)
                                    IconButton(
                                      tooltip: s('Group members', '群成员'),
                                      icon: const Icon(Icons.groups_outlined),
                                      onPressed: () => _groupDetails(selectedGroup),
                                    )
                                  else
                                    PopupMenuButton<String>(
                                      tooltip: s('Device options', '设备选项'),
                                      onSelected: (action) async {
                                        final preference = ref.read(chatStoreProvider).preferencesFor(selected);
                                        if (action == 'details') await _details(selected, names[selected] ?? selected, nearby[selected]);
                                        if (action == 'receive-directory') await _configureReceiveDirectory(selected);
                                        if (action == 'mute') await _toggleMuted(selected);
                                        if (action == 'pin') {
                                          await ref.notifier(chatStoreProvider).setDevice(preference.copyWith(pinned: !preference.pinned));
                                        }
                                        if (action == 'trust') {
                                          if (preference.trusted ||
                                              await _confirm(
                                                s('Trust this device?', '信任此设备？'),
                                                s(
                                                  'After verifying its certificate fingerprint, trust this device to automatically receive future messages and files. Only trust devices you recognize.',
                                                  '核对证书指纹后，信任此设备后，将直接接收它今后发来的消息和文件。请仅信任你确认的设备。',
                                                ),
                                              )) {
                                            if (!mounted) return;
                                            final latest = ref.read(chatStoreProvider).preferencesFor(selected);
                                            await ref.notifier(chatStoreProvider).setDevice(latest.copyWith(trusted: !preference.trusted));
                                          }
                                        }
                                        if (action == 'clear' &&
                                            await _confirm(
                                              s('Clear conversation?', '清除会话？'),
                                              s('Only history metadata is removed. Files on disk are kept.', '仅清除历史记录，不删除磁盘文件。'),
                                            )) {
                                          await ref.notifier(chatStoreProvider).clearConversation(selected);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(value: 'details', child: Text(s('Device details / nickname', '设备详情 / 备注名'))),
                                        if (Theme.of(context).platform == TargetPlatform.windows)
                                          PopupMenuItem(value: 'receive-directory', child: Text(s('Save location for this chat…', '此聊天的保存位置…'))),
                                        PopupMenuItem(
                                          value: 'mute',
                                          child: Text(
                                            store.preferencesFor(selected).muted
                                                ? s('Unmute notifications', '关闭免打扰')
                                                : s('Mute notifications', '消息免打扰'),
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'pin',
                                          child: Text(store.preferencesFor(selected).pinned ? s('Unpin', '取消置顶') : s('Pin conversation', '置顶会话')),
                                        ),
                                        PopupMenuItem(
                                          value: 'trust',
                                          child: Text(
                                            store.preferencesFor(selected).trusted ? s('Revoke trust', '撤销信任') : s('Trust device…', '信任设备…'),
                                          ),
                                        ),
                                        PopupMenuItem(value: 'clear', child: Text(s('Clear history…', '清除历史…'))),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            if (selectedGroup != null && selectedGroup.announcement.isNotEmpty)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.campaign_outlined),
                                title: Text(selectedGroup.announcement, maxLines: 1, overflow: TextOverflow.ellipsis),
                                onTap: () => _readAnnouncement(selectedGroup),
                              ),
                            if (_historySearchOpen) _historySearchBar(),
                            Expanded(
                              child: ColoredBox(
                                color: colors.surfaceContainerLow,
                                child: Builder(
                                  builder: (context) {
                                    final entries = store.entries.where((e) => _conversationId(e) == selected).toList().reversed.toList();
                                    final keyword = _historySearch.text.trim().toLowerCase();
                                    final filtering = _historySearchOpen && (keyword.isNotEmpty || _historyFilesOnly);
                                    if (entries.isEmpty && !filtering) {
                                      return _empty(
                                        Icons.waving_hand_outlined,
                                        s('Ready when you are', '随时开始'),
                                        s('Send a message or drop files here.', '发送消息，或将文件拖到这里。'),
                                      );
                                    }
                                    final deliveries = <String, Map<String, ChatEntry>>{};
                                    final visible = entries.where((entry) {
                                      final id = entry.groupMessageId;
                                      if (!entry.outgoing || id == null) return true;
                                      final members = deliveries.putIfAbsent(id, () => {});
                                      final first = members.isEmpty;
                                      members.putIfAbsent(entry.peerFingerprint, () => entry);
                                      return first;
                                    }).toList();
                                    final results = filtering ? visible.where((entry) => _matchesHistory(entry, keyword)).toList() : visible;
                                    if (results.isEmpty) {
                                      return _empty(
                                        Icons.search_off,
                                        s('No matching records', '没有匹配的记录'),
                                        s('Try another keyword or turn off the file filter.', '换个关键词，或关闭「只看文件」。'),
                                      );
                                    }
                                    final list = ListView.builder(
                                      reverse: true,
                                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                      itemCount: results.length,
                                      itemBuilder: (context, index) {
                                        final entry = results[index];
                                        final date = DateUtils.dateOnly(entry.createdAt.toLocal());
                                        final showDate =
                                            index + 1 == results.length || date != DateUtils.dateOnly(results[index + 1].createdAt.toLocal());
                                        return Column(
                                          children: [
                                            if (showDate) _dateChip(date),
                                            _entry(entry, transfers, ownAlias, deliveries: deliveries[entry.groupMessageId], group: selectedGroup),
                                          ],
                                        );
                                      },
                                    );
                                    return filtering
                                        ? Column(
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.only(top: 7),
                                                child: Text(
                                                  s('${results.length} matching records', '${results.length} 条匹配记录'),
                                                  style: Theme.of(context).textTheme.labelSmall,
                                                ),
                                              ),
                                              Expanded(child: list),
                                            ],
                                          )
                                        : list;
                                  },
                                ),
                              ),
                            ),
                            if (incoming != null && incoming.sender.fingerprint == selected && incoming.status == SessionStatus.waiting)
                              Card(
                                margin: const EdgeInsets.all(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        invitation == null ? s('Incoming transfer', '收到传输请求') : s('Group invitation', '群聊邀请'),
                                        style: Theme.of(context).textTheme.titleSmall,
                                      ),
                                      Text(
                                        invitation == null
                                            ? incomingCount == 0
                                                  ? s('Text message', '文字消息')
                                                  : s('$incomingCount attachments', '$incomingCount 个附件')
                                            : s(
                                                'Join ${invitation.name}? Files and messages from group members are accepted automatically.',
                                                '加入「${invitation.name}」？加入后会自动接收群成员发来的群消息和文件。',
                                              ),
                                      ),
                                      if (incomingText != null)
                                        SelectableText(incomingText.length > 2000 ? '${incomingText.substring(0, 2000)}…' : incomingText),
                                      Wrap(
                                        spacing: 12,
                                        children: [
                                          TextButton(
                                            onPressed: _deciding
                                                ? null
                                                : () {
                                                    final current = ref.read(serverProvider)?.session;
                                                    if (current?.sessionId != incoming.sessionId || current?.status != SessionStatus.waiting) return;
                                                    ref.notifier(serverProvider).declineFileRequest();
                                                  },
                                            child: Text(s('Decline', '拒绝')),
                                          ),
                                          if (invitation == null && ref.notifier(serverProvider).canTrustChatRequest(incoming.sessionId))
                                            TextButton(
                                              onPressed: _deciding ? null : () => _acceptChat(incoming.sessionId, trust: true),
                                              child: Text(s('Accept & trust', '接收并信任')),
                                            ),
                                          FilledButton(
                                            onPressed: _deciding ? null : () => _acceptChat(incoming.sessionId),
                                            child: Text(invitation == null ? s('Accept', '接收') : s('Join group', '加入群聊')),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            _compose(staged, selectedGroup == null ? nearby.containsKey(selected) : groupAvailable, group: selectedGroup),
                          ],
                        );
                  return DropTarget(
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: (event) async {
                      setState(() => _dragging = false);
                      await _stage(() async {
                        for (final file in event.files) {
                          if (await Directory(file.path).exists()) {
                            await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(file.path));
                          } else {
                            await ref
                                .redux(selectedSendingFilesProvider)
                                .dispatchAsync(AddFilesAction(files: [file], converter: CrossFileConverters.convertXFile));
                          }
                        }
                      });
                    },
                    child: Stack(
                      children: [
                        if (wide)
                          Row(
                            children: [
                              _rail(ownAlias),
                              SizedBox(width: 246, child: list),
                              const VerticalDivider(width: 1),
                              Expanded(child: detail),
                            ],
                          )
                        else
                          selected == null ? list : detail,
                        if (_dragging)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: colors.primaryContainer.withValues(alpha: 0.94),
                                child: _empty(
                                  Icons.file_download_outlined,
                                  s('Drop to attach', '拖放以添加附件'),
                                  s('Files and folders are staged before sending.', '文件和文件夹将先添加到待发送列表。'),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        if (selected != null) const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openHistorySearch,
        if (_historySearchOpen) const SingleActivator(LogicalKeyboardKey.escape): _closeHistorySearch,
      },
      child: workspace,
    );
  }

  InputDecoration _inputDecoration(String hint) {
    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none);
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: colors.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: colors.primary)),
    );
  }

  Widget _rail(String alias) => Material(
    color: const Color(0xff242724),
    child: SizedBox(
      width: 60,
      child: Column(
        children: [
          const SizedBox(height: 14),
          Tooltip(message: alias, child: _peerAvatar(alias, size: 34)),
          const SizedBox(height: 15),
          IconButton(
            tooltip: s('Chats', '聊天'),
            isSelected: !_devicesOnly,
            color: const Color(0xffc9ceca),
            selectedIcon: const Icon(Icons.chat_bubble, color: Color(0xff40d48f)),
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => setState(() => _devicesOnly = false),
          ),
          IconButton(
            tooltip: s('Nearby devices', '附近设备'),
            isSelected: _devicesOnly,
            color: const Color(0xffc9ceca),
            selectedIcon: const Icon(Icons.devices, color: Color(0xff40d48f)),
            icon: const Icon(Icons.devices),
            onPressed: () {
              setState(() => _devicesOnly = true);
              ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());
            },
          ),
          const Spacer(),
          if (Theme.of(context).platform == TargetPlatform.windows)
            IconButton(
              tooltip: s('Check for updates (Chat $chatVersion)', '检查更新（聊天版 $chatVersion）'),
              color: const Color(0xffc9ceca),
              onPressed: _checkingUpdate || _updating ? null : () => _checkUpdates(manual: true),
              icon: const Icon(Icons.system_update_alt),
            ),
          IconButton(
            tooltip: s('Refresh discovery', '刷新设备发现'),
            color: const Color(0xffc9ceca),
            onPressed: () => ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan()),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: s('Settings', '设置'),
            color: const Color(0xffc9ceca),
            onPressed: widget.onSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _peerAvatar(String name, {bool online = false, double size = 38}) {
    final colors = Theme.of(context).colorScheme;
    const palette = [Color(0xff237957), Color(0xff3b6eaa), Color(0xff866339), Color(0xff795a9a), Color(0xffa64c63)];
    final label = name.trim();
    final initial = label.isEmpty ? '?' : label.characters.first.toUpperCase();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette[initial.runes.first % palette.length],
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            initial,
            maxLines: 1,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
        if (online)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: const Color(0xff299969),
                shape: BoxShape.circle,
                border: Border.all(color: colors.surface, width: 2),
              ),
            ),
          ),
      ],
    );
  }

  String _chatTime(DateTime timestamp) => TimeOfDay.fromDateTime(timestamp.toLocal()).format(context);

  String _preview(ChatEntry? entry, bool online) {
    if (entry == null) return online ? s('Nearby device', '附近设备') : s('Not discovered', '未发现设备');
    final caption = entry.text?.trim();
    if (caption != null && caption.isNotEmpty) return caption.replaceAll(RegExp(r'\s+'), ' ');
    if (entry.groupId != null && entry.outgoing && entry.attachments.isEmpty) return s('Group invitation', '群聊邀请');
    if (entry.attachments.isEmpty) return chatEntryStatusLabel(entry, chinese: Localizations.localeOf(context).languageCode == 'zh');
    final file = entry.attachments.first.name;
    return s('File · $file', '文件 · $file');
  }

  Widget _dateChip(DateTime date) {
    final theme = Theme.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final label = date == today ? s('Today', '今天') : MaterialLocalizations.of(context).formatMediumDate(date);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(18)),
      child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
    );
  }

  Widget _empty(IconData icon, String title, String subtitle) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 46, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 18),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );

  Widget _compose(List<CrossFile> staged, bool available, {ChatGroup? group}) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_reply case final reply?)
            Row(
              children: [
                Expanded(child: _quotePreview(reply)),
                IconButton(
                  tooltip: s('Cancel reply', '取消引用'),
                  onPressed: _busy ? null : () => setState(() => _reply = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          if (staged.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < staged.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InputChip(
                        label: Text(staged[i].name.length > 35 ? '…${staged[i].name.substring(staged[i].name.length - 35)}' : staged[i].name),
                        avatar: const Icon(Icons.insert_drive_file_outlined, size: 16),
                        onDeleted: _busy ? null : () => ref.redux(selectedSendingFilesProvider).dispatch(RemoveSelectedFileAction(i)),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              IconButton(
                tooltip: s('Attach files', '添加文件'),
                onPressed: _busy
                    ? null
                    : () => _stage(() async {
                        final files = await picker.openFiles();
                        await ref
                            .redux(selectedSendingFilesProvider)
                            .dispatchAsync(AddFilesAction(files: files, converter: CrossFileConverters.convertXFile));
                      }),
                icon: const Icon(Icons.attach_file, size: 21),
              ),
              IconButton(
                tooltip: s('Attach folder', '添加文件夹'),
                onPressed: _busy
                    ? null
                    : () => _stage(() async {
                        final directory = await picker.getDirectoryPath();
                        if (directory != null) await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory));
                      }),
                icon: const Icon(Icons.create_new_folder_outlined, size: 21),
              ),
              if (group != null && group.members.length > 1)
                IconButton(
                  tooltip: s('Mention a member', '@群成员'),
                  onPressed: _busy || _sending ? null : () => _pickMention(group),
                  icon: const Icon(Icons.alternate_email, size: 21),
                ),
              const Spacer(),
              if (!available)
                Flexible(
                  flex: 3,
                  child: Text(
                    group != null ? s('No nearby group members', '没有可发送的在线群成员') : s('Device not discovered', '设备未发现'),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
          Focus(
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent ||
                  event.logicalKey != LogicalKeyboardKey.enter ||
                  HardwareKeyboard.instance.isShiftPressed ||
                  (_composer.value.isComposingRangeValid && !_composer.value.composing.isCollapsed)) {
                return KeyEventResult.ignored;
              }
              if (!_busy && !_sending && available && (staged.isNotEmpty || _composer.text.trim().isNotEmpty)) unawaited(_send());
              return KeyEventResult.handled;
            },
            child: TextField(
              key: const ValueKey('chat-composer'),
              controller: _composer,
              focusNode: _composerFocus,
              minLines: 2,
              maxLines: 4,
              enabled: !_busy,
              onChanged: group == null || group.members.length < 2
                  ? null
                  : (text) {
                      final value = _composer.value;
                      final cursor = value.selection.baseOffset;
                      if (value.selection.isCollapsed &&
                          cursor > 0 &&
                          text[cursor - 1] == '@' &&
                          (!value.isComposingRangeValid || value.composing.isCollapsed) &&
                          (cursor == 1 || text[cursor - 2].trim().isEmpty)) {
                        unawaited(_pickMention(group, replaceAt: true));
                      }
                    },
              decoration: InputDecoration(
                hintText: s('Write a message…', '写一条消息…'),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  _busy
                      ? s('Working…', '处理中…')
                      : _sending
                      ? s('Sending…', '正在发送…')
                      : s('Enter to send · Shift+Enter for a new line', 'Enter 发送 · Shift+Enter 换行'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _composer,
                builder: (context, draft, _) => FilledButton(
                  key: const ValueKey('chat-send'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff087c4b),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: _busy || _sending || !available || (staged.isEmpty && draft.text.trim().isEmpty) ? null : () => _send(),
                  child: Text(s('Send', '发送')),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _attachment(ChatAttachment file, {required bool outgoing, required bool showStatus}) {
    final path = !outgoing && file.status == ChatAttachmentStatus.transferred ? file.path : null;
    final localPath = outgoing ? file.path : path;
    final menuPath = localPath != null && p.isAbsolute(localPath) && Theme.of(context).platform == TargetPlatform.windows
        ? p.normalize(localPath)
        : null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = chatAttachmentStatusLabel(file.status, chinese: Localizations.localeOf(context).languageCode == 'zh');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: menuPath == null ? null : (details) => _showAttachmentMenu(details, file, menuPath, outgoing: outgoing),
      onDoubleTap: path != null && chatCanOpenFile(path) ? () => _runAttachmentAction(_AttachmentAction.open, file, path) : null,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(8, 5, 0, 5),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant.withValues(alpha: .6)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: colors.primaryContainer,
              foregroundColor: colors.onPrimaryContainer,
              child: const Icon(Icons.insert_drive_file_outlined, size: 18),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    showStatus ? '${_size(file.size)} · $status' : _size(file.size),
                    style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  if (showStatus && file.error != null) Text(file.error!, style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
                ],
              ),
            ),
            if (path != null && chatCanOpenFile(path))
              IconButton(
                tooltip: s('Open file', '打开文件'),
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () => _runAttachmentAction(_AttachmentAction.open, file, path),
              ),
            if (menuPath != null)
              PopupMenuButton<_AttachmentAction>(
                tooltip: s('File options', '文件选项'),
                onSelected: (action) => _runAttachmentAction(action, file, menuPath),
                itemBuilder: (_) => _attachmentMenu(menuPath, outgoing: outgoing),
              ),
          ],
        ),
      ),
    );
  }

  bool _delivered(ChatEntry? entry) =>
      entry?.status == ChatTransferStatus.succeeded && entry!.attachments.every((file) => file.status == ChatAttachmentStatus.transferred);

  Future<void> _retryGroup(ChatGroup group, Map<String, ChatEntry> attempts) async {
    if (_busy || _sending || attempts.isEmpty) return;
    setState(() => _busy = true);
    final devices = ref.read(nearbyDevicesProvider).devices;
    final sender = ref.notifier(sendProvider);
    try {
      for (final attempt in attempts.entries) {
        if (!mounted) return;
        final device = devices[attempt.key];
        final previous = attempt.value;
        final current = ref.read(chatStoreProvider).groups[group.id];
        if (current == null ||
            !current.members.containsKey(ref.read(securityProvider).certificateHash) ||
            !current.members.containsKey(attempt.key) ||
            device == null ||
            !_canSendToGroupDevice(current, device) ||
            !supportsAdvancedChat(device.deviceModel)) {
          continue;
        }
        try {
          final packet = ChatGroupPacket(
            groupId: group.id,
            messageId: previous.groupMessageId!,
            text: previous.text,
            reply: previous.reply,
            mentions: previous.mentions,
            revision: current.revision,
            deduplicate: true,
          );
          final files = <CrossFile>[_chatPacketFile(packet)];
          for (final attachment in previous.attachments) {
            final path = attachment.path;
            if (path == null || !await File(path).exists()) {
              throw FileSystemException(s('Source file is missing. Choose it again.', '源文件已丢失，请重新选择。'), path);
            }
            final file = await CrossFileConverters.convertFile(File(path));
            if (file.size != attachment.size) {
              throw FileSystemException(s('Source file size changed. Send it as a new message.', '源文件大小已变化，请作为新消息发送。'), path);
            }
            files.add(file.copyWith(name: attachment.name));
          }
          if (!mounted) return;
          await sender.startSession(target: device, files: files, background: true);
        } catch (error) {
          _error(error);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showDeliveryDetails(ChatGroup group, Map<String, ChatEntry> deliveries, String? messageId) async {
    final own = ref.read(securityProvider).certificateHash;
    final devices = ref.read(nearbyDevicesProvider).devices;
    final recipients = {
      if (_activeGroupMessageId == messageId) ...group.members,
      for (final delivery in deliveries.values) delivery.peerFingerprint: group.members[delivery.peerFingerprint] ?? delivery.peerAlias,
    }..remove(own);
    final retryable = <String, ChatEntry>{
      for (final entry in deliveries.entries)
        if (!_busy &&
            !_sending &&
            group.members.containsKey(entry.key) &&
            !_delivered(entry.value) &&
            !entry.value.status.isActive &&
            !entry.value.groupInvitation &&
            (entry.value.text != null || entry.value.attachments.isNotEmpty) &&
            devices[entry.key]?.https == true &&
            supportsAdvancedChat(devices[entry.key]?.deviceModel))
          entry.key: entry.value,
    };
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s('Group delivery details', '群发送达详情')),
        content: SizedBox(
          width: 400,
          height: MediaQuery.sizeOf(context).height * .42,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final member in recipients.entries)
                ListTile(
                  title: Text(member.value),
                  subtitle: Text(
                    _delivered(deliveries[member.key])
                        ? s('Delivered', '已送达')
                        : (deliveries[member.key]?.status.isActive ?? (_activeGroupMessageId == messageId))
                        ? s('In progress', '发送中')
                        : s('Not delivered', '未送达'),
                  ),
                  trailing: retryable.containsKey(member.key)
                      ? TextButton(onPressed: () => Navigator.pop(context, member.key), child: Text(s('Retry', '补发')))
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s('Close', '关闭'))),
          if (retryable.isNotEmpty) FilledButton(onPressed: () => Navigator.pop(context, '*'), child: Text(s('Retry undelivered', '补发给未送达成员'))),
        ],
      ),
    );
    if (!mounted || result == null) return;
    final current = ref.read(chatStoreProvider).groups[group.id];
    if (current == null) return;
    await _retryGroup(current, result == '*' ? retryable : {result: retryable[result]!});
  }

  Widget _quotePreview(ChatReply reply) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text('${reply.author} · ${reply.excerpt}', maxLines: 2, overflow: TextOverflow.ellipsis),
  );

  Widget _entry(
    ChatEntry entry,
    FileTransferNotifier transfers,
    String ownAlias, {
    Map<String, ChatEntry>? deliveries,
    ChatGroup? group,
  }) {
    final colors = Theme.of(context).colorScheme;
    final sessionId = entry.id.substring(entry.id.indexOf(':') + 1);
    final live = transfers.getData()[sessionId];
    final progress = live == null || live.isEmpty ? null : live.values.fold<double>(0, (sum, f) => sum + f.progress) / live.length;
    final time = _chatTime(entry.createdAt);
    final avatar = _peerAvatar(entry.outgoing ? ownAlias : entry.peerAlias, size: 34);
    final groupOutgoing = group != null && deliveries != null && entry.outgoing;
    final delivered = deliveries?.values.where(_delivered).length ?? 0;
    final count = deliveries?.length ?? 0;
    return Align(
      alignment: entry.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!entry.outgoing) ...[avatar, const SizedBox(width: 8)],
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                margin: const EdgeInsets.only(bottom: 9),
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
                decoration: BoxDecoration(
                  color: entry.outgoing
                      ? Color.alphaBlend(_chatGreen.withValues(alpha: colors.brightness == Brightness.light ? .22 : .37), colors.surface)
                      : colors.surface,
                  border: Border.all(color: colors.outlineVariant.withValues(alpha: .45)),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(entry.outgoing ? 9 : 3),
                    topRight: Radius.circular(entry.outgoing ? 3 : 9),
                    bottomLeft: const Radius.circular(9),
                    bottomRight: const Radius.circular(9),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (group != null && !entry.outgoing)
                      Text(entry.peerAlias, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant)),
                    if (entry.reply case final reply?) _quotePreview(reply),
                    if (entry.text != null) SelectableText(entry.text!),
                    if (!entry.outgoing && entry.mentions.contains(ref.read(securityProvider).certificateHash))
                      Text(s('@You', '@我'), style: TextStyle(color: colors.error)),
                    if (groupOutgoing && entry.text == null && entry.attachments.isEmpty) Text(s('Group invitation', '群聊邀请')),
                    for (final file in entry.attachments) _attachment(file, outgoing: entry.outgoing, showStatus: !groupOutgoing),
                    if (!entry.status.isActive && (entry.text?.trim().isNotEmpty == true || entry.attachments.isNotEmpty))
                      IconButton(
                        tooltip: s('Reply to message', '引用回复'),
                        icon: const Icon(Icons.reply, size: 17),
                        visualDensity: VisualDensity.compact,
                        onPressed: _busy ? null : () => _quote(entry, entry.outgoing ? ownAlias : entry.peerAlias),
                      ),
                    const SizedBox(height: 4),
                    if (groupOutgoing)
                      TextButton(
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                        onPressed: () => _showDeliveryDetails(group, deliveries, entry.groupMessageId),
                        child: Text(s('$time · $delivered/$count delivered', '$time · 已送达 $delivered/$count')),
                      )
                    else
                      Align(
                        alignment: Alignment.centerRight,
                        widthFactor: 1,
                        child: Text(
                          '$time · ${chatEntryStatusLabel(entry, chinese: Localizations.localeOf(context).languageCode == 'zh')}',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    if (!groupOutgoing && entry.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SelectableText(entry.error!, style: TextStyle(color: colors.error)),
                      ),
                    if (!groupOutgoing && entry.status == ChatTransferStatus.transferring)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(value: progress),
                      ),
                    if (!groupOutgoing && entry.status.isActive)
                      TextButton(
                        onPressed: () {
                          if (entry.outgoing) {
                            ref.notifier(sendProvider).cancelSession(sessionId);
                          } else if (ref.read(serverProvider)?.session?.sessionId == sessionId) {
                            ref.notifier(serverProvider).cancelSession();
                          }
                        },
                        child: Text(s('Cancel transfer', '取消传输')),
                      ),
                    if (!groupOutgoing &&
                        entry.outgoing &&
                        !entry.status.isActive &&
                        ((entry.text != null && !entry.textDelivered && entry.status != ChatTransferStatus.succeeded) ||
                            entry.attachments.any((a) => a.status != ChatAttachmentStatus.transferred)))
                      TextButton(
                        onPressed: _busy || _sending ? null : () => _send(retry: entry),
                        child: Text(s('Retry as new transfer', '重新发起传输')),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (entry.outgoing) ...[const SizedBox(width: 8), avatar],
        ],
      ),
    );
  }

  String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1048576
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / 1048576).toStringAsFixed(1)} MiB';
}

String chatStatusLabel(ChatTransferStatus status, {bool chinese = false}) => switch (status) {
  ChatTransferStatus.pending => chinese ? '等待确认' : 'Waiting for approval',
  ChatTransferStatus.transferring => chinese ? '传输中' : 'Transferring',
  ChatTransferStatus.succeeded => chinese ? '已完成' : 'Completed',
  ChatTransferStatus.failed => chinese ? '失败' : 'Failed',
  ChatTransferStatus.canceled => chinese ? '已取消' : 'Canceled',
  ChatTransferStatus.interrupted => chinese ? '已中断，需重新发起' : 'Interrupted · start a new transfer',
  ChatTransferStatus.declined => chinese ? '已拒绝' : 'Declined',
};

String chatAttachmentStatusLabel(ChatAttachmentStatus status, {bool chinese = false}) => switch (status) {
  ChatAttachmentStatus.pending => chinese ? '等待传输' : 'Pending',
  ChatAttachmentStatus.transferred => chinese ? '已传输' : 'Transferred',
  ChatAttachmentStatus.skipped => chinese ? '未接收' : 'Not accepted',
  ChatAttachmentStatus.failed => chinese ? '失败' : 'Failed',
};

/// Only documents/media/archives get an in-app launch action. Programs and
/// scripts must be handled manually outside the chat workspace.
bool chatCanOpenFile(String path) {
  final extension = path.toLowerCase().split('.').last;
  return const {
    'pdf',
    'txt',
    'md',
    'csv',
    'json',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'tif',
    'tiff',
    'mp4',
    'mov',
    'mkv',
    'webm',
    'mp3',
    'wav',
    'ogg',
    'flac',
    'zip',
    '7z',
    'tar',
    'gz',
    'docx',
    'xlsx',
    'pptx',
    'odt',
    'ods',
    'odp',
  }.contains(extension);
}

String chatEntryStatusLabel(ChatEntry entry, {bool chinese = false}) {
  if (entry.status == ChatTransferStatus.succeeded && entry.attachments.isNotEmpty) {
    final transferred = entry.attachments.where((a) => a.status == ChatAttachmentStatus.transferred).length;
    if (transferred == 0) return chinese ? '未传输文件' : 'No files transferred';
    if (transferred < entry.attachments.length) return chinese ? '部分文件已传输' : 'Partially transferred';
  }
  return chatStatusLabel(entry.status, chinese: chinese);
}
