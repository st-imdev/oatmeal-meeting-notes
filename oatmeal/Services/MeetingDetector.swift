import CoreAudio
import UserNotifications
import os

/// Monitors the system's default audio input device for activity.
/// When another app starts using the microphone (e.g. a video call),
/// posts a notification offering to start recording.
final class MeetingDetector: @unchecked Sendable {
    static let startActionID = "START_RECORDING"
    static let categoryID = "MEETING_DETECTED"

    private let log = Logger(subsystem: "wonderwhat.openola", category: "MeetingDetector")
    private var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var wasRunning = false
    private var lastNotified: Date = .distantPast
    private var isMonitoring = false
    private let checkActive: @MainActor @Sendable () -> Bool

    /// `checkActive` should return `true` when a meeting is already recording.
    init(checkActive: @escaping @MainActor @Sendable () -> Bool) {
        self.checkActive = checkActive
    }

    deinit {
        removeListener()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        requestNotificationPermission()
        installListener()
    }

    func stop() {
        removeListener()
        isMonitoring = false
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let action = UNNotificationAction(
            identifier: Self.startActionID,
            title: "Start Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [action],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Detected"
        content.body = "It looks like a call is starting. Would you like to record it?"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [self] error in
            if let error {
                log.error("Failed to post meeting notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CoreAudio Input Device Monitoring

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else {
            log.warning("Could not get default input device for meeting detection")
            return
        }

        inputDeviceID = deviceID
        wasRunning = queryIsRunning()

        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(deviceID, &address, meetingDetectorListener, ctx)

        log.info("Meeting detector monitoring input device \(deviceID)")
    }

    private func removeListener() {
        guard inputDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(inputDeviceID, &address, meetingDetectorListener, ctx)
        inputDeviceID = kAudioObjectUnknown
    }

    private func queryIsRunning() -> Bool {
        guard inputDeviceID != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            inputDeviceID, &address, 0, nil, &size, &running
        ) == noErr else { return false }
        return running != 0
    }

    fileprivate func handlePropertyChange() {
        let running = queryIsRunning()
        let justStarted = running && !wasRunning
        wasRunning = running

        guard justStarted else { return }
        guard Date().timeIntervalSince(lastNotified) > 120 else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.checkActive() else { return }
            self.lastNotified = Date()
            self.postNotification()
        }
    }
}

/// Handles the "Start Recording" notification action.
final class MeetingNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onStartRecording: (@MainActor () -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == MeetingDetector.startActionID {
            Task { @MainActor [weak self] in
                self?.onStartRecording?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private func meetingDetectorListener(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return noErr }
    let detector = Unmanaged<MeetingDetector>.fromOpaque(context).takeUnretainedValue()
    detector.handlePropertyChange()
    return noErr
}
