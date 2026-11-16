import 'dart:io';

import 'package:flutter/material.dart';

import '../src/audio_routes.dart';
import '../src/intercom_service.dart';
import '../src/settings.dart';

/// The "Microphone" (and on desktop "Sound output") choice in Settings.
/// A change applies at once, also during a call, and is remembered.
///
/// Desktop lists the system's devices by name. Android lists the phone's
/// microphones (built-in, wired 3.5 mm, USB, Bluetooth); its sound output
/// is chosen with the output button during a call.
class AudioDevicePicker extends StatefulWidget {
  const AudioDevicePicker({
    super.key,
    required this.service,
    required this.settings,
  });

  final IntercomService service;
  final Settings settings;

  /// Platforms where the app itself can choose among named devices.
  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  State<AudioDevicePicker> createState() => _AudioDevicePickerState();
}

class _AudioDevicePickerState extends State<AudioDevicePicker> {
  List<AudioDevice> _mics = const [];
  List<AudioDevice> _speakers = const [];

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      AudioRoutes.instance.refresh();
    } else if (AudioDevicePicker.supported) {
      _mics = widget.service.audioDevices(AudioDeviceKind.microphone);
      _speakers = widget.service.audioDevices(AudioDeviceKind.speaker);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return ListenableBuilder(
        listenable: AudioRoutes.instance,
        builder: (context, _) {
          final routes = AudioRoutes.instance;
          return _dropdown(
            label: 'Microphone',
            icon: Icons.mic,
            value: routes.micChoice,
            defaultLabel: 'Automatic (follows the sound output)',
            items: {for (final i in routes.inputs) i.key: i.name},
            helper: routes.chosenInput?.type == 'bluetooth'
                ? 'A Bluetooth microphone also moves the sound to that '
                      'Bluetooth device.'
                : null,
            onChanged: (v) {
              widget.settings.micDevice = v;
              routes.setMicChoice(v);
            },
          );
        },
      );
    }
    if (!AudioDevicePicker.supported) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dropdown(
          label: 'Microphone',
          icon: Icons.mic,
          value: widget.settings.micDevice,
          defaultLabel: 'System default',
          items: {for (final d in _mics) d.name: d.name},
          onChanged: (v) {
            widget.settings.micDevice = v;
            widget.service.selectAudioDevice(AudioDeviceKind.microphone, v);
            setState(() {});
          },
        ),
        const SizedBox(height: 12),
        _dropdown(
          label: 'Sound output',
          icon: Icons.volume_up,
          value: widget.settings.speakerDevice,
          defaultLabel: 'System default',
          items: {for (final d in _speakers) d.name: d.name},
          onChanged: (v) {
            widget.settings.speakerDevice = v;
            widget.service.selectAudioDevice(AudioDeviceKind.speaker, v);
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _dropdown({
    required String label,
    required IconData icon,
    required String value,
    required String defaultLabel,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
    String? helper,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        helperText: helper,
        helperMaxLines: 2,
      ),
      items: [
        DropdownMenuItem(value: '', child: Text(defaultLabel)),
        for (final e in items.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
        // Chosen earlier but unplugged now: keep showing it.
        if (value.isNotEmpty && !items.containsKey(value))
          DropdownMenuItem(
            value: value,
            child: Text(
              '${value.split('|').last} (not connected)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => onChanged(v ?? ''),
    );
  }
}
