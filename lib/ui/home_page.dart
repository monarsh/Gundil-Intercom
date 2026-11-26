import '../src/app_updater.dart';
import 'updates.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../src/autostart.dart';
import '../src/camera_viewer.dart';
import '../src/intercom_service.dart';
import '../src/platform_bridge.dart';
import '../src/settings.dart';
import '../src/video_call.dart';
import '../src/window_bridge.dart';
import 'intercom_panel.dart';
import 'audio_device_picker.dart';
import 'backup_dialog.dart';
import 'camera_stream.dart';
import 'pairing.dart';
import 'peer_dialog.dart';
import 'contacts_pane.dart';
import 'debug_log_page.dart';
import 'video_view.dart';
import 'volume_sheet.dart';

/// Main window.
///
/// * Wide screens (desktop, tablets): peer list on the left, the connect /
///   hang-up controls on the right.
/// * Narrow screens (phones): peer list on top, controls at the bottom.
///
/// Pick Everyone or one peer and press CONNECT: a two-way audio line opens
/// until either side hangs up.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.service,
    required this.settings,
    this.updater,
  });

  final IntercomService service;
  final Settings settings;
  final AppUpdater? updater;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const double _wideBreakpoint = 720;

  late final StreamSubscription<IntercomEvent> _eventSub;
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();
  final FocusNode _focus = FocusNode(debugLabel: 'ptt-keyboard');

  IntercomService get service => widget.service;

  late final VideoCall _video = VideoCall(
    service,
    hd: widget.settings.videoHd,
    onHdChanged: (v) => widget.settings.videoHd = v,
  )..onError = (m) => _showMessage(m, error: true);

  /// The IP camera picture (camera on/off button).
  final CameraViewer _viewer = CameraViewer();
  TalkTarget? _lastTarget;

  /// The picture belongs to the selected camera: it goes off when another
  /// entry is selected or the camera is removed.
  void _followSelection() {
    final target = service.target;
    final id = _viewer.showing;
    if (id != null &&
        (service.camera(id) == null ||
            (_lastTarget != null && target != _lastTarget))) {
      _viewer.stop();
    }
    _lastTarget = target;
  }

  @override
  void initState() {
    super.initState();
    _lastTarget = service.target;
    service.addListener(_followSelection);
    WidgetsBinding.instance.addObserver(this);
    _eventSub = service.events.listen((e) {
      if (e.kind == IntercomEventKind.pairRequest && e.peerId != null) {
        if (mounted) showPairRequestDialog(context, service, e.peerId!);
        return;
      }
      _showMessage(e.message, error: e.error);
    });
    _updateSub = widget.updater?.manager.changes.listen((_) => _onUpdate());
  }

  StreamSubscription<void>? _updateSub;
  String? _announced;

  /// The update server offers a version: say so once (with "ask"; with
  /// "auto" it installs by itself, unless this platform can't).
  void _onUpdate() {
    final u = widget.updater;
    final o = u?.manager.offer;
    if (u == null || o == null || !mounted) return;
    if (u.manager.state != UpdateState.available || _announced == o.version) {
      return;
    }
    if (o.mode == 'auto' && u.manager.installable) return;
    _announced = o.version;
    _messenger.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          o.downgrade
              ? 'Your administrator asks to go back to version ${o.version}.'
              : 'Gundil Intercom ${o.version} is available.',
        ),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: u.manager.installable ? 'Install' : 'Details',
          onPressed: () => u.manager.installable
              ? u.manager.installNow()
              : showUpdatesDialog(context, u),
        ),
      ),
    );
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    service.removeListener(_followSelection);
    _viewer.dispose();
    _video.dispose();
    _eventSub.cancel();
    _updateSub?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A two-way conversation deliberately continues in the background
    // (tray on Windows, background mode on Android).
    // On Android the engine may keep running without a window (background
    // mode), so only desktop shuts down when the window goes away.
    if (state == AppLifecycleState.detached && !Platform.isAndroid) {
      service.shutdown();
    }
  }

  // ---------------------------------------------------------------- dialogs

  Future<void> _addPeerDialog() async {
    final r = await showPeerDialog(
      context,
      title: 'Add peer',
      confirmText: 'Add',
    );
    _focus.requestFocus();
    if (r == null || !mounted) return;
    try {
      final online = await service.addSavedPeer(
        host: r.host,
        port: r.port,
        label: r.label,
        altHost: r.altHost,
      );
      final name = r.label.isEmpty ? '${r.host}:${r.port}' : r.label;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            online
                ? 'Connected to $name'
                : 'Saved $name. It is offline right now — '
                      'it will connect when it comes online.',
          ),
        ),
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text('${e.message}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _settingsDialog() async {
    final nameCtl = TextEditingController(text: service.name);
    final passwordCtl = TextEditingController(text: service.password);
    var showPassword = false;
    final autostartWas = await Autostart.isEnabled();
    var autostart = autostartWas;
    final trayWas = widget.settings.minimizeToTray;
    final trayAvailable = await WindowBridge.trayAvailable();
    var autoAnswer = service.autoAnswer;
    var echo = service.echoSuppression;
    var tray = trayWas;
    final backgroundWas = await PlatformBridge.getBackground();
    var background = backgroundWas;
    final bootWas = await PlatformBridge.getStartOnBoot();
    var boot = bootWas;
    var internet = service.internetMode;
    var share = service.shareCameras;
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Settings'),
          scrollable: true,
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Device name shown to peers',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordCtl,
                  obscureText: !showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Intercom password (optional)',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: showPassword ? 'Hide' : 'Show',
                      icon: Icon(
                        showPassword ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setLocal(() => showPassword = !showPassword),
                    ),
                    helperText:
                        'Calls are always encrypted. With a password, only '
                        'intercoms with the same password can connect: set '
                        'it on every device. Without one, anyone on your '
                        'Wi-Fi can connect, and Internet calls use the home '
                        'key (Pairing).',
                    helperMaxLines: 5,
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                if (Platform.isAndroid || AudioDevicePicker.supported) ...[
                  const SizedBox(height: 12),
                  AudioDevicePicker(
                    service: service,
                    settings: widget.settings,
                  ),
                ],
                if (Autostart.supported) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      Platform.isWindows
                          ? 'Start with Windows'
                          : 'Start automatically at login',
                    ),
                    subtitle: Text(
                      Platform.isMacOS
                          ? 'Starts in the menu bar when you log in, ready '
                                'to receive (macOS 13 or later).'
                          : trayAvailable
                          ? 'Starts in the system tray when you sign in, '
                                'ready to receive.'
                          : 'Opens minimized when you log in, ready to '
                                'receive.',
                    ),
                    value: autostart,
                    onChanged: (v) => setLocal(() => autostart = v),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Answer automatically'),
                  subtitle: const Text(
                    'Incoming connections open at once, like an intercom. '
                    'Turn off to ring and accept/decline instead.',
                  ),
                  value: autoAnswer,
                  onChanged: (v) => setLocal(() => autoAnswer = v),
                ),
                if (!Platform.isAndroid)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Echo suppression'),
                    subtitle: const Text(
                      'Lowers your mic while the other side talks, so they '
                      "don't hear themselves. Turn off with a headset.",
                    ),
                    value: echo,
                    onChanged: (v) => setLocal(() => echo = v),
                  ),
                if (trayAvailable)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      Platform.isMacOS
                          ? 'Keep running in the menu bar'
                          : 'Minimize to tray',
                    ),
                    subtitle: Text(
                      Platform.isMacOS
                          ? 'Minimize and the close button hide the window '
                                'to the menu bar, and it keeps receiving. '
                                'Click the menu bar icon to open it, or Quit.'
                          : Platform.isWindows
                          ? 'Minimize and the close button keep it running in '
                                'the notification area. Right-click the tray '
                                'icon > Exit to quit.'
                          : 'Minimize and the close button keep it running in '
                                "the tray. Use the tray icon's menu to open "
                                'it, or Exit to quit.',
                    ),
                    value: tray,
                    onChanged: (v) => setLocal(() => tray = v),
                  ),
                if (PlatformBridge.hasBackgroundMode) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Run in background'),
                    subtitle: Text(
                      Platform.isAndroid
                          ? 'Keeps receiving when the app is closed or the '
                                'screen is off. Shows a notification.'
                          : 'Keeps answering calls with the screen locked. '
                                'Plays silence in the background, so it uses '
                                'some battery.',
                    ),
                    value: background,
                    onChanged: (v) => setLocal(() {
                      background = v;
                      if (!v) boot = false;
                    }),
                  ),
                ],
                if (Platform.isAndroid) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start when phone turns on'),
                    subtitle: const Text('Needs "Run in background".'),
                    value: boot,
                    onChanged: background
                        ? (v) => setLocal(() => boot = v)
                        : null,
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Internet calls (STUN + UDP hole punching)',
                  ),
                  subtitle: Text(
                    'Reach your intercoms from anywhere, without a VPN. '
                    'Uses public Nostr relays and STUN servers; calls go '
                    'directly between the devices, encrypted. Uses the '
                    'intercom password (at least '
                    '${IntercomCore.internetMinPassword} characters), or the '
                    'home key when there is none: pair each device once.',
                  ),
                  value: internet,
                  onChanged: (v) => setLocal(() => internet = v),
                ),
                if (internet)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: const Text('Pairing'),
                    subtitle: Text(
                      passwordCtl.text.isNotEmpty
                          ? 'Uses the intercom password'
                          : service.homeKey == null
                          ? 'Not paired yet: tap to pair'
                          : 'Paired · home key ${service.homeKey!.fingerprint}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await showPairingDialog(ctx, service);
                      setLocal(() {});
                    },
                  ),
                if (internet)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Share home cameras over the internet'),
                    subtitle: const Text(
                      'Turn on for the intercom that stays at home, on the '
                      "cameras' Wi-Fi: your other intercoms can "
                      'then watch, hear and talk to the cameras from outside '
                      'through it. Only devices on this LAN are reachable.',
                    ),
                    value: share,
                    onChanged: (v) => setLocal(() => share = v),
                  ),
                // Why it can't run, next to the settings that fix it. The
                // relays and NAT are in ⋮ More → Check network.
                if (internet &&
                    service.internetMode &&
                    service.internetProblem != null)
                  Text(
                    'Not running: ${service.internetProblem}',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      service.autoAnswer = autoAnswer;
      widget.settings.autoAnswer = autoAnswer;
      service.echoSuppression = echo;
      widget.settings.echoSuppression = echo;
      if (tray != trayWas) {
        widget.settings.minimizeToTray = tray;
        await WindowBridge.setTrayEnabled(tray);
      }
      if (background != backgroundWas) {
        await _setBackground(background);
      }
      if (boot != bootWas) await PlatformBridge.setStartOnBoot(boot);
      if (autostart != autostartWas) {
        final now = await Autostart.setEnabled(autostart);
        if (now != autostart && mounted) {
          _messenger.currentState?.showSnackBar(
            SnackBar(
              content: Text(
                Platform.isMacOS
                    ? 'Could not change the login item. It needs macOS 13 '
                          'or later; check System Settings > General > '
                          'Login Items.'
                    : 'Could not change the autostart setting',
              ),
            ),
          );
        }
      }
      final name = nameCtl.text.trim();
      if (name.isNotEmpty) {
        service.name = name;
        widget.settings.name = name;
      }
      final password = passwordCtl.text;
      if (password != service.password) {
        widget.settings.password = password;
        await service.setPassword(password);
        if (mounted) {
          _showMessage(
            password.isEmpty
                ? 'Password removed. Calls stay encrypted.'
                : 'Password set. Use the same one on every intercom.',
          );
        }
      }
      if (share != service.shareCameras) {
        await service.setShareCameras(share);
        widget.settings.shareCameras = share;
      }
      if (internet != service.internetMode) {
        if (internet &&
            service.password.isEmpty &&
            service.homeKey == null &&
            mounted) {
          await showPairingDialog(context, service);
        }
        try {
          await service.setInternetMode(internet);
          if (mounted && internet) {
            _showMessage(
              service.internetUsesPassword
                  ? 'Internet calls on. Turn them on on the other intercoms '
                        'too (same password).'
                  : 'Internet calls on. Pair and turn them on on the other '
                        'intercoms too.',
            );
          }
        } on ArgumentError catch (e) {
          if (mounted) _showMessage('${e.message}');
        }
        widget.settings.internetMode = service.internetMode;
      }
    }
    nameCtl.dispose();
    passwordCtl.dispose();
    _focus.requestFocus();
  }

  /// More → This device: version, addresses, port and discovery.
  Future<void> _deviceInfoDialog() async {
    final addrs = await _localAddresses();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This device'),
        content: SelectableText(
          'Gundil Intercom $appVersion\n'
          'Name: ${service.name}\n'
          'Addresses: ${addrs.isEmpty ? 'none' : addrs.join(', ')}\n'
          'TCP port: ${service.listenPort}\n'
          'Discovery: ${service.discoveryRunning ? 'UDP $discoveryPort broadcast' : 'off'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// More → Check network: relays, STUN (NAT type) and the public address.
  Future<void> _checkNetworkDialog() async {
    String? result;
    var checking = false;
    var open = true;
    Future<void> run(StateSetter setLocal) async {
      setLocal(() {
        checking = true;
        result = null;
      });
      final r = service.internetMode ? await service.checkInternet() : null;
      if (!open) return; // Closed while checking.
      setLocal(() {
        checking = false;
        result = !service.internetMode
            ? 'Internet calls are off: turn them on in Settings first.'
            : r == null && service.internetProblem != null
            ? 'Internet calls are not running: ${service.internetProblem}'
            : _describeCheck(r);
      });
    }

    var started = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          if (!started) {
            started = true;
            Future.microtask(() => run(setLocal));
          }
          return AlertDialog(
            title: const Text('Check network'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (checking) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text(
                    'Connecting to the relays and asking STUN servers for '
                    'the NAT type. Takes about 10 seconds.',
                  ),
                ] else if (result != null)
                  SelectableText(result!),
              ],
            ),
            actions: [
              TextButton(
                onPressed: checking ? null : () => run(setLocal),
                child: const Text('Check again'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    open = false;
  }

  static String _describeCheck(NetworkCheck? r) {
    if (r == null) return 'Internet calls are not running.';
    final nat = switch (r.nat) {
      NatType.cone ||
      NatType.open => 'direct calls likely (your NAT keeps one public port)',
      NatType.symmetric =>
        'direct calls may fail (strict NAT: a new public port per '
            'destination)',
      NatType.unknown => 'unknown (no STUN server answered)',
    };
    return 'Relays: ${r.relays} of ${r.relaysTotal} connected\n'
        'NAT: $nat\n'
        'Public address: ${r.publicAddress ?? 'unknown'}';
  }

  /// Turns background mode on/off, asking for what it needs (Android).
  Future<void> _setBackground(bool on) async {
    if (!on || !Platform.isAndroid) {
      await PlatformBridge.setBackground(on);
      return;
    }
    // Android 13+: without this the notification is hidden (the service
    // still runs).
    await PlatformBridge.requestNotifications();
    await PlatformBridge.setBackground(true);
    if (!await PlatformBridge.isIgnoringBatteryOptimizations()) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow unrestricted battery use?'),
          content: const Text(
            'To keep hearing other intercoms while the screen is off, Android '
            'must not put Gundil Intercom to sleep. On the next screen, choose '
            '"Allow".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok == true) await PlatformBridge.requestIgnoreBatteryOptimizations();
    }
  }

  /// Every IPv4 address with its network interface, e.g.
  /// "192.168.1.20 (wlan0)". The name tells what it is: on a phone with
  /// Wi-Fi and mobile data off, the carrier's VoLTE link (rmnet…, ims…,
  /// ccmni…) can still have one.
  static Future<List<String>> _localAddresses() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return [
        for (final i in ifaces)
          for (final a in i.addresses) '${a.address} (${i.name})',
      ];
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messenger,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideBreakpoint;
            return Scaffold(
              appBar: AppBar(
                // Room for the name and, below it, the version.
                toolbarHeight: 76,
                title: ListenableBuilder(
                  listenable: service,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gundil Intercom'),
                      Text(
                        'You are “${service.name}”',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'v$appVersion',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                actions: [
                  ListenableBuilder(
                    listenable: service,
                    builder: (context, _) => IconButton(
                      tooltip: 'Volume',
                      onPressed: () => showVolumeSheet(context, service),
                      icon: Icon(speakerIcon(service.speakerVolume)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: _settingsDialog,
                    icon: const Icon(Icons.settings),
                  ),
                  PopupMenuButton<void Function()>(
                    tooltip: 'More',
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _deviceInfoDialog,
                        child: const ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('This device'),
                          subtitle: Text('Version, addresses, ports'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _checkNetworkDialog,
                        child: const ListTile(
                          leading: Icon(Icons.network_check),
                          title: Text('Check network'),
                          subtitle: Text('Relays, NAT type, public address'),
                        ),
                      ),
                      if (widget.updater != null) ...[
                        PopupMenuItem(
                          value: () =>
                              showUpdatesDialog(context, widget.updater!),
                          child: ListTile(
                            leading: const Icon(Icons.system_update_outlined),
                            title: const Text('Updates'),
                            subtitle: Text(updateSummary(widget.updater!)),
                          ),
                        ),
                        const PopupMenuDivider(),
                      ],
                      PopupMenuItem(
                        value: () => BackupDialogs.export(context, service),
                        child: const ListTile(
                          leading: Icon(Icons.upload_file),
                          title: Text('Export list'),
                          subtitle: Text('Save peers and cameras to a file'),
                        ),
                      ),
                      PopupMenuItem(
                        value: () => BackupDialogs.import(context, service),
                        child: const ListTile(
                          leading: Icon(Icons.download),
                          title: Text('Import list'),
                          subtitle: Text('Add peers and cameras from a file'),
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: () => DebugLogPage.open(context, service),
                        child: const ListTile(
                          leading: Icon(Icons.bug_report_outlined),
                          title: Text('Debug log'),
                          subtitle: Text(
                            'What the app is doing, to report a problem',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              body: wide ? _wideBody() : _narrowBody(),
            );
          },
        ),
      ),
    );
  }

  /// Video takes the main area while anyone's camera is on (or an IP
  /// camera's picture).
  bool get _showVideo =>
      service.videoPeers.isNotEmpty || _video.on || _viewer.on;

  bool get _callVideo => service.videoPeers.isNotEmpty || _video.on;

  /// The IP camera's picture and/or the call's video.
  Widget _stage() {
    final camera = CameraStage(service: service, viewer: _viewer);
    final call = VideoStage(service: service, video: _video);
    if (!_viewer.on) return call;
    if (!_callVideo) return camera;
    return Column(
      children: [
        Expanded(child: camera),
        const SizedBox(height: 8),
        Expanded(child: call),
      ],
    );
  }

  Widget _wideBody() {
    return Row(
      children: [
        SizedBox(
          width: 340,
          child: ContactsPane(service: service, onAddPeer: _addPeerDialog),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([service, _video, _viewer]),
            builder: (context, _) {
              final panel = IntercomPanel(
                service: service,
                video: _video,
                viewer: _viewer,
                onMessage: _showMessage,
                showParticipants: !_showVideo,
              );
              if (!_showVideo) return Center(child: panel);
              return Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: _stage(),
                    ),
                  ),
                  panel,
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _narrowBody() {
    return ListenableBuilder(
      listenable: Listenable.merge([service, _video, _viewer]),
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: _showVideo
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: _stage(),
                  )
                : ContactsPane(service: service, onAddPeer: _addPeerDialog),
          ),
          if (!_showVideo) const Divider(height: 1),
          SafeArea(
            top: false,
            child: IntercomPanel(
              service: service,
              video: _video,
              viewer: _viewer,
              onMessage: _showMessage,
              compact: true,
              showParticipants: !_showVideo,
            ),
          ),
        ],
      ),
    );
  }
}
