import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import 'peer_list.dart';

/// The side list: intercoms (Everyone, groups, peers) and, on their own
/// tab, the IP cameras.
class ContactsPane extends StatefulWidget {
  const ContactsPane({
    super.key,
    required this.service,
    required this.onAddPeer,
  });

  final IntercomService service;
  final VoidCallback onAddPeer;

  @override
  State<ContactsPane> createState() => _ContactsPaneState();
}

class _ContactsPaneState extends State<ContactsPane>
    with SingleTickerProviderStateMixin {
  /// The tab last shown: kept when the list comes back (e.g. after a
  /// camera's picture took the screen on a phone).
  static int _lastTab = 0;

  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: _lastTab,
  )..addListener(() => _lastTab = _tabs.index);

  IntercomService get service => widget.service;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onAddPeer = widget.onAddPeer;
    return Column(
      children: [
        ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            // How many are online right now, on each tab.
            var peers = 0, cams = 0;
            for (final e in service.entries) {
              if (!e.online) continue;
              final id = e.peerId;
              if (id != null && service.camera(id) != null) {
                cams++;
              } else {
                peers++;
              }
            }
            return TabBar(
              controller: _tabs,
              tabs: [
                Tab(
                  icon: const Icon(Icons.people),
                  text: 'Peers · $peers online',
                ),
                Tab(
                  icon: const Icon(Icons.videocam),
                  text: 'Cameras · $cams online',
                ),
              ],
            );
          },
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              PeerList(service: service, onAddPeer: onAddPeer),
              PeerList(service: service, onAddPeer: onAddPeer, cameras: true),
            ],
          ),
        ),
      ],
    );
  }
}
