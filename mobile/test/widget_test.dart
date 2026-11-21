import 'package:campusvibe/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Requires a public HTTPS origin without URL credentials', () {
    expect(httpsOrigin(' https://campus.example/ '), 'https://campus.example');
    for (final url in [
      'http://campus.example',
      'https://user:pwd@campus.example',
      'https://campus.example/path',
      'https://campus.example?test=1'
    ]) {
      expect(() => httpsOrigin(url), throwsFormatException);
    }
  });
  testWidgets('Student sees Google-only sign-in, not the server form',
      (tester) async {
    api = '';
    await tester.pumpWidget(const CampusVibe());
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Campus HTTPS address'), findsNothing);
    expect(find.text('Join CampusVibe'), findsNothing);
    expect(find.textContaining('backend has not been configured'), findsOneWidget);
  });
}
