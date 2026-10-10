import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/server_options.dart';

void main() {
  test('official domain alias retains server identity without merging other servers', () {
    expect(officialServerUrl, 'https://linkory.yuhuotech.com');
    expect(sameServerIdentity('https://linkory.dev99.cn/', officialServerUrl), isTrue);
    expect(sameServerIdentity(officialServerUrl, 'https://linkory.dev99.cn'), isTrue);
    expect(sameServerIdentity('https://custom.example', officialServerUrl), isFalse);
    expect(sameServerIdentity('http://linkory.dev99.cn', officialServerUrl), isFalse);
    expect(sameServerIdentity('https://same.example/', 'https://same.example'), isTrue);
  });
}
