import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/edition.dart';

void main() {
  test('basic builds hide the server edition by default', () {
    expect(serverEdition, isFalse);
  });
}
