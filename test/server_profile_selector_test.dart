import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/server_profile.dart';
import 'package:lanchat/widgets/server_profile_selector.dart';

void main() {
  testWidgets('opens the compact mobile server selector and changes profile', (
    tester,
  ) async {
    final profiles = [
      ServerProfile(
        id: 'home',
        name: '家庭服务器',
        baseUrl: 'https://home.example.com',
        username: 'alice',
      ),
      ServerProfile(
        id: 'work',
        name: '工作服务器',
        baseUrl: 'https://work.example.com',
        username: 'alice',
      ),
    ];
    ServerProfile? selected = profiles.first;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ServerProfileSelector(
              profiles: profiles,
              selected: selected,
              onSelected: (profile) => setState(() => selected = profile),
              onAdd: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('家庭服务器'), findsOneWidget);
    expect(find.text('工作服务器'), findsNothing);

    await tester.tap(find.byType(DropdownButton<ServerProfile>));
    await tester.pumpAndSettle();
    expect(find.text('工作服务器'), findsOneWidget);

    await tester.tap(find.text('工作服务器').last);
    await tester.pumpAndSettle();
    expect(selected, profiles.last);
  });
}
