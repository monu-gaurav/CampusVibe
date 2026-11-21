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
  testWidgets('Email sign-in and registration open without a server prompt', (tester) async {
    api = '';
    await tester.pumpWidget(const CampusVibe());
    expect(find.text('Sign in with email'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Campus HTTPS address'), findsNothing);
    await tester.tap(find.text('New here? Create an account'));
    await tester.pump();
    expect(find.text('Full name'), findsOneWidget);
    await tester.tap(find.text('Create account'));
    await tester.pump();
    expect(find.textContaining('at least 10 characters.'), findsOneWidget);
  });
}
