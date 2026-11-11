import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/pages/chat_page.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/chat_store_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust_metadata;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

class _Isolate extends Mock implements IsolateController {}

class _Favorites extends Mock implements FavoritesService {}

class _Discovery extends Mock implements DiscoveryLogger {}

class _Metadata extends Mock implements RustLibApi {
  @override
  Future<rust_metadata.FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async => null;
}

class _Persistence extends MockPersistenceService {
  @override
  bool getAlwaysOnTop() => false;
}

class _RecordingSend extends SendNotifier {
  final calls = <(Device, List<CrossFile>)>[];
  final controls = <(Device, ChatGroupPacket)>[];

  @override
  Future<int?> sendGroupControl(Device target, ChatGroupPacket packet, {bool interactive = false}) async {
    controls.add((target, packet));
    return 204;
  }

  @override
  Future<void> startSession({required Device target, required List<CrossFile> files, required bool background}) async {
    calls.add((target, files));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fontDirectory = String.fromEnvironment('CHAT_FONT_DIR');
  const screenshotDirectory = String.fromEnvironment('CHAT_SCREENSHOT_DIR');
  setUpAll(() async {
    if (fontDirectory.isNotEmpty) {
      for (final font in {'Roboto': 'Roboto-Regular.ttf', 'MaterialIcons': 'MaterialIcons-Regular.otf'}.entries) {
        final loader = FontLoader(font.key);
        loader.addFont(Future.value(ByteData.sublistView(await File('$fontDirectory/${font.value}').readAsBytes())));
        await loader.load();
      }
    }
  });
  Future<ChatStoreService> pump(
    WidgetTester tester, {
    bool devices = true,
    bool dark = false,
    _RecordingSend? send,
    List<CrossFile>? staged,
    TargetPlatform? platform,
    List<Device>? peers,
    _Persistence? persistenceService,
  }) async {
    final persistence = persistenceService ?? _Persistence();
    when(persistence.getAlias()).thenReturn('My desktop');
    when(persistence.getShareViaLinkAutoAccept()).thenReturn(false);
    when(persistence.getReceiveViaLinkAutoAccept()).thenReturn(false);
    when(persistence.getCreateChecksums()).thenReturn(false);
    when(persistence.getVerifyChecksums()).thenReturn(false);
    when(persistence.getAdvancedSettingsEnabled()).thenReturn(false);
    when(persistence.getDiscoveryTimeout()).thenReturn(2000);
    when(persistence.isHttps()).thenReturn(true);
    when(persistence.getSecurityContext()).thenReturn(
      StoredSecurityContext(privateKey: '', publicKey: '', certificate: '', certificateHash: 'A' * 64),
    );
    final store = ChatStoreService(read: () => null, write: (_) async {});
    final peer = Device.empty.copyWith(fingerprint: 'test-certificate', alias: 'Studio laptop');
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          persistenceProvider.overrideWithValue(persistence),
          chatStoreProvider.overrideWithNotifier((_) => store),
          if (send != null) sendProvider.overrideWithNotifier((_) => send),
          if (staged != null)
            selectedSendingFilesProvider.overrideWithInitialState(notifier: (_) => SelectedSendingFilesNotifier(), initialState: staged),
          nearbyDevicesProvider.overrideWithInitialState(
            notifier: (_) => NearbyDevicesService(isolateController: _Isolate(), favoriteService: _Favorites(), discoveryLogs: _Discovery()),
            initialState: NearbyDevicesState(
              runningFavoriteScan: false,
              runningIps: {},
              devices: devices
                  ? {
                      for (final device in peers ?? [peer]) device.fingerprint: device,
                    }
                  : {},
              signalingDevices: {},
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            platform: platform,
            fontFamily: fontDirectory.isEmpty ? null : 'Roboto',
            colorSchemeSeed: Colors.teal,
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: RepaintBoundary(
            key: const ValueKey('capture'),
            child: ChatPage(onSettings: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('double-click own name saves a trimmed name with Enter', (tester) async {
    final persistence = _Persistence();
    when(persistence.setAlias(any)).thenAnswer((_) async {});
    await pump(tester, persistenceService: persistence);
    final name = find.byKey(const ValueKey('own-name'));
    await tester.tap(name);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(name);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('own-name-input'));
    expect(tester.widget<TextField>(input).controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 10));
    await tester.enterText(input, '  我的电脑  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    verify(persistence.setAlias('我的电脑')).called(1);
    expect(find.text('我的电脑'), findsOneWidget);
    expect(input, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('own name rejects whitespace and Escape cancels without saving', (tester) async {
    final persistence = _Persistence();
    await pump(tester, persistenceService: persistence);
    final name = find.byKey(const ValueKey('own-name'));
    await tester.tap(name);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(name);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('own-name-input'));
    await tester.enterText(input, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Name cannot be empty'), findsOneWidget);
    await tester.tap(input);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(find.text('My desktop'), findsOneWidget);
    verifyNever(persistence.setAlias(any));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one send action submits draft and attachments together and then clears the composer', (tester) async {
    final sender = _RecordingSend();
    const binary = CrossFile(
      name: 'example.bin',
      fileType: FileType.other,
      size: 3,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: [1, 2, 3],
      lastModified: null,
      lastAccessed: null,
    );
    await pump(tester, send: sender, staged: [binary]);
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(field, '中文\n🙂');
    await tester.pump();
    expect(find.text('example.bin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();
    final (target, files) = sender.calls.single;
    expect(target.fingerprint, 'test-certificate');
    expect(files.map((f) => f.name), ['message.txt', 'example.bin']);
    expect(utf8.decode(files.first.bytes!), '中文\n🙂');
    expect(files.last.bytes, [1, 2, 3]);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('example.bin'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-click Save as copies a received attachment and keeps the original', (tester) async {
    final folder = Directory.systemTemp.createTempSync('localsend-save-test-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final original = File('${folder.path}${Platform.pathSeparator}example.bin')..writeAsBytesSync([3, 19, 255]);
    final copy = File('${folder.path}${Platform.pathSeparator}saved-copy.bin');
    const pickerChannel = MethodChannel('plugins.flutter.io/file_selector');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pickerChannel, (call) async {
      expect(call.method, 'getSavePath');
      expect(call.arguments['suggestedName'], 'example.bin');
      return copy.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pickerChannel, null));
    final store = await pump(tester, platform: TargetPlatform.windows);
    await store.upsertEntry(
      ChatEntry(
        id: 'in:example',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: false,
        createdAt: DateTime.utc(2026),
        status: ChatTransferStatus.succeeded,
        attachments: [
          ChatAttachment(name: 'example.bin', size: 3, path: original.path, fileType: FileType.other, status: ChatAttachmentStatus.transferred),
        ],
      ),
    );
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('example.bin')),
      kind: ui.PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Save as…'), findsOneWidget);
    expect(find.text('Show in folder'), findsOneWidget);
    expect(find.text('Open file'), findsNothing);
    await tester.tap(find.text('Save as…'));
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (!copy.existsSync() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    }
    await tester.pumpAndSettle();
    expect(copy.existsSync(), isTrue, reason: 'Save as should write the selected destination');
    expect(copy.readAsBytesSync(), [3, 19, 255]);
    expect(original.readAsBytesSync(), [3, 19, 255]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation search filters by nickname and can be cleared', (tester) async {
    final store = await pump(tester);
    await store.setDevice(const ChatDevicePreferences(fingerprint: 'office', alias: 'Office PC'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('chat-search'));
    await tester.enterText(search, 'OFFICE');
    await tester.pumpAndSettle();
    expect(find.text('Office PC'), findsOneWidget);
    expect(find.text('Studio laptop'), findsNothing);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Studio laptop'), findsOneWidget);
    expect(find.text('Office PC'), findsOneWidget);
  });

  testWidgets('history search finds text and filenames and preserves the composer draft', (tester) async {
    final store = await pump(tester, platform: TargetPlatform.windows);
    await store.upsertEntry(
      ChatEntry(
        id: 'in:history-text',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: false,
        createdAt: DateTime.utc(2026),
        status: ChatTransferStatus.succeeded,
        text: 'Report discussion',
      ),
    );
    await store.upsertEntry(
      ChatEntry(
        id: 'in:history-file',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: false,
        createdAt: DateTime.utc(2026, 1, 2),
        status: ChatTransferStatus.succeeded,
        attachments: [ChatAttachment(name: 'Report.XLSX', size: 3, fileType: FileType.other, status: ChatAttachmentStatus.transferred)],
      ),
    );
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('chat-composer'));
    final search = find.byKey(const ValueKey('history-search-input'));
    final message = find.widgetWithText(SelectableText, 'Report discussion');
    await tester.enterText(composer, 'Keep this draft');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);

    await tester.enterText(search, '  report  ');
    await tester.pumpAndSettle();
    expect(find.text('2 matching records'), findsOneWidget);
    expect(message, findsOneWidget);
    expect(find.text('Report.XLSX'), findsOneWidget);

    await tester.tap(find.text('Files only'));
    await tester.pumpAndSettle();
    expect(find.text('1 matching records'), findsOneWidget);
    expect(message, findsNothing);
    expect(find.text('Report.XLSX'), findsOneWidget);

    await tester.enterText(search, 'discussion');
    await tester.pumpAndSettle();
    expect(find.text('No matching records'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear keyword'));
    await tester.pumpAndSettle();
    expect(find.text('Report.XLSX'), findsOneWidget);
    expect(message, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    expect(message, findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, 'Keep this draft');
  });

  testWidgets('right-click forwards an outgoing file without clearing the current draft', (tester) async {
    RustLib.initMock(api: _Metadata());
    addTearDown(RustLib.dispose);
    final folder = Directory.systemTemp.createTempSync('localsend-forward-test-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}${Platform.pathSeparator}notes.bin')..writeAsBytesSync([1, 2, 3]);
    final sender = _RecordingSend();
    final store = await pump(tester, send: sender, platform: TargetPlatform.windows);
    await store.upsertEntry(
      ChatEntry(
        id: 'out:forward',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: true,
        createdAt: DateTime.utc(2026),
        status: ChatTransferStatus.succeeded,
        attachments: [
          ChatAttachment(name: 'notes.bin', size: 3, fileType: FileType.other, path: file.path, status: ChatAttachmentStatus.transferred),
        ],
      ),
    );
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(composer, 'Keep this draft');
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('notes.bin')),
      kind: ui.PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forward…'));
    final dialogDeadline = DateTime.now().add(const Duration(seconds: 4));
    while (find.text('Forward file').evaluate().isEmpty && DateTime.now().isBefore(dialogDeadline)) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(RadioListTile<String>, 'Studio laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forward'));
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (sender.calls.isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    }
    await tester.pumpAndSettle();
    expect(sender.calls.single.$2.single.path, file.path);
    expect(sender.calls.single.$2.single.name, 'notes.bin');
    expect(tester.widget<TextField>(composer).controller!.text, 'Keep this draft');
  });

  testWidgets('creating a shared group invites both members and sending uses one shared message id', (tester) async {
    final sender = _RecordingSend();
    final devices = [
      Device.empty.copyWith(fingerprint: 'B' * 64, alias: 'Studio laptop', https: true, deviceModel: chatGroupDeviceMarker),
      Device.empty.copyWith(fingerprint: 'C' * 64, alias: 'Office PC', https: true, deviceModel: chatGroupDeviceMarker),
    ];
    final store = await pump(tester, send: sender, platform: TargetPlatform.windows, peers: devices);
    await tester.tap(find.byTooltip('New group'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Group name'), '办公室');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Office PC'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Studio laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create and invite'));
    await tester.pumpAndSettle();
    expect(sender.calls, hasLength(2));
    final invitations = sender.calls.map((call) => ChatGroupPacket.decode(utf8.decode(call.$2.single.bytes!))!).toList();
    expect(invitations.map((packet) => packet.invitation!.name), ['办公室', '办公室']);
    expect(invitations.first.invitation!.members.length, 3);
    final group = invitations.first.groupId;
    expect(store.state.groups[group]?.name, '办公室');
    sender.calls.clear();
    await tester.enterText(find.byKey(const ValueKey('chat-composer')), '下班前发报告');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();
    expect(sender.calls.map((call) => call.$1.fingerprint).toSet(), {'B' * 64, 'C' * 64});
    final messages = sender.calls.map((call) => ChatGroupPacket.decode(utf8.decode(call.$2.single.bytes!))!).toList();
    expect(messages.map((packet) => packet.groupId).toSet(), {group});
    expect(messages.map((packet) => packet.messageId).toSet(), hasLength(1));
    expect(messages.first.text, '下班前发报告');
    for (final device in devices) {
      await store.upsertEntry(
        ChatEntry(
          id: 'out:group-search:${device.fingerprint}',
          peerFingerprint: device.fingerprint,
          peerAlias: device.alias,
          outgoing: true,
          createdAt: DateTime.utc(2026),
          status: ChatTransferStatus.succeeded,
          groupId: group,
          groupMessageId: messages.first.messageId,
          text: messages.first.text,
        ),
      );
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search conversation history'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('history-search-input')), '报告');
    await tester.pumpAndSettle();
    expect(find.text('1 matching records'), findsOneWidget);
    expect(find.textContaining('2/2 delivered'), findsOneWidget);
    await tester.tap(find.byTooltip('Close history search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Group members'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(store.state.groups, isEmpty);
  });

  final advancedDevices = [
    for (final (certificate, alias) in [('B', 'Studio laptop'), ('C', 'Office PC'), ('D', 'New device')])
      Device.empty.copyWith(
        fingerprint: certificate * 64,
        alias: alias,
        https: true,
        deviceModel: '$chatAdvancedDeviceMarker$chatGroupDeviceMarker',
      ),
  ];
  final group = ChatGroup(
    id: 'da6a2a75-3d1f-4d08-82bb-bebfc7d55d6b',
    name: 'Team workspace',
    owner: 'A' * 64,
    members: {'A' * 64: 'My desktop', for (final device in advancedDevices.take(2)) device.fingerprint: device.alias},
  );

  testWidgets('group delivery retries only an undelivered recipient with the original message id', (tester) async {
    final sender = _RecordingSend();
    final store = await pump(tester, send: sender, platform: TargetPlatform.windows, peers: advancedDevices);
    await store.addGroup(group);
    const messageId = '5db86d01-9838-4186-9021-b0104f4d79d6';
    for (final (index, device) in advancedDevices.take(2).indexed) {
      await store.upsertEntry(
        ChatEntry(
          id: 'out:test-retry-$index',
          peerFingerprint: device.fingerprint,
          peerAlias: device.alias,
          outgoing: true,
          createdAt: DateTime.utc(2026, 1, index + 1),
          status: index == 0 ? ChatTransferStatus.succeeded : ChatTransferStatus.failed,
          text: 'Original message',
          groupId: group.id,
          groupMessageId: messageId,
        ),
      );
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text(group.name));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('1/2 delivered'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry undelivered'));
    await tester.pumpAndSettle();
    expect(sender.calls, hasLength(1));
    expect(sender.calls.single.$1.fingerprint, advancedDevices[1].fingerprint);
    final packet = ChatGroupPacket.decode(utf8.decode(sender.calls.single.$2.single.bytes!))!;
    expect(packet.messageId, messageId);
    expect(packet.text, 'Original message');
    expect(packet.deduplicate, isTrue);
  });

  testWidgets('quoting a group message and mentioning a member adds structured data to the send', (tester) async {
    final sender = _RecordingSend();
    final store = await pump(tester, send: sender, platform: TargetPlatform.windows, peers: advancedDevices);
    await store.addGroup(group);
    await store.upsertEntry(
      ChatEntry(
        id: 'in:reference',
        peerFingerprint: advancedDevices[0].fingerprint,
        peerAlias: advancedDevices[0].alias,
        outgoing: false,
        createdAt: DateTime.utc(2026),
        status: ChatTransferStatus.succeeded,
        groupId: group.id,
        text: 'Please review the report',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(group.name));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reply to message'));
    await tester.pumpAndSettle();
    expect(find.text('Studio laptop · Please review the report'), findsOneWidget);
    await tester.tap(find.byTooltip('Mention a member'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'Office PC'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();
    expect(sender.calls, hasLength(2));
    final packet = ChatGroupPacket.decode(utf8.decode(sender.calls.first.$2.single.bytes!))!;
    expect(packet.text, '@Office PC ');
    expect(packet.reply!.excerpt, 'Please review the report');
    expect(packet.mentions, ['C' * 64]);
  });

  testWidgets('group details saves mute locally and synchronizes a published announcement', (tester) async {
    final sender = _RecordingSend();
    final store = await pump(tester, send: sender, platform: TargetPlatform.windows, peers: advancedDevices);
    await store.addGroup(group);
    await tester.pumpAndSettle();
    await tester.tap(find.text(group.name));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Group members'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute notifications'));
    await tester.pumpAndSettle();
    expect(store.state.preferencesFor(group.conversationId).muted, isTrue);
    expect(sender.controls, isEmpty);
    await tester.tap(find.byTooltip('Group members'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group announcement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'Friday handoff');
    await tester.tap(find.text('Save announcement'));
    await tester.pumpAndSettle();
    expect(store.state.groups[group.id]?.announcement, 'Friday handoff');
    expect(find.text('Friday handoff'), findsOneWidget);
    expect(sender.controls.map((call) => call.$2.snapshot!.announcement), ['Friday handoff', 'Friday handoff']);
  });

  testWidgets('the owner can appoint an admin, invite a new member, and remove a member', (tester) async {
    final sender = _RecordingSend();
    final store = await pump(tester, send: sender, platform: TargetPlatform.windows, peers: advancedDevices);
    await store.addGroup(group);
    await tester.pumpAndSettle();
    await tester.tap(find.text(group.name));
    await tester.pumpAndSettle();

    Future<void> openDetails() async {
      await tester.tap(find.byTooltip('Group members'));
      await tester.pumpAndSettle();
    }

    Future<void> manage(String name, String operation) async {
      await openDetails();
      final tile = find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(ListTile, name));
      final button = find.descendant(of: tile, matching: find.byTooltip('Manage member'));
      await tester.scrollUntilVisible(
        button,
        80,
        scrollable: find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text(operation));
      await tester.pumpAndSettle();
    }

    await manage('Studio laptop', 'Make admin');
    expect(store.state.groups[group.id]?.admins, {'B' * 64});
    await openDetails();
    await tester.tap(find.text('Add group member'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, 'New device'));
    await tester.pumpAndSettle();
    expect(store.state.groups[group.id]?.members['D' * 64], 'New device');
    await manage('Office PC', 'Remove from group');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(store.state.groups[group.id]?.members.containsKey('C' * 64), isFalse);
    expect(store.state.groups[group.id]?.removed, {'C' * 64});
    expect(store.state.groups[group.id]?.revision, 3);
  });

  testWidgets('a received message shows an unread badge until its chat opens', (tester) async {
    final store = await pump(tester);
    await store.upsertEntry(
      ChatEntry(
        id: 'in:unread',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: false,
        createdAt: DateTime.now().add(const Duration(milliseconds: 1)),
        status: ChatTransferStatus.succeeded,
        text: 'New message',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Badge), findsOneWidget);
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(Badge), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('chat-composer'))).focusNode!.hasFocus, isTrue);
  });

  testWidgets('empty desktop and narrow list/detail remain usable', (tester) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(tester, devices: false);
    expect(find.text('Find your devices'), findsOneWidget);
    expect(find.text('A conversation for every device'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
    tester.view.physicalSize = const Size(430, 760);
    await tester.pumpAndSettle();
    expect(find.text('Studio laptop'), findsOneWidget);
    expect(find.text('Write a message…'), findsNothing);
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    expect(find.text('Write a message…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Write a message…'), findsNothing);
  });

  testWidgets('history shows truthful status and error, pin never grants trust', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await pump(tester, dark: true);
    await store.upsertEntry(
      ChatEntry(
        id: 'out:example',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: true,
        createdAt: DateTime(2026, 11, 7, 14, 25),
        status: ChatTransferStatus.failed,
        text: 'Here is the revised outline.',
        error: 'Connection refused',
      ),
    );
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    expect(find.text('Connection refused'), findsOneWidget);
    expect(find.text('Retry as new transfer'), findsOneWidget);
    await tester.tap(find.byTooltip('Device options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin conversation'));
    await tester.pumpAndSettle();
    expect(store.state.preferencesFor('test-certificate').pinned, isTrue);
    expect(store.state.preferencesFor('test-certificate').trusted, isFalse);
    expect(tester.takeException(), isNull);
    // Headless Flutter-rendered image, not live GUI or device QA.
    if (screenshotDirectory.isNotEmpty) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('capture')));
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(screenshotDirectory).create(recursive: true);
        await File('$screenshotDirectory/chat-desktop-dark.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('partial acceptance labels each file and preserves retry action', (tester) async {
    final store = await pump(tester);
    await store.upsertEntry(
      ChatEntry(
        id: 'out:partial',
        peerFingerprint: 'test-certificate',
        peerAlias: 'Studio laptop',
        outgoing: true,
        createdAt: DateTime(2026),
        status: ChatTransferStatus.succeeded,
        attachments: const [
          ChatAttachment(name: 'accepted.pdf', size: 100, fileType: FileType.other, status: ChatAttachmentStatus.transferred),
          ChatAttachment(name: 'declined.pdf', size: 100, fileType: FileType.other, status: ChatAttachmentStatus.skipped),
        ],
      ),
    );
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Transferred'), findsOneWidget);
    expect(find.textContaining('Not accepted'), findsOneWidget);
    expect(find.textContaining('Partially transferred'), findsOneWidget);
    expect(find.text('Retry as new transfer'), findsOneWidget);
    expect(find.byTooltip('Open file'), findsNothing);
    await tester.tap(find.text('Retry as new transfer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Source file is missing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trust requires confirmation and can be revoked independently of pin', (tester) async {
    final store = await pump(tester);
    await tester.tap(find.text('Studio laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Device options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trust device…'));
    await tester.pumpAndSettle();
    expect(store.state.preferencesFor('test-certificate').trusted, isFalse);
    expect(find.textContaining('automatically receive future messages and files'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(store.state.preferencesFor('test-certificate').trusted, isTrue);
    expect(store.state.preferencesFor('test-certificate').pinned, isFalse);
    await tester.tap(find.byTooltip('Device options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke trust'));
    await tester.pumpAndSettle();
    expect(store.state.preferencesFor('test-certificate').trusted, isFalse);
  });

  test('native tab callbacks work without a desktop PageView', () {
    final ref = RefenaContainer();
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
    expect(ref.read(homePageControllerProvider).currentTab, HomeTab.send);
    ref.read(homePageControllerProvider).controller.dispose();
    ref.disposeContainer();
  });

  test('programs and scripts cannot be launched from chat', () {
    for (final path in ['setup.exe', 'run.sh', 'launch.desktop', 'run.bat', 'macro.xlsm', 'binary']) {
      expect(chatCanOpenFile(path), isFalse);
    }
    expect(chatCanOpenFile('report.PDF'), isTrue);
  });

  test('all terminal status labels are distinct', () {
    expect(ChatTransferStatus.values.map(chatStatusLabel).toSet().length, ChatTransferStatus.values.length);
    expect(chatStatusLabel(ChatTransferStatus.interrupted), contains('new transfer'));
    expect(chatStatusLabel(ChatTransferStatus.declined, chinese: true), '已拒绝');
  });
}
