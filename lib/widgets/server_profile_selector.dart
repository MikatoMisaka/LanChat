import 'package:flutter/material.dart';

import '../services/server_profile.dart';

class ServerProfileSelector extends StatelessWidget {
  const ServerProfileSelector({
    super.key,
    required this.profiles,
    required this.selected,
    required this.onSelected,
    required this.onAdd,
  });

  final List<ServerProfile> profiles;
  final ServerProfile? selected;
  final ValueChanged<ServerProfile> onSelected;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final current = profiles.contains(selected) ? selected : null;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: profiles.isEmpty
                  ? const Text('还没有服务器，请先添加一个服务器。')
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<ServerProfile>(
                        value: current,
                        isExpanded: true,
                        hint: const Text('选择服务器'),
                        onChanged: (profile) {
                          if (profile != null) onSelected(profile);
                        },
                        items: profiles
                            .map(
                              (profile) => DropdownMenuItem<ServerProfile>(
                                value: profile,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      profile.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      profile.uri.authority,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
            ),
            IconButton(
              tooltip: '添加服务器',
              onPressed: onAdd,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
      ),
    );
  }
}
