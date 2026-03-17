import AppKit
import Combine
import Foundation

enum PrivacySettingsDestination: Sendable {
    case microphone
    case speechRecognition
    case screenCapture

    init?(error: Error) {
        guard let recorderError = error as? SpeechRecorderError else {
            return nil
        }

        switch recorderError {
        case .microphonePermissionDenied:
            self = .microphone
        case .speechPermissionDenied:
            self = .speechRecognition
        case .screenCapturePermissionDenied:
            self = .screenCapture
        default:
            return nil
        }
    }

    var buttonTitle: String {
        switch self {
        case .microphone:
            return "Open Microphone Settings"
        case .speechRecognition:
            return "Open Speech Recognition Settings"
        case .screenCapture:
            return "Open Screen Capture Settings"
        }
    }

    var url: URL {
        let path: String
        switch self {
        case .microphone:
            path = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            path = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .screenCapture:
            path = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        return URL(string: path)!
    }
}

@MainActor
final class OpenolaAppModel: ObservableObject {
    private static let preferredMicrophoneDefaultsKey = "preferredMicrophoneUID"
    private static let openRouterModelDefaultsKey = "openRouterModel"
    private static let userNameDefaultsKey = "userName"

    @Published private(set) var sessions: [MeetingSession] = []
    @Published var selectedSessionID: MeetingSession.ID?
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingCapture = false
    @Published private(set) var isBusy = false
    @Published private(set) var availableMicrophones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneUID: String?
    @Published private(set) var vaultRootURL: URL
    @Published private(set) var apiBaseURL: URL?
    @Published var statusMessage = "Preparing local vault…"
    @Published var errorMessage: String?
    @Published private(set) var permissionSettingsDestination: PrivacySettingsDestination?
    @Published var flashMessage: String?
    @Published var openRouterApiKey: String
    @Published var openRouterModel: String
    @Published var userName: String
    @Published private(set) var modelDownloadProgress: Double?
    @Published private(set) var modelDownloadPhase: String?

    private let vault: MeetingVault
    private let recorder: any MeetingTranscriptionBackend = FluidAudioRecorder()
    private let apiServer: MeetingAPIServer

    private var activeRecordingSessionID: MeetingSession.ID?
    private var recordingActivationToken = UUID()
    private var livePersistTask: Task<Void, Never>?

    init() {
        let vault = MeetingVault()
        self.vault = vault
        self.vaultRootURL = MeetingVault.defaultRootURL()
        self.apiServer = MeetingAPIServer(vault: vault)
        self.selectedMicrophoneUID = UserDefaults.standard.string(forKey: Self.preferredMicrophoneDefaultsKey)
        self.openRouterApiKey = KeychainHelper.load(key: "openRouterApiKey") ?? ""
        self.openRouterModel = UserDefaults.standard.string(forKey: Self.openRouterModelDefaultsKey) ?? "anthropic/claude-sonnet-4"
        self.userName = UserDefaults.standard.string(forKey: Self.userNameDefaultsKey) ?? ""
        configureRecorder()
        refreshMicrophones()
        hideWindowsFromScreenSharing()

        Task {
            await bootstrap()
        }
    }

    deinit {
        apiServer.stop()
    }

    var selectedSession: MeetingSession? {
        guard let selectedSessionID else {
            return nil
        }

        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var activeMeetingID: MeetingSession.ID? {
        activeRecordingSessionID
    }

    var hasActiveMeeting: Bool {
        activeRecordingSessionID != nil
    }

    func startFreshMeeting() async {
        guard !isBusy else {
            return
        }

        clearTransientMessages()
        isBusy = true

        do {
            let sessionID = try await createSession(
                title: "Meeting \(DateFormatter.sessionTitle.string(from: Date()))",
                mode: .microphone
            )
            await startRecording(sessionID: sessionID)
        } catch {
            isBusy = false
            apply(error: error)
            statusMessage = "Failed to create meeting."
        }
    }

    func finishMeeting() async {
        guard let activeRecordingSessionID else {
            return
        }

        livePersistTask?.cancel()
        recordingActivationToken = UUID()
        isBusy = true
        statusMessage = isPreparingCapture ? "Stopping meeting…" : "Finalizing transcript…"

        do {
            _ = try await updateSession(id: activeRecordingSessionID) { session in
                session.status = .transcribing
            }

            let result = await recorder.finish()
            isRecording = false
            isPreparingCapture = false
            updateWindowSharingType()
            self.activeRecordingSessionID = nil

            let finishedSessionID = activeRecordingSessionID
            _ = try await updateSession(id: finishedSessionID) { session in
                session.transcript = result.transcript
                session.transcriptSegments = result.segments
                session.status = .complete
                session.generatedNotes = nil
            }

            statusMessage = "Meeting finished."
            flashMessage = "Saved transcript as local Markdown and JSON."

            // Generate LLM-powered summary in the background if OpenRouter is configured
            if !openRouterApiKey.isEmpty, let session = sessions.first(where: { $0.id == finishedSessionID }) {
                Task {
                    statusMessage = "Generating meeting notes…"
                    let engine = MeetingSummaryEngine()
                    let notes = await engine.generate(for: session, apiKey: openRouterApiKey, model: openRouterModel)
                    do {
                        _ = try await updateSession(id: finishedSessionID) { session in
                            session.generatedNotes = notes
                        }
                        flashMessage = "Meeting notes generated."
                    } catch {
                        flashMessage = "Notes generation saved locally."
                    }
                    statusMessage = "Meeting finished."
                }
            }
        } catch {
            apply(error: error)
            statusMessage = "Failed to finish meeting."
        }

        isBusy = false
    }

    func deleteSessions(at offsets: IndexSet) async {
        let doomedSessions = offsets.compactMap { index in
            sessions.indices.contains(index) ? sessions[index] : nil
        }

        sessions = sessions.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)

        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = sessions.first?.id
        }

        for session in doomedSessions {
            do {
                try await vault.delete(session)
            } catch {
                apply(error: error)
            }
        }
    }

    func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([vaultRootURL])
    }

    func revealSelectedMeeting() {
        guard let selectedSession else {
            return
        }

        Task {
            let paths = await vault.bundlePaths(for: selectedSession)
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([paths.directoryURL])
            }
        }
    }

    func copyAPIURL() {
        guard let apiBaseURL else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiBaseURL.absoluteString, forType: .string)
        flashMessage = "Copied local API URL."
    }

    func copySelectedTranscript() {
        guard let selectedSession else {
            return
        }

        let transcript = selectedSession.resolvedCombinedTranscript(userName: userName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            flashMessage = "Nothing to copy yet."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        flashMessage = "Copied transcript."
    }

    func renameSelectedSession(to proposedTitle: String) async {
        guard let selectedSessionID else {
            return
        }

        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            permissionSettingsDestination = nil
            errorMessage = "Meeting titles cannot be empty."
            return
        }

        guard selectedSession?.title != trimmedTitle else {
            return
        }

        do {
            _ = try await updateSession(id: selectedSessionID) { session in
                session.title = trimmedTitle
            }
        } catch {
            apply(error: error)
        }
    }

    func refreshMicrophones() {
        let microphones = recorder.availableMicrophones()
        availableMicrophones = microphones

        if let selectedMicrophoneUID, !microphones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            self.selectedMicrophoneUID = nil
            UserDefaults.standard.removeObject(forKey: Self.preferredMicrophoneDefaultsKey)
        }

        recorder.preferredMicrophoneUID = selectedMicrophoneUID
    }

    func setSelectedMicrophone(uid: String?) {
        selectedMicrophoneUID = uid

        if let uid {
            UserDefaults.standard.set(uid, forKey: Self.preferredMicrophoneDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.preferredMicrophoneDefaultsKey)
        }

        recorder.preferredMicrophoneUID = uid
        flashMessage = isRecording
            ? "Microphone updated. It will apply to the next meeting."
            : "Microphone updated."
    }

    var systemDefaultMicrophoneLabel: String {
        if let device = availableMicrophones.first(where: \.isSystemDefault) {
            return "System Default (\(device.name))"
        }

        return "System Default"
    }

    func setOpenRouterApiKey(_ key: String) {
        openRouterApiKey = key
        if key.isEmpty {
            KeychainHelper.delete(key: "openRouterApiKey")
        } else {
            KeychainHelper.save(key: "openRouterApiKey", value: key)
        }
    }

    func setOpenRouterModel(_ model: String) {
        openRouterModel = model
        UserDefaults.standard.set(model, forKey: Self.openRouterModelDefaultsKey)
    }

    func setUserName(_ name: String) {
        userName = name
        if name.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.userNameDefaultsKey)
        } else {
            UserDefaults.standard.set(name, forKey: Self.userNameDefaultsKey)
        }
    }

    func displayName(for rawSpeaker: String, in session: MeetingSession) -> String {
        session.resolvedSpeakerName(for: rawSpeaker, userName: userName)
    }

    func renameSpeaker(rawLabel: String, newName: String, inSessionID sessionID: MeetingSession.ID) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await updateSession(id: sessionID) { session in
                var map = session.speakerNameMap ?? [:]
                if trimmed.isEmpty || trimmed == rawLabel {
                    map.removeValue(forKey: rawLabel)
                } else {
                    map[rawLabel] = trimmed
                }
                session.speakerNameMap = map.isEmpty ? nil : map
            }
        } catch {
            apply(error: error)
        }
    }

    func openPermissionSettings() {
        guard let destination = permissionSettingsDestination else {
            return
        }

        NSWorkspace.shared.open(destination.url)
    }

    /// Hide all Openola windows from screen sharing while recording
    /// so the app is invisible during calls.
    private func hideWindowsFromScreenSharing() {
        // Watch for new windows becoming key — apply current sharing policy.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            window.sharingType = self.isRecording ? .none : .readOnly
        }
    }

    func updateWindowSharingType() {
        let type: NSWindow.SharingType = isRecording ? .none : .readOnly
        for window in NSApplication.shared.windows {
            window.sharingType = type
        }
    }

    private func bootstrap() async {
        isBusy = true

        vaultRootURL = vault.rootURL

        do {
            apiBaseURL = try await apiServer.start()
        } catch {
            apply(error: error)
        }

        do {
            sessions = try await vault.loadSessions()
            if sessions.isEmpty {
                statusMessage = "Start a new meeting."
            } else {
                selectedSessionID = sessions.first?.id
                statusMessage = "Local vault ready."
            }
        } catch {
            if errorMessage == nil {
                apply(error: error)
            }
            statusMessage = "Vault is ready, but loading history failed."
        }

        isBusy = false
    }

    @discardableResult
    private func createSession(title: String, mode: CaptureMode) async throws -> MeetingSession.ID {
        var session = MeetingSession.draft(template: .general, title: title)
        session.captureMode = mode
        session.generatedNotes = nil
        session = try await vault.save(session, userName: userName)

        sessions.insert(session, at: 0)
        sortSessions()
        selectedSessionID = session.id
        flashMessage = "Created a new meeting."
        return session.id
    }

    private func startRecording(sessionID: MeetingSession.ID) async {
        clearTransientMessages()

        selectedSessionID = sessionID
        activeRecordingSessionID = sessionID
        let activationToken = UUID()
        recordingActivationToken = activationToken
        isPreparingCapture = true
        statusMessage = "Requesting microphone, speech, and speaker capture access…"

        do {
            _ = try await updateSession(id: sessionID) { session in
                session.captureMode = .microphone
                session.status = .recording
                session.generatedNotes = nil
            }

            try await recorder.start()
            guard recordingActivationToken == activationToken, activeRecordingSessionID == sessionID else {
                _ = await recorder.finish()
                isPreparingCapture = false
                isBusy = false
                return
            }

            isRecording = true
            isPreparingCapture = false
            updateWindowSharingType()
            statusMessage = "Recording your microphone and speaker audio. Transcript is updating live."
        } catch {
            activeRecordingSessionID = nil
            isRecording = false
            isPreparingCapture = false
            apply(error: error)
            statusMessage = "Capture is unavailable."

            do {
                _ = try await updateSession(id: sessionID) { session in
                    session.status = .draft
                }
            } catch {
                apply(error: error)
            }
        }

        isBusy = false
    }

    private func configureRecorder() {
        recorder.preferredMicrophoneUID = selectedMicrophoneUID

        recorder.onUpdate = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyLive(result: result)
            }
        }

        recorder.onStatus = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.statusMessage = message
            }
        }

        if let fluidRecorder = recorder as? FluidAudioRecorder {
            fluidRecorder.onDownloadProgress = { [weak self] fraction, phase in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if fraction >= 1.0 && phase == "Ready" {
                        self.modelDownloadProgress = nil
                        self.modelDownloadPhase = nil
                    } else {
                        self.modelDownloadProgress = fraction
                        self.modelDownloadPhase = phase
                    }
                }
            }
        }
    }

    private func applyLive(result: TranscriptionResult) {
        guard
            let activeRecordingSessionID,
            let index = sessions.firstIndex(where: { $0.id == activeRecordingSessionID })
        else {
            return
        }

        sessions[index].transcript = result.transcript
        sessions[index].transcriptSegments = result.segments
        sessions[index].status = .recording
        sessions[index].updatedAt = Date()
        sortSessions()

        let session = sessions[index]
        scheduleLivePersist(for: session)
    }

    private func scheduleLivePersist(for session: MeetingSession) {
        livePersistTask?.cancel()

        livePersistTask = Task { [weak self, session] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else {
                return
            }

            do {
                let persisted = try await self.vault.save(session, userName: self.userName)
                await MainActor.run {
                    self.replaceSession(persisted)
                }
            } catch {
                await MainActor.run {
                    self.apply(error: error)
                }
            }
        }
    }

    private func clearTransientMessages() {
        errorMessage = nil
        permissionSettingsDestination = nil
        flashMessage = nil
    }

    private func apply(error: Error) {
        errorMessage = error.localizedDescription
        permissionSettingsDestination = PrivacySettingsDestination(error: error)
    }

    @discardableResult
    private func updateSession(
        id: MeetingSession.ID,
        _ mutate: (inout MeetingSession) -> Void
    ) async throws -> MeetingSession {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }

        mutate(&sessions[index])
        sessions[index].updatedAt = Date()
        let persisted = try await vault.save(sessions[index], userName: userName)
        replaceSession(persisted)
        return persisted
    }

    private func replaceSession(_ session: MeetingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }

        sortSessions()
    }

    private func sortSessions() {
        sessions.sort { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }
}
