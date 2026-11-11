import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

// Independent of the upstream LocalSend version. Increase for every Chat release.
const chatVersion = '1.0.0';
const chatRepository = 'rick-li-1299/LocalSend-Chat';
const chatUpdateAsset = 'LocalSend-Chat-windows-x64-unsigned.zip';

List<int> _version(String value) {
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value)) throw const FormatException('Invalid Chat version');
  return value.split('.').map(int.parse).toList();
}

bool isNewerChatVersion(String candidate, String current) {
  final a = _version(candidate);
  final b = _version(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

class ChatUpdate {
  final String version;
  final Uri url;
  final String sha256Hex;
  final int size;

  const ChatUpdate({required this.version, required this.url, required this.sha256Hex, required this.size});

  static ChatUpdate? fromRelease(Map<String, dynamic> release, {String current = chatVersion}) {
    if (release['draft'] != false || release['prerelease'] != false) return null;
    final tag = release['tag_name'];
    if (tag is! String || !RegExp(r'^chat-v\d+\.\d+\.\d+$').hasMatch(tag)) return null;
    final version = tag.substring(6);
    if (!isNewerChatVersion(version, current)) return null;
    for (final asset in release['assets'] as List<dynamic>? ?? []) {
      if (asset is! Map || asset['name'] != chatUpdateAsset || asset['state'] != 'uploaded') continue;
      final digest = asset['digest'];
      final size = asset['size'];
      final url = Uri.tryParse(asset['browser_download_url'] as String? ?? '');
      if (digest is! String ||
          !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
          size is! int ||
          size <= 0 ||
          size > 350 * 1024 * 1024 ||
          url == null ||
          url.scheme != 'https' ||
          url.host != 'github.com' ||
          url.hasQuery ||
          url.hasFragment ||
          url.userInfo.isNotEmpty ||
          url.path != '/$chatRepository/releases/download/$tag/$chatUpdateAsset') {
        throw const FormatException('Invalid update asset or missing SHA-256 digest');
      }
      return ChatUpdate(version: version, url: url, sha256Hex: digest.substring(7).toLowerCase(), size: size);
    }
    return null;
  }
}

class PreparedChatUpdate {
  final Directory directory;
  final ChatUpdate update;
  const PreparedChatUpdate(this.directory, this.update);

  Future<void> launch() async {
    final target = File(Platform.resolvedExecutable).parent.path;
    final executable = p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    await Process.start(executable, [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      p.join(directory.path, 'Apply-ChatUpdate.ps1'),
      '-Archive',
      p.join(directory.path, 'update.zip'),
      '-ExpectedSha256',
      update.sha256Hex,
      '-TargetDir',
      target,
      '-AppProcessId',
      '$pid',
    ], mode: ProcessStartMode.detached);
    // The helper verifies/extracts the archive and checks write access before
    // acknowledging readiness. A failed helper must never close the running app.
    for (var attempt = 0; attempt < 300; attempt++) {
      final failed = File(p.join(directory.path, 'failed'));
      if (await failed.exists()) throw FileSystemException(await failed.readAsString());
      if (await File(p.join(directory.path, 'ready')).exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await cancel();
    throw const FileSystemException('Update helper did not become ready; application remains open');
  }

  Future<void> cancel() => File(p.join(directory.path, 'cancel')).writeAsString('cancel').then((_) {});
}

class ChatUpdater {
  Future<HttpClientResponse> _get(HttpClient client, Uri url) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (url.scheme != 'https' ||
          url.userInfo.isNotEmpty ||
          !const {
            'api.github.com',
            'github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
          }.contains(url.host)) {
        throw const FormatException('Unexpected update host');
      }
      final request = await client.getUrl(url).timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'LocalSend-Chat/$chatVersion');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (location == null) throw const FormatException('Missing update redirect');
        url = url.resolve(location);
        continue;
      }
      return response;
    }
    throw const HttpException('Too many update redirects');
  }

  Future<ChatUpdate?> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final response = await _get(client, Uri.https('api.github.com', '/repos/$chatRepository/releases/latest'));
      if (response.statusCode == 404) return null; // No published release yet.
      if (response.statusCode != 200) throw HttpException('GitHub update check: ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) throw const FormatException('Update metadata too large');
      }
      return ChatUpdate.fromRelease(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }

  Future<PreparedChatUpdate> prepare(ChatUpdate update, void Function(double) onProgress) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows updates only');
    final directory = await Directory.systemTemp.createTemp('localsend-chat-update-');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final response = await _get(client, update.url);
      if (response.statusCode != 200) throw HttpException('Update download: ${response.statusCode}');
      final archive = File(p.join(directory.path, 'update.zip'));
      final sink = archive.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 45))) {
          received += chunk.length;
          if (received > update.size) throw const FormatException('Update exceeds expected size');
          sink.add(chunk);
          onProgress(received / update.size);
        }
      } finally {
        await sink.close();
      }
      if (received != update.size || (await sha256.bind(archive.openRead()).first).toString() != update.sha256Hex) {
        throw const FormatException('Update SHA-256 verification failed');
      }
      final script = await rootBundle.loadString('assets/update/Apply-ChatUpdate.ps1');
      await File(p.join(directory.path, 'Apply-ChatUpdate.ps1')).writeAsString(script, flush: true);
      return PreparedChatUpdate(directory, update);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
