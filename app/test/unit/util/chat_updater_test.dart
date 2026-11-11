import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/chat_updater.dart';

void main() {
  Map<String, dynamic> release({String tag = 'chat-v1.2.0', String? digest, String? url}) => {
    'draft': false,
    'prerelease': false,
    'tag_name': tag,
    'assets': [
      {
        'name': chatUpdateAsset,
        'state': 'uploaded',
        'size': 123,
        'digest': digest ?? 'sha256:${'a' * 64}',
        'browser_download_url': url ?? 'https://github.com/$chatRepository/releases/download/$tag/$chatUpdateAsset',
      },
    ],
  };

  test('versions compare numerically and never downgrade', () {
    expect(isNewerChatVersion('1.10.0', '1.9.9'), isTrue);
    expect(isNewerChatVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerChatVersion('0.99.99', '1.0.0'), isFalse);
    expect(() => isNewerChatVersion('1.2.0-rc1', '1.0.0'), throwsFormatException);
  });

  test('accepts only a newer stable Chat release with the expected asset', () {
    final update = ChatUpdate.fromRelease(release());
    expect(update!.version, '1.2.0');
    expect(update.sha256Hex, 'a' * 64);
    expect(ChatUpdate.fromRelease(release(tag: 'chat-v1.0.0')), isNull);
    expect(ChatUpdate.fromRelease(release(tag: 'v9.0.0')), isNull);
    expect(ChatUpdate.fromRelease({...release(), 'draft': true}), isNull);
    expect(ChatUpdate.fromRelease({...release(), 'prerelease': true}), isNull);
  });

  test('rejects missing or malformed integrity information', () {
    expect(() => ChatUpdate.fromRelease(release(digest: '')), throwsFormatException);
    expect(() => ChatUpdate.fromRelease(release(digest: 'md5:${'a' * 32}')), throwsFormatException);
    final invalidSize = release();
    (invalidSize['assets'] as List).first['size'] = 999999999;
    expect(() => ChatUpdate.fromRelease(invalidSize), throwsFormatException);
  });

  test('rejects downloads from another repository, host, or transport', () {
    for (final url in [
      'https://example.com/$chatUpdateAsset',
      'https://github.com/another/repo/releases/download/chat-v1.2.0/$chatUpdateAsset',
      'http://github.com/$chatRepository/releases/download/chat-v1.2.0/$chatUpdateAsset',
    ]) {
      expect(() => ChatUpdate.fromRelease(release(url: url)), throwsFormatException);
    }
  });
}
