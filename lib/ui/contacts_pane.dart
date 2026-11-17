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
            final cams = service.cameras.length;
            return TabBar(
              controller: _tabs,
              tabs: [
                const Tab(icon: Icon(Icons.people), text: 'Peers'),
                Tab(
                  icon: const Icon(Icons.videocam),
                  text: cams == 0 ? 'Cameras' : 'Cameras ($cams)',
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
