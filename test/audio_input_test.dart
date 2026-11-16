import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_intercom/src/audio_routes.dart';

void main() {
  test('microphones from Android; the choice picks the device id', () {
    final routes = AudioRoutes();
    final set = <int>[];
    var reopened = 0;
    routes
      ..setNativeMic = set.add
      ..onMicChanged = () => reopened++;

    Map<String, Object?> state({bool active = true, String usbId = '7'}) => {
      'active': active,
      'current': '1',
      'routes': [
        {'id': '1', 'type': 'speaker', 'name': 'Speaker'},
        {'id': '9', 'type': 'bluetooth', 'name': 'Buds'},
      ],
      'inputs': [
        {'id': '3', 'type': 'builtin', 'name': 'Built-in microphone'},
        {'id': usbId, 'type': 'usb', 'name': 'Yeti (USB)'},
        {'id': '9', 'type': 'bluetooth', 'name': 'Buds (Bluetooth)'},
      ],
    };

    routes.apply(state());
    expect(routes.inputs.map((i) => i.type), ['builtin', 'usb', 'bluetooth']);
    expect(set, isEmpty); // Automatic: nothing forced.

    routes.setMicChoice('usb|Yeti (USB)');
    expect(set.last, 7);
    expect(reopened, 1);

    // Plugged in again with a new id: still found by its name.
    routes.apply(state(usbId: '12'));
    expect(set.last, 12);

    // Bluetooth: the native device is left to Android (the Bluetooth
    // route carries the mic).
    routes.setMicChoice('bluetooth|Buds (Bluetooth)');
    expect(set.last, 0);

    routes.setMicChoice('');
    expect(routes.chosenInput, isNull);
  });
}
