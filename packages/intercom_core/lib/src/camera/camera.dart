/// IP cameras (TP-Link Tapo) as intercom stations: hear the camera's
/// microphone and talk through its speaker.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'g711.dart';
import 'mpegts.dart';
import 'rtsp_client.dart';
import 'tapo_client.dart';

/// A camera the user added.
class SavedCamera {
  SavedCamera({
    required this.key,
    required this.name,
    required this.host,
    this.cloudPassword = '',
    this.rtspUser = '',
    this.rtspPassword = '',
    this.port = 8800,
    this.rtspPort = 554,
  });

  final String key;
  final String name;

  /// IP address of the camera.
  final String host;

  /// Password of the TP-Link (Tapo app) account: listen and talk.
  final String cloudPassword;

  /// The "camera account" set in the Tapo app: listen only (RTSP), used
  /// when the camera refuses the cloud password.
  final String rtspUser, rtspPassword;

  final int port, rtspPort;

  /// The id this camera has as a peer.
  String get peerId => 'cam-$key';

  static bool isCameraId(String id) => id.startsWith('cam-');

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'host': host,
    'cloudPassword': cloudPassword,
    'rtspUser': rtspUser,
    'rtspPassword': rtspPassword,
    if (port != 8800) 'port': port,
    if (rtspPort != 554) 'rtspPort': rtspPort,
  };

  static SavedCamera? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['key'], host = j['host'];
    if (key is! String || host is! String) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    return SavedCamera(
      key: key,
      name: s('name'),
      host: host,
      cloudPassword: s('cloudPassword'),
      rtspUser: s('rtspUser'),
      rtspPassword: s('rtspPassword'),
      port: j['port'] is int ? j['port'] as int : 8800,
      rtspPort: j['rtspPort'] is int ? j['rtspPort'] as int : 554,
    );
  }
}

class CameraException implements Exception {
  CameraException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What [CameraSession.start] managed to set up.
class CameraStatus {
  CameraStatus({required this.talk, this.talkProblem, required this.via});

  /// We can talk through the camera's speaker.
  final bool talk;

  /// Why not, when [talk] is false.
  final String? talkProblem;

  /// 'tapo' or 'rtsp': how we hear it.
  final String via;

  String get summary => talk
      ? 'Listen and talk work'
      : 'Listen only: ${talkProblem ?? 'talking is not available'}';
}

/// A running audio connection with one camera, in the intercom's own
/// format (16 kHz PCM both ways).
class CameraSession {
  CameraSession(this.camera, {required this.onAudio, required this.onClosed});

  final SavedCamera camera;
  final void Function(Int16List pcm16k) onAudio;

  /// The camera's stream ended on its own.
  final void Function(Object? error) onClosed;

  TapoClient? _tapo;
  RtspAudioClient? _rtsp;
  final Upsampler2 _up = Upsampler2();
  bool _closed = false;
  CameraStatus? status;

  DateTime get lastData => _tapo?.lastData ?? _rtsp?.lastData ?? DateTime.now();

  void _g711(Uint8List payload, {required bool alaw, required int rate}) {
    if (_closed) return;
    final pcm = alaw ? alawDecode(payload) : ulawDecode(payload);
    onAudio(rate == 16000 ? pcm : _up.process(pcm));
  }

  /// Connects: the Tapo stream (listen, then talk) first, RTSP (listen
  /// only) when that isn't possible. Throws [CameraException] if the
  /// camera can't even be heard.
  Future<CameraStatus> start() async {
    String? tapoProblem;
    if (camera.cloudPassword.isNotEmpty) {
      final tapo = TapoClient(
        host: camera.host,
        port: camera.port,
        cloudPassword: camera.cloudPassword,
        onAudio: (a) => _g711(
          a.payload,
          alaw: a.streamType == streamTypePcmaTapo,
          rate: a.streamType == streamTypePcmuTapo ? 16000 : 8000,
        ),
        onClosed: (e) {
          if (!_closed) onClosed(e);
        },
      );
      try {
        await tapo.start().timeout(const Duration(seconds: 10));
        _tapo = tapo;
        String? talkProblem;
        try {
          await tapo.startTalk().timeout(const Duration(seconds: 10));
        } catch (e) {
          talkProblem = _text(e);
        }
        if (_closed) tapo.close();
        return status = CameraStatus(
          talk: tapo.canTalk,
          talkProblem: talkProblem,
          via: 'tapo',
        );
      } catch (e) {
        tapo.close();
        tapoProblem = _text(e);
      }
    } else {
      tapoProblem = 'no cloud password set';
    }

    if (camera.rtspUser.isEmpty) {
      throw CameraException(
        camera.cloudPassword.isEmpty
            ? 'Enter the cloud password or a camera account'
            : tapoProblem,
      );
    }
    final rtsp = RtspAudioClient(
      host: camera.host,
      port: camera.rtspPort,
      username: camera.rtspUser,
      password: camera.rtspPassword,
      onAudio: _g711,
      onClosed: (e) {
        if (!_closed) onClosed(e);
      },
    );
    try {
      await rtsp.start().timeout(const Duration(seconds: 10));
    } catch (e) {
      rtsp.close();
      throw CameraException(
        camera.cloudPassword.isEmpty
            ? _text(e)
            : '$tapoProblem; camera account: ${_text(e)}',
      );
    }
    _rtsp = rtsp;
    if (_closed) rtsp.close();
    return status = CameraStatus(
      talk: false,
      talkProblem: tapoProblem,
      via: 'rtsp',
    );
  }

  static String _text(Object e) => switch (e) {
    TimeoutException() => 'the camera did not answer',
    // Not the full text: it ends with our own (local) port, which confuses.
    SocketException(:final osError?) => osError.message,
    _ => e.toString().replaceFirst('SocketException: ', ''),
  };

  /// Plays 16 kHz PCM through the camera's speaker (if it can talk).
  void sendAudio(Int16List pcm16k) {
    final tapo = _tapo;
    if (_closed || tapo == null || !tapo.canTalk) return;
    tapo.sendAudio(alawEncode(downsample2(pcm16k)));
  }

  void close() {
    _closed = true;
    _tapo?.close();
    _rtsp?.close();
  }
}
