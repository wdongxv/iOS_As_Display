/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's primary view controller that presents the camera interface.
*/

import UIKit
import AVFoundation
import CoreLocation
import Photos

class CameraViewController: UIViewController {

    // MARK: View Controller Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()


        // Set up the video preview view.
        previewView.session = session
        // Check the video authorization status. Video access is required and
        // audio access is optional. If the user denies audio access, AVCam
        // won't record audio during movie recording.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break

        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. Suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })

        default:
            // The user has previously denied access.
            setupResult = .notAuthorized
        }

        /*
         Setup the capture session.
         In general, it's not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Don't perform these tasks on the main queue because
         AVCaptureSession.startRunning() is a blocking call, which can
         take a long time. Dispatch session setup to the sessionQueue, so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.configureSession()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        sessionQueue.async {
            switch self.setupResult {
            case .success:
                // Only setup observers and start the session if setup
                // succeeded.
                self.addObservers()
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning

            case .notAuthorized:
                DispatchQueue.main.async {
                    let changePrivacySetting = "AVCam doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                            style: .cancel,
                            handler: nil))

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                            style: .`default`,
                            handler: { _ in
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                        options: [:],
                                        completionHandler: nil)
                            }))

                    self.present(alertController, animated: true, completion: nil)
                }

            case .configurationFailed:
                DispatchQueue.main.async {
                    let alertMsg = "Alert message when something goes wrong during capture session configuration"
                    let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)

                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                            style: .cancel,
                            handler: nil))

                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
                self.removeObservers()
            }
        }

        super.viewWillDisappear(animated)
    }

    override var shouldAutorotate: Bool {
        true
    }

    // MARK: Session Management

    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }

    private let session = AVCaptureSession()
    private var isSessionRunning = false

    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "session queue")

    private var setupResult: SessionSetupResult = .success

    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!

    @IBOutlet private weak var previewView: PreviewView!

    // Call this on the session queue.
    /// - Tag: ConfigureSession
    private func configureSession() {
        if setupResult != .success {
            return
        }

        session.beginConfiguration()

        // Do not create an AVCaptureMovieFileOutput when setting up the session
        // because Live Photo is not supported when AVCaptureMovieFileOutput is
        // added to the session.
        session.sessionPreset = .high

        // Add video input.
        do {
            // Handle the situation when the system-preferred camera is nil.
            var defaultVideoDevice: AVCaptureDevice? = AVCaptureDevice.systemPreferredCamera

            let userDefaults = UserDefaults.standard
            if !userDefaults.bool(forKey: "setInitialUserPreferredCamera") || defaultVideoDevice == nil {
                let backVideoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external],
                        mediaType: .video, position: .back)

                defaultVideoDevice = backVideoDeviceDiscoverySession.devices.first

                AVCaptureDevice.userPreferredCamera = defaultVideoDevice

                userDefaults.set(true, forKey: "setInitialUserPreferredCamera")
            }
            guard let videoDevice = defaultVideoDevice else {
                print("Default video device is unavailable.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

            AVCaptureDevice.self.addObserver(self, forKeyPath: "systemPreferredCamera", options: [.new], context: &systemPreferredCameraContext)

            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput

                DispatchQueue.main.async {
                    // Dispatch video streaming to the main queue because
                    // AVCaptureVideoPreviewLayer is the backing layer for
                    // PreviewView. You can manipulate UIView only on the main
                    // thread. Note: As an exception to the above rule, it's not
                    // necessary to serialize video orientation changes on the
                    // AVCaptureVideoPreviewLayer’s connection with other
                    // session manipulation.
                    self.createDeviceRotationCoordinator()
                }
            } else {
                print("Couldn't add video device input to the session.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        } catch {
            print("Couldn't create video device input: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Add an audio input device.
        do {
            let audioDevice = AVCaptureDevice.default(for: .audio)
            let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)

            if session.canAddInput(audioDeviceInput) {
                session.addInput(audioDeviceInput)
            } else {
                print("Could not add audio device input to the session")
            }
        } catch {
            print("Could not create audio device input: \(error)")
        }

        session.commitConfiguration()
    }

    @IBOutlet private weak var cameraUnavailableLabel: UILabel!

    private var videoDeviceRotationCoordinator: AVCaptureDevice.RotationCoordinator!

    private var videoRotationAngleForHorizonLevelPreviewObservation: NSKeyValueObservation?

    private func createDeviceRotationCoordinator() {
        videoDeviceRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: videoDeviceInput.device, previewLayer: previewView.videoPreviewLayer)
        let connection = previewView.videoPreviewLayer.connection;
        connection?.videoRotationAngle = videoDeviceRotationCoordinator.videoRotationAngleForHorizonLevelPreview
        if ((connection?.isVideoMirroringSupported) != nil) {
            connection?.automaticallyAdjustsVideoMirroring = false;
            connection?.isVideoMirrored = false;
        }

        videoRotationAngleForHorizonLevelPreviewObservation = videoDeviceRotationCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { _, change in
            guard let videoRotationAngleForHorizonLevelPreview = change.newValue else {
                return
            }

            self.previewView.videoPreviewLayer.connection?.videoRotationAngle = videoRotationAngleForHorizonLevelPreview
        }
    }

    private func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {

        sessionQueue.async {
            let device = self.videoDeviceInput.device
            do {
                try device.lockForConfiguration()

                // Setting (focus/exposure)PointOfInterest alone does not
                // initiate a (focus/exposure) operation. Call
                // set(Focus/Exposure)Mode() to apply the new point of interest.
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                }

                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }

                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }

    @IBOutlet private weak var resumeButton: UIButton!

    // MARK: KVO and Notifications

    private var keyValueObservations = [NSKeyValueObservation]()

    /// - Tag: ObserveInterruption
    private func addObservers() {

        NotificationCenter.default.addObserver(self,
                selector: #selector(subjectAreaDidChange),
                name: .AVCaptureDeviceSubjectAreaDidChange,
                object: videoDeviceInput.device)

        NotificationCenter.default.addObserver(self,
                selector: #selector(sessionRuntimeError),
                name: .AVCaptureSessionRuntimeError,
                object: session)

        // A session can only run when the app is full screen. It will be
        // interrupted in a multi-app layout, introduced in iOS 9, see also the
        // documentation of AVCaptureSessionInterruptionReason. Add observers to
        // handle these session interruptions and show a preview is paused
        // message. See `AVCaptureSessionWasInterruptedNotification` for other
        // interruption reasons.
        NotificationCenter.default.addObserver(self,
                selector: #selector(sessionWasInterrupted),
                name: .AVCaptureSessionWasInterrupted,
                object: session)
        NotificationCenter.default.addObserver(self,
                selector: #selector(sessionInterruptionEnded),
                name: .AVCaptureSessionInterruptionEnded,
                object: session)
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)

        for keyValueObservation in keyValueObservations {
            keyValueObservation.invalidate()
        }
        keyValueObservations.removeAll()
    }

    private var systemPreferredCameraContext = 0

    @objc
    func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }

    /// - Tag: HandleRuntimeError
    @objc
    func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            return
        }

        print("Capture session runtime error: \(error)")
        // If media services were reset, and the last start succeeded, restart
        // the session.
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }

    /// - Tag: HandleInterruption
    @objc
    func sessionWasInterrupted(notification: NSNotification) {
        // In some scenarios you want to enable the user to resume the session.
        // For example, if music playback is initiated from Control Center while
        // using AVCam, then the user can let AVCam resume the session running,
        // which will stop music playback. Note that stopping music playback in
        // Control Center will not automatically resume the session. Also note
        // that it's not always possible to resume, see
        // `resumeInterruptedSession(_:)`.
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
           let reasonIntegerValue = userInfoValue.integerValue,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")

            var showResumeButton = false
            if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
                showResumeButton = true
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Fade-in a label to inform the user that the camera is
                // unavailable.
                cameraUnavailableLabel.alpha = 0
                cameraUnavailableLabel.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1
                }
            } else if reason == .videoDeviceNotAvailableDueToSystemPressure {
                print("Session stopped running due to shutdown system pressure level.")
            }
            if showResumeButton {
                // Fade-in a button to enable the user to try to resume the
                // session running.
                resumeButton.alpha = 0
                resumeButton.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1
                }
            }
        }
    }

    @objc
    func sessionInterruptionEnded(notification: NSNotification) {
        print("Capture session interruption ended")

        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                    animations: {
                        self.resumeButton.alpha = 0
                    }, completion: { _ in
                self.resumeButton.isHidden = true
            })
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                    animations: {
                        self.cameraUnavailableLabel.alpha = 0
                    }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }
}
