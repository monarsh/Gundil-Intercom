import AVFoundation
import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GundilPlatform") {
      GundilPlatform.register(messenger: registrar.messenger())
    }
    // "Run in background" was on: keep running from the start.
    if BackgroundKeeper.shared.enabled { BackgroundKeeper.shared.start() }
  }
}

/// The "p2p_intercom/platform" channel on iOS (lib/src/platform_bridge.dart):
/// the microphone permission, call audio, "Run in background", and Wi-Fi /
/// mobile data and Low Power Mode for the battery saving; the rest is
/// Android-only.
enum GundilPlatform {
  static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "p2p_intercom/platform", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "requestMicrophone":
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async { result(granted) }
        }
      case "startCallAudio":
        BackgroundKeeper.shared.callStarted()
        EarDetection.shared.start()
        result(nil)
      case "stopCallAudio":
        EarDetection.shared.stop()
        BackgroundKeeper.shared.callEnded()
        result(nil)
      case "networkKind":
        result(PowerAndNetwork.shared.kind)
      case "lowPowerMode":
        result(ProcessInfo.processInfo.isLowPowerModeEnabled)
      case "getBackground":
        result(BackgroundKeeper.shared.enabled)
      case "setBackground":
        let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        BackgroundKeeper.shared.enabled = on
        if on { BackgroundKeeper.shared.start() } else { BackgroundKeeper.shared.stop() }
        result(BackgroundKeeper.shared.enabled)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
    PowerAndNetwork.shared.start()
  }
}

/// Battery saving (the engine's idle pace): whether the iPhone is on Wi-Fi
/// or mobile data, and whether Low Power Mode is on. Tells Dart when either
/// changes ("powerOrNetworkChanged"); it then asks "networkKind" and
/// "lowPowerMode".
final class PowerAndNetwork {
  static let shared = PowerAndNetwork()

  private let monitor = NWPathMonitor()
  private var started = false
  private var observer: NSObjectProtocol?
  private var lastKind = "none"
  private var lastLow = false

  /// "wifi", "mobile" or "none". Wi-Fi (or Ethernet) wins when both are up,
  /// as on Android; a VPN counts as the network it runs over.
  private(set) var kind = "none"

  func start() {
    guard !started else { return }
    started = true
    lastLow = ProcessInfo.processInfo.isLowPowerModeEnabled
    monitor.pathUpdateHandler = { [weak self] path in
      var k = "none"
      if path.status == .satisfied {
        let types = path.availableInterfaces.map { $0.type }
        if types.contains(.wifi) || types.contains(.wiredEthernet) {
          k = "wifi"
        } else if types.contains(.cellular) {
          k = "mobile"
        }
      }
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.kind = k
        if k != self.lastKind {
          self.lastKind = k
          self.changed()
        }
      }
    }
    monitor.start(queue: DispatchQueue(label: "gundil.network"))
    observer = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      let low = ProcessInfo.processInfo.isLowPowerModeEnabled
      if low != self.lastLow {
        self.lastLow = low
        self.changed()
      }
    }
  }

  private func changed() {
    GundilPlatform.channel?.invokeMethod("powerOrNetworkChanged", arguments: nil)
  }
}

/// Ear detection during a call, like the Phone app: held to the ear
/// (proximity sensor), audio on the loudspeaker or a Bluetooth device moves
/// to the earpiece, and iOS turns the screen off; taken away, it goes back
/// to that speaker / Bluetooth device. Wired headphones are left alone.
final class EarDetection {
  static let shared = EarDetection()

  private enum Back { case speaker, bluetooth(AVAudioSessionPortDescription?) }

  private var running = false
  private var back: Back?
  private var observer: NSObjectProtocol?
  private var pendingAway: DispatchWorkItem?

  /// Same as the audio library sets up (packages/intercom_audio): talk and
  /// listen, loudspeaker by default, Bluetooth headsets allowed.
  private let callOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]

  func start() {
    guard !running, UIDevice.current.userInterfaceIdiom == .phone else { return }
    running = true
    UIDevice.current.isProximityMonitoringEnabled = true
    observer = NotificationCenter.default.addObserver(
      forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.pendingAway?.cancel()
      if UIDevice.current.proximityState {
        self.toEar()
      } else {
        // Back only once it stays away a moment (no flapping).
        let work = DispatchWorkItem { [weak self] in self?.awayFromEar() }
        self.pendingAway = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
      }
    }
  }

  func stop() {
    guard running else { return }
    running = false
    pendingAway?.cancel()
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    observer = nil
    UIDevice.current.isProximityMonitoringEnabled = false
    if back != nil { awayFromEar() }
  }

  private func toEar() {
    guard back == nil else { return }
    let session = AVAudioSession.sharedInstance()
    guard let out = session.currentRoute.outputs.first?.portType else { return }
    do {
      switch out {
      case .builtInSpeaker:
        back = .speaker
        // Without "default to speaker" the call plays on the earpiece.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        try session.overrideOutputAudioPort(.none)
      case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
        let bt = session.currentRoute.inputs.first { $0.portType == .bluetoothHFP }
        back = .bluetooth(bt)
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        // Choosing the built-in microphone moves the call off Bluetooth,
        // onto the earpiece.
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
          try session.setPreferredInput(mic)
        }
        try session.overrideOutputAudioPort(.none)
      default:
        return // Earpiece already, or wired headphones.
      }
    } catch {
      NSLog("Ear detection: could not switch to the earpiece: \(error)")
    }
  }

  private func awayFromEar() {
    guard let previous = back else { return }
    back = nil
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: callOptions)
      switch previous {
      case .speaker:
        try session.setPreferredInput(nil)
        try session.overrideOutputAudioPort(.speaker)
      case .bluetooth(let port):
        let bt = port ?? session.availableInputs?.first { $0.portType == .bluetoothHFP }
        try session.setPreferredInput(bt)
      }
    } catch {
      NSLog("Ear detection: could not switch back: \(error)")
    }
  }
}

/// "Run in background" on iPhone. iOS keeps an app with the audio background
/// mode (Info.plist) running while it plays sound, so this plays a silent
/// loop, output only (no microphone indicator), and the intercom keeps
/// answering with the screen locked. Idle, the session mixes with other
/// apps, so their music keeps playing; during a call it takes the audio as
/// before. The audio library (packages/intercom_audio) owns the session and
/// its category: this only adds or removes "mix with others".
final class BackgroundKeeper {
  static let shared = BackgroundKeeper()

  private static let key = "gundil.background"
  private var player: AVAudioPlayer?
  private var running = false
  private var inCall = false
  private var observers: [NSObjectProtocol] = []

  /// Same as the audio library sets up: talk and listen, loudspeaker,
  /// Bluetooth headsets allowed.
  private let callOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]

  var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: BackgroundKeeper.key) }
    set { UserDefaults.standard.set(newValue, forKey: BackgroundKeeper.key) }
  }

  func start() {
    if !running {
      running = true
      observe()
    }
    configureSession()
    play()
  }

  func stop() {
    guard running else { return }
    running = false
    player?.stop()
    player = nil
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
    // Back to the library's own options; the session stays active (it's
    // the library's).
    if !inCall { setOptions(callOptions) }
  }

  func callStarted() {
    inCall = true
    if running { setOptions(callOptions) }
  }

  func callEnded() {
    inCall = false
    guard running else { return }
    configureSession()
    play()
  }

  private func configureSession() {
    setOptions(inCall ? callOptions : callOptions.union(.mixWithOthers))
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("Background: could not activate the audio session: \(error)")
    }
  }

  private func setOptions(_ options: AVAudioSession.CategoryOptions) {
    let session = AVAudioSession.sharedInstance()
    if session.category == .playAndRecord && session.categoryOptions == options { return }
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: options)
    } catch {
      NSLog("Background: could not set the audio session: \(error)")
    }
  }

  private func play() {
    if player == nil {
      do {
        let p = try AVAudioPlayer(data: BackgroundKeeper.silentWav())
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        player = p
      } catch {
        NSLog("Background: could not create the silent player: \(error)")
        return
      }
    }
    if player?.isPlaying == false { player?.play() }
  }

  private func observe() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self, self.running,
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      // A phone call, Siri or an alarm took the audio: start again once
      // it's over, whether or not iOS suggests resuming.
      if type == .ended {
        self.configureSession()
        self.play()
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.running else { return }
      self.player = nil
      self.configureSession()
      self.play()
    })
  }

  /// One second of silence: 16-bit mono PCM WAV at 8 kHz.
  private static func silentWav() -> Data {
    let rate: UInt32 = 8000
    let samples = Int(rate)
    let dataSize = UInt32(samples * 2)
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append("RIFF".data(using: .ascii)!)
    u32(36 + dataSize)
    d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    d.append("data".data(using: .ascii)!)
    u32(dataSize)
    d.append(Data(count: Int(dataSize)))
    return d
  }
}
