import 'package:flutter/material.dart';

import '../src/intercom_service.dart';
import 'camera_dialog.dart';
import 'camera_reboot.dart';
import 'group_dialog.dart';
import 'peer_dialog.dart';
import 'widgets.dart';

enum _PeerAction { edit, reboot, remove }

enum _GroupAction { edit, leave }

/// Channel selector: "Everyone" plus every known peer. The selected entry is
/// who CONNECT opens a two-way line with; tapping another one switches.
///
/// Every peer that has been seen stays in the list across restarts, even
/// when offline. Every peer has a ⋮ menu to edit or remove it (online or
/// offline).
class PeerList extends StatelessWidget {
  const PeerList({
    super.key,
    required this.service,
    required this.onAddPeer,
    this.cameras = false,
  });

  final IntercomService service;
  final VoidCallback onAddPeer;

  /// The camera list instead (cameras are never in the peer list).
  final bool cameras;

  bool _isCamera(PeerEntry e) =>
      e.peerId != null && service.camera(e.peerId!) != null;

  @override
  Widget build(BuildContext context) {
    if (cameras) return _cameraList(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final entries = service.entries.where((e) => !_isCamera(e)).toList();
        final online = entries.where((e) => e.online).length;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _everyone(context, online),
            const Divider(indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Groups',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _newGroup(context),
                    icon: const Icon(Icons.group_add, size: 18),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            if (service.groups.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Make a group so several peers can talk together.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            for (final g in service.groups) _groupTile(context, g),
            const Divider(indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entries.isEmpty
                          ? 'Peers'
                          : 'Peers · $online online of ${entries.length}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onAddPeer,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add peer'),
                  ),
                ],
              ),
            ),
            if (entries.isEmpty) _empty(context),
            for (final e in entries) _tile(context, e),
          ],
        );
      },
    );
  }

  Widget _cameraList(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final entries = service.entries.where(_isCamera).toList();
        final online = entries.where((e) => e.online).length;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entries.isEmpty
                          ? 'Cameras'
                          : 'Cameras · $online online of ${entries.length}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _addCamera(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add camera'),
                  ),
                ],
              ),
            ),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No cameras yet. Add a TP-Link Tapo or another camera that '
                  'streams RTSP to watch it, and (Tapo) talk through it.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            for (final e in entries) _tile(context, e),
          ],
        );
      },
    );
  }

  Widget _everyone(BuildContext context, int online) {
    final scheme = Theme.of(context).colorScheme;
    final selected = service.target is EveryoneTarget;
    final conv = service.conversation;
    final groupActive =
        conv != null && conv.group && conv.groupId == null && conv.outgoing;
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.tertiaryContainer,
        foregroundColor: scheme.onTertiaryContainer,
        child: const Icon(Icons.campaign),
      ),
      title: const Text('Everyone'),
      subtitle: Text(
        online == 0
            ? 'Nobody online yet'
            : 'Talk to all $online online peer${online == 1 ? '' : 's'}',
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: groupActive
            ? const Icon(Icons.call, color: Colors.green)
            : _radio(selected),
      ),
      onTap: () => service.selectTarget(const EveryoneTarget()),
    );
  }

  Widget _groupTile(BuildContext context, Group g) {
    final scheme = Theme.of(context).colorScheme;
    final target = GroupTarget(g.id);
    final selected = service.target == target;
    final others = g.members.keys.where((id) => id != service.selfId).toList();
    final online = others.where((id) => service.peer(id)?.online ?? false);
    final conv = service.conversation;
    final inCall = conv != null && conv.groupId == g.id;
    final names = others.map(service.displayName).join(', ');
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: const Icon(Icons.groups),
      ),
      title: Text(g.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        inCall && conv.isConnected
            ? 'In call · ${service.participants.length + 1} talking'
            : '${online.length} of ${others.length} online · $names',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inCall)
            const Icon(Icons.call, color: Colors.green)
          else
            _radio(selected),
          PopupMenuButton<_GroupAction>(
            tooltip: 'Group options',
            icon: const Icon(Icons.more_vert),
            onSelected: (a) => switch (a) {
              _GroupAction.edit => _editGroup(context, g),
              _GroupAction.leave => _leaveGroup(context, g),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _GroupAction.edit,
                child: ListTile(
                  leading: Icon(Icons.edit),
                  title: Text('Edit / invite…'),
                ),
              ),
              PopupMenuItem(
                value: _GroupAction.leave,
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Leave group'),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () => service.selectTarget(target),
      onLongPress: () => _editGroup(context, g),
    );
  }

  Future<void> _newGroup(BuildContext context) async {
    final r = await showGroupDialog(context, service: service);
    if (r == null) return;
    final g = service.createGroup(r.name, r.members);
    service.selectTarget(GroupTarget(g.id));
    if (context.mounted) {
      _snack(context, 'Group ${g.name} created. Members get it too.');
    }
  }

  Future<void> _editGroup(BuildContext context, Group g) async {
    final r = await showGroupDialog(context, service: service, group: g);
    if (r == null) return;
    service.updateGroup(g.id, name: r.name, memberIds: r.members);
  }

  Future<void> _leaveGroup(BuildContext context, Group g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Leave ${g.name}?'),
        content: const Text(
          'It is removed from your list and the other members are told. '
          'A member can invite you again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok == true) service.leaveGroup(g.id);
  }

  Widget _tile(BuildContext context, PeerEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final id = e.peerId;
    final selected = id != null && service.target == PeerTarget(id);
    final state = id == null ? null : service.memberState(id);
    final muted = e.online ? null : scheme.onSurface.withValues(alpha: 0.45);

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.6),
      leading: PeerAvatar(name: e.name, online: e.online),
      title: Row(
        children: [
          Flexible(
            child: Text(
              e.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted),
            ),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          Icon(platformIcon(e.platform), size: 14, color: muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              switch (state) {
                MemberState.connected when service.isReconnecting(id!) =>
                  'Reconnecting…',
                MemberState.connected when service.isSpeaking(id!) =>
                  'Speaking…',
                MemberState.connected
                    when service.cameraCanTalk(id!) == false =>
                  'Connected · listen only',
                MemberState.connected when service.routeTo(id!) == 'internet' =>
                  'Connected · 🌐 internet',
                MemberState.connected => 'Connected',
                MemberState.calling => 'Calling…',
                MemberState.ringing => 'Wants to talk',
                null when e.live?.outdated ?? false =>
                  'Needs update (no encryption)',
                null when e.live?.wrongPassword ?? false =>
                  'Different intercom password',
                null when _isCamera(e) => _cameraInfo(e),
                null => e.online ? _hosts(e) : 'Offline · ${_hosts(e)}',
              },
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == MemberState.connected && service.isSpeaking(id!))
            const Icon(Icons.graphic_eq, color: Colors.green)
          else if (state != null)
            Icon(switch (state) {
              MemberState.connected => Icons.call,
              MemberState.calling => Icons.phone_forwarded,
              MemberState.ringing => Icons.ring_volume,
            }, color: Colors.green)
          else if (e.online)
            _radio(selected),
          _menu(context, e),
        ],
      ),
      onTap: () {
        if (e.online && id != null) {
          service.selectTarget(PeerTarget(id));
        } else {
          _snack(context, '${e.name} is offline');
        }
      },
      onLongPress: () => _edit(context, e),
    );
  }

  /// "Tapo · 192.168.1.50", "RTSP · gate.local", "Offline · …".
  String _cameraInfo(PeerEntry e) {
    final cam = service.camera(e.peerId!)!;
    final text = '${cam.isTapo ? 'Tapo' : 'RTSP'} · ${cam.host}';
    return e.online ? text : 'Offline · $text';
  }

  /// "192.168.1.5" or, with an alternate address, "192.168.1.5 · 100.64.0.7".
  static String _hosts(PeerEntry e) {
    final live = e.live;
    // Known only through the relays: no address to show.
    if (live != null && live.internet && live.address.address == '0.0.0.0') {
      return '🌐 Internet';
    }
    final alt = e.altHost;
    final hosts = alt.isEmpty || alt == e.host ? e.host : '${e.host} · $alt';
    return live != null && live.internet ? '$hosts · 🌐' : hosts;
  }

  Widget _menu(BuildContext context, PeerEntry e) {
    final cam = e.peerId == null ? null : service.camera(e.peerId!);
    return PopupMenuButton<_PeerAction>(
      tooltip: 'Peer options',
      icon: const Icon(Icons.more_vert),
      onSelected: (a) => switch (a) {
        _PeerAction.edit => _edit(context, e),
        _PeerAction.reboot => confirmRebootCamera(context, service, cam!),
        _PeerAction.remove => _remove(context, e),
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _PeerAction.edit,
          child: ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Edit…'),
          ),
        ),
        if (cam != null && cam.isTapo)
          const PopupMenuItem(
            value: _PeerAction.reboot,
            child: ListTile(
              leading: Icon(Icons.restart_alt),
              title: Text('Reboot camera'),
            ),
          ),
        const PopupMenuItem(
          value: _PeerAction.remove,
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Remove'),
          ),
        ),
      ],
    );
  }

  Future<void> _addCamera(BuildContext context) async {
    final cam = await showCameraDialog(context, service: service);
    if (cam != null && context.mounted) {
      _snack(context, '${cam.name} added');
    }
  }

  Future<void> _edit(BuildContext context, PeerEntry e) async {
    final camera = e.peerId == null ? null : service.camera(e.peerId!);
    if (camera != null) {
      await showCameraDialog(context, service: service, camera: camera);
      return;
    }
    final saved = e.saved;
    if (saved == null) {
      // Discovered peer: a name or an alternate address saves it.
      final r = await showPeerDialog(
        context,
        title: 'Edit peer',
        label: '',
        nameHint: e.name,
        host: e.host,
        port: e.port,
        hostEditable: false,
      );
      if (r == null) return;
      service.saveLivePeer(e.live!.id, label: r.label, altHost: r.altHost);
      return;
    }
    final r = await showPeerDialog(
      context,
      title: 'Edit peer',
      label: saved.label,
      nameHint: e.live?.name,
      host: saved.host,
      port: saved.port,
      altHost: saved.altHost,
    );
    if (r == null || !context.mounted) return;
    try {
      final addressChanged = r.host != saved.host || r.port != saved.port;
      final online = await service.updateSavedPeer(
        saved.key,
        label: r.label,
        host: r.host,
        port: r.port,
        altHost: r.altHost,
      );
      if (addressChanged && !online && context.mounted) {
        _snack(
          context,
          'Saved. ${r.host}:${r.port} is not reachable right now — '
          'will keep trying.',
        );
      }
    } on ArgumentError catch (err) {
      if (context.mounted) _snack(context, '${err.message}', error: true);
    }
  }

  Future<void> _remove(BuildContext context, PeerEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${e.name}?'),
        content: Text(
          e.platform == 'camera'
              ? 'The camera and its passwords are removed from this device.'
              : 'It is removed from the list and any call with it ends. If '
                    'it is still on the network it can show up again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    service.removePeer(e);
    if (context.mounted) _snack(context, '${e.name} removed');
  }

  void _snack(BuildContext context, String msg, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  Widget _radio(bool selected) => Icon(
    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
  );

  Widget _empty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 12),
          const Text(
            'Looking for other intercoms on this network…\n'
            'Start the app on another device on the same Wi-Fi/LAN.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onAddPeer,
            icon: const Icon(Icons.add_link),
            label: const Text('Add peer by IP'),
          ),
        ],
      ),
    );
  }
}
