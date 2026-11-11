import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/shared_preferences/shared_preferences_file.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('localsend-chat-prefs-');
    file = File('${directory.path}/nested/settings.json');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('writes complete snapshots, reloads and clears the cache', () async {
    final store = SharedPreferencesFile(filePath: file.path);
    await store.setValue('String', 'message', '你好');
    await store.setValue('Bool', 'trusted', false);
    expect(jsonDecode(file.readAsStringSync()), {'message': '你好', 'trusted': false});
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect(await SharedPreferencesFile(filePath: file.path).getAll(), {'message': '你好', 'trusted': false});
    await store.clear();
    expect(await store.getAll(), isEmpty);
    expect(jsonDecode(file.readAsStringSync()), isEmpty);
  });

  test('preserves corrupt settings instead of replacing them', () async {
    file.parent.createSync(recursive: true);
    const original = '{private damaged content';
    file.writeAsStringSync(original);
    final store = SharedPreferencesFile(filePath: file.path);
    await expectLater(store.getAll(), throwsFormatException);
    expect(file.readAsStringSync(), original);
  });

  test('accepts an intentionally empty portable settings file', () async {
    file.createSync(recursive: true);
    expect(await SharedPreferencesFile(filePath: file.path).getAll(), isEmpty);
  });
}
