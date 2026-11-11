import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _beautyEncoder = JsonEncoder.withIndent('  ');
const _encoder = JsonEncoder();

/// Custom implementation of SharedPreferencesStorePlatform
/// that uses a custom file.
class SharedPreferencesFile extends SharedPreferencesStorePlatform {
  final File _file;
  final bool beautify;

  SharedPreferencesFile({
    required String filePath,
    this.beautify = false,
  }) : _file = File(filePath);

  late final Map<String, Object> _cache = _getAll();

  bool exists() {
    return _file.existsSync();
  }

  String getPath() {
    return _file.path;
  }

  @override
  Future<bool> clear() {
    _cache.clear();
    _write(_cache);
    return Future.value(true);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    return _cache;
  }

  Map<String, Object> _getAll() {
    if (!_file.existsSync()) return {};
    final contents = _file.readAsStringSync();
    // Empty settings.json is the documented way to select portable mode.
    if (contents.trim().isEmpty) return {};
    try {
      return json.decode(contents).cast<String, Object>();
    } catch (_) {
      // Never silently replace a damaged history or device identity with defaults.
      // Omit decoder details because they may contain private message text.
      throw const FormatException('Settings could not be read. The original file has been preserved.');
    }
  }

  @override
  Future<bool> remove(String key) {
    _cache.remove(key);
    _write(_cache);
    return Future.value(true);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _cache[key] = value;
    _write(_cache);
    return Future.value(true);
  }

  void _write(Map<String, dynamic> data) {
    _file.parent.createSync(recursive: true);
    final temporary = File('${_file.path}.tmp');
    temporary.writeAsStringSync((beautify ? _beautyEncoder : _encoder).convert(data), flush: true);
    // Rename in the same directory replaces the previous complete snapshot only
    // after the new bytes are flushed. An interrupted write leaves the old file.
    temporary.renameSync(_file.path);
  }
}
