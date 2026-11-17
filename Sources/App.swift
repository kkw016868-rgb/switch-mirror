import UIKit
import AVFoundation

// 씬 기반 생명주기 — 없으면 최신 iPadOS가 호환 모드(세로 고정 창)로 띄움
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        app.isIdleTimerDisabled = true  // 화면 꺼짐 방지
        return true
    }

    func application(_ app: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = MirrorViewController()
        window?.makeKeyAndVisible()
    }
}

// 영상: AVCaptureVideoPreviewLayer = 디코딩→화면까지 하드웨어 경로, 버퍼링 없음 (가장 낮은 딜레이)
final class MirrorViewController: UIViewController {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "capture")
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let audio = AudioPassthrough()
    private let label = UILabel()

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        previewLayer.session = session
        previewLayer.videoGravity = Self.gravities[UserDefaults.standard.integer(forKey: "gravity") % Self.gravities.count]

        // 두 번 탭: 비율 유지(여백) → 꽉 채우기(좌우 잘림) → 늘리기(찌그러짐)
        let tap = UITapGestureRecognizer(target: self, action: #selector(cycleGravity))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        view.layer.addSublayer(previewLayer)

        label.text = "캡처보드를 연결하세요"
        label.textColor = .gray
        label.font = .systemFont(ofSize: 24)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // 소리는 캡처 세션이 아니라 AudioPassthrough가 직접 처리
        session.automaticallyConfiguresApplicationAudioSession = false

        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification,
                     AVCaptureDevice.wasDisconnectedNotification,
                     UIApplication.didBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reconnect() }
        }

        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVAudioApplication.requestRecordPermission { _ in
                DispatchQueue.main.async { self.reconnect() }
            }
        }
    }

    private static let gravities: [AVLayerVideoGravity] = [.resizeAspect, .resizeAspectFill, .resize]

    @objc private func cycleGravity() {
        let next = (UserDefaults.standard.integer(forKey: "gravity") + 1) % Self.gravities.count
        UserDefaults.standard.set(next, forKey: "gravity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.videoGravity = Self.gravities[next]
        CATransaction.commit()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        lockVideoUpright()
    }

    // 외부 캡처보드는 iPad 몸체와 무관 — 기기 방향에 따른 회전 없이 화면 기준 항상 정방향
    private func lockVideoUpright() {
        guard let c = previewLayer.connection, c.isVideoRotationAngleSupported(0) else { return }
        c.videoRotationAngle = 0
    }

    private func reconnect() {
        sessionQueue.async { [self] in
            let device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            ).devices.first

            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                Self.selectLowLatencyFormat(device)
            }
            session.commitConfiguration()

            let connected = !session.inputs.isEmpty
            if connected && !session.isRunning { session.startRunning() }
            if !connected && session.isRunning { session.stopRunning() }

            DispatchQueue.main.async { [self] in
                label.isHidden = connected
                if let c = previewLayer.connection, c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = false
                }
                lockVideoUpright()
            }
        }
        audio.start()
    }

    // 60fps 우선 (프레임 간격 16ms vs 30fps 33ms), 그다음 해상도
    private static func selectLowLatencyFormat(_ device: AVCaptureDevice) {
        func fps(_ f: AVCaptureDevice.Format) -> Double {
            min(f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0, 60)
        }
        func pixels(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        guard let best = device.formats.max(by: {
            fps($0) != fps($1) ? fps($0) < fps($1) : pixels($0) < pixels($1)
        }) else { return }
        guard let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
        } catch {}
    }
}

// 소리: 캡처보드의 USB 오디오 입력 → AVAudioEngine → 스피커 직결, IO 버퍼 5ms
final class AudioPassthrough {
    private var engine: AVAudioEngine?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { self?.start() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.start()
        }
    }

    func start() {
        engine?.stop()
        engine = nil

        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try s.setPreferredIOBufferDuration(0.005)
            try s.setActive(true)

            // USB 입력이 없으면 시작 안 함 — 내장 마이크→스피커 하울링 방지
            guard let usb = s.availableInputs?.first(where: { $0.portType == .usbAudio }) else { return }
            try s.setPreferredInput(usb)
            guard s.currentRoute.inputs.contains(where: { $0.portType == .usbAudio }) else { return }

            // 라우트가 바뀌면 포맷도 바뀌므로 엔진은 매번 새로 만든다
            let e = AVAudioEngine()
            let input = e.inputNode
            e.connect(input, to: e.mainMixerNode, format: input.outputFormat(forBus: 0))
            e.prepare()
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
    }
}
