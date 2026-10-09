import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/updater.dart';

void main() {
  group('SemVer', () {
    int cmp(String a, String b) => SemVer.tryParse(a)!.compareTo(SemVer.tryParse(b)!);

    test('orders numerically, not as text', () {
      expect(cmp('0.10.0', '0.9.9'), greaterThan(0));
      expect(cmp('1.0.0', '0.99.99'), greaterThan(0));
      expect(cmp('1.2.3', '1.2.3'), 0);
    });
    test('a release candidate is older than its final release, rc10 newer than rc9', () {
      expect(cmp('0.1.0-rc3', '0.1.0'), lessThan(0));
      expect(cmp('0.1.0-rc10', '0.1.0-rc9'), greaterThan(0));
      expect(cmp('0.1.0-rc3', '0.1.0-rc4'), lessThan(0));
      expect(cmp('0.1.1-rc1', '0.1.0'), greaterThan(0));
      expect(cmp('0.1.0-beta1', '0.1.0-rc1'), lessThan(0));
    });
    test('accepts a v prefix and build metadata, rejects junk', () {
      expect(SemVer.tryParse('v1.2.3')?.toString(), '1.2.3');
      expect(SemVer.tryParse('1.2.3+4')?.toString(), '1.2.3');
      expect(SemVer.tryParse('latest'), isNull);
      expect(SemVer.tryParse('1.2'), isNull);
    });
  });

  group('release feed', () {
    Map<String, dynamic> rel(String tag, {bool pre = false, bool draft = false, List<String> assets = const []}) => {
          'tag_name': tag,
          'prerelease': pre,
          'draft': draft,
          'html_url': 'https://github.com/x/y/releases/tag/$tag',
          'body': "## What's Changed\n* a\n* b\n\n**Full Changelog**: z",
          'published_at': '2026-10-09T12:59:33Z',
          'assets': [for (final a in assets) {'name': a, 'browser_download_url': 'https://dl/$a', 'size': 10}],
        };

    test('picks the newest, ignoring drafts and (by default) pre-releases', () {
      final feed = [rel('v0.2.0-rc1', pre: true), rel('v0.1.0'), rel('v0.3.0', draft: true), rel('v0.0.9')];
      expect(latestRelease(feed, includePrerelease: false)?.tag, 'v0.1.0');
      expect(latestRelease(feed, includePrerelease: true)?.tag, 'v0.2.0-rc1');
    });
    test('empty or unusable feed gives nothing', () {
      expect(latestRelease([], includePrerelease: true), isNull);
      expect(latestRelease([rel('nightly')], includePrerelease: true), isNull);
    });
    test('keeps assets and the page url', () {
      final r = latestRelease([rel('v1.0.0', assets: ['a.zip', 'SHA256SUMS.txt'])], includePrerelease: false)!;
      expect(r.asset('a.zip')?.url, 'https://dl/a.zip');
      expect(r.asset('missing'), isNull);
      expect(r.pageUrl, endsWith('/tag/v1.0.0'));
    });
  });

  test('shortNotes keeps the change list and drops the changelog link', () {
    final n = shortNotes("intro table\n\n## What's Changed\n* one\n* two\n\n**Full Changelog**: https://x");
    expect(n, '* one\n* two');
    expect(shortNotes('plain text'), 'plain text');
  });

  test('sha256For reads "hash  file" lines, with or without the binary marker', () {
    final h1 = 'a' * 64, h2 = 'B' * 64;
    final sums = '$h1  Linkory-1.zip\n$h2 *Linkory-2.zip\n';
    expect(sha256For(sums, 'Linkory-1.zip'), h1);
    expect(sha256For(sums, 'Linkory-2.zip'), 'b' * 64);
    expect(sha256For(sums, 'nope'), isNull);
  });
}
