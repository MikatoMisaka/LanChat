import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/server_form_validator.dart';

void main() {
  test('accepts a complete join form', () {
    expect(
      ServerFormValidator.validate(
        baseUrl: 'https://chat.example.com',
        username: 'alice_1',
        password: 'password1',
        displayName: 'Alice',
        inviteCode: 'invite',
        isJoining: true,
      ),
      isEmpty,
    );
  });

  test('reports field errors before the request is sent', () {
    final errors = ServerFormValidator.validate(
      baseUrl: 'ftp://bad',
      username: 'Alice',
      password: 'short',
      displayName: '',
      inviteCode: '',
      isJoining: true,
    );

    expect(errors[ServerFormField.baseUrl], isNotNull);
    expect(errors[ServerFormField.username], isNotNull);
    expect(errors[ServerFormField.password], isNotNull);
    expect(errors[ServerFormField.displayName], isNotNull);
    expect(errors[ServerFormField.inviteCode], isNotNull);
  });

  test('does not require an invite when logging into an existing account', () {
    expect(
      ServerFormValidator.validate(
        baseUrl: 'http://192.168.1.10:8080',
        username: 'alice',
        password: 'password1',
        displayName: '',
        inviteCode: '',
        isJoining: false,
      ),
      isEmpty,
    );
  });
}
