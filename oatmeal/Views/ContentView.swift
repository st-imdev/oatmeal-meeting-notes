import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: OpenolaAppModel

    var body: some View {
        NavigationSplitView {
            MeetingSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            MainPane(session: model.selectedSession)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarContentView()
        }
    }
}

private struct MainPane: View {
    let session: MeetingSession?

    var body: some View {
        Group {
            if let session {
                MeetingDetailView(session: session)
                    .id(session.id)
            } else {
                HomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingSidebar: View {
    @EnvironmentObject private var model: OpenolaAppModel

    var body: some View {
        List(selection: $model.selectedSessionID) {
            Section {
                ForEach(model.sessions) { session in
                    SessionRow(session: session, isActive: model.activeMeetingID == session.id)
                        .tag(session.id)
                }
                .onDelete { offsets in
                    Task {
                        await model.deleteSessions(at: offsets)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No Meetings Yet",
                    systemImage: "record.circle",
                    description: Text("Start a meeting and it will appear here.")
                )
            }
        }
        .navigationTitle("Oatmeal")
    }
}

private struct ToolbarContentView: ToolbarContent {
    @EnvironmentObject private var model: OpenolaAppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: startMeeting) {
                Label("New Meeting", systemImage: "plus.circle")
            }
            .disabled(model.isBusy || model.hasActiveMeeting)

            if model.hasActiveMeeting {
                Button(action: finishMeeting) {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
            }

            if model.selectedSession != nil {
                Button(action: model.copySelectedTranscript) {
                    Label("Copy Transcript", systemImage: "square.on.square")
                }
                .disabled(model.selectedSession?.combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }
    }

    private func startMeeting() {
        Task {
            await model.startFreshMeeting()
        }
    }

    private func finishMeeting() {
        Task {
            await model.finishMeeting()
        }
    }
}

private struct SessionRow: View {
    let session: MeetingSession
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isActive {
                    Image(systemName: "record.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Meeting in progress")
                }
            }

            Text(DateFormatter.shortMeta.string(from: session.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        session.combinedTranscript
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct HomeView: View {
    @EnvironmentObject private var model: OpenolaAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 16)

            Text("Oatmeal")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            Text("Start a meeting, watch the transcript build live, copy it anywhere.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: startMeeting) {
                Label("Start Meeting", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy || model.hasActiveMeeting)

            StatusBlock()

            Text("Everything is saved locally as Markdown and JSON inside your vault.")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Oatmeal")
    }

    private func startMeeting() {
        Task {
            await model.startFreshMeeting()
        }
    }
}

private struct MeetingDetailView: View {
    @EnvironmentObject private var model: OpenolaAppModel

    let session: MeetingSession

    private var isActiveMeeting: Bool {
        model.activeMeetingID == session.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned header — never scrolls
            VStack(alignment: .leading, spacing: 20) {
                MeetingHeader(session: session, isActiveMeeting: isActiveMeeting)

                HStack {
                    Text("Transcript")
                        .font(.system(.title2, design: .rounded).weight(.semibold))

                    Spacer()

                    if isActiveMeeting {
                        Label("Live", systemImage: "waveform")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .top)

            // Thin separator — using a Rectangle instead of Divider() to avoid
            // macOS rendering artifacts where Divider floats over scroll content.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            // Scrollable transcript rows
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    TranscriptBody(
                        session: session,
                        isActive: isActiveMeeting
                    )
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .background { ScrollViewVibrancyFix() }
                .onChange(of: session.transcriptSegments.last?.id) { _, _ in
                    if let lastID = session.transcriptSegments.last?.id {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle(session.title)
    }
}

private struct MeetingHeader: View {
    @EnvironmentObject private var model: OpenolaAppModel
    @FocusState private var titleFieldFocused: Bool
    @State private var editableTitle: String = ""

    let session: MeetingSession
    let isActiveMeeting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                TextField("Meeting Title", text: $editableTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .focused($titleFieldFocused)
                    .onSubmit(commitTitle)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button(action: model.copySelectedTranscript) {
                        Image(systemName: "square.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Copy transcript")
                    .disabled(session.combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isActiveMeeting {
                        Button(action: finishMeeting) {
                            Label("Stop", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }

            HStack(spacing: 12) {
                Text(DateFormatter.shortMeta.string(from: session.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("•")
                    .foregroundStyle(.tertiary)

                StatusBadge(
                    title: activeLabel,
                    isActive: isActiveMeeting
                )
            }

            if isActiveMeeting || session.captureMode == .microphone {
                let meLabel = model.userName.isEmpty ? "Me" : model.userName
                VStack(alignment: .leading, spacing: 4) {
                    Text("`\(meLabel)` is your microphone. `Them` is speaker output.")
                    if isActiveMeeting {
                        Text("Speaker labels may be inaccurate during live transcription. They are refined when the meeting ends.")
                    } else {
                        Text("Click a speaker label to rename it.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
            }

            StatusBlock()
        }
        .onAppear {
            editableTitle = session.title
        }
        .onChange(of: session.title) { _, newTitle in
            if !titleFieldFocused {
                editableTitle = newTitle
            }
        }
        .onChange(of: titleFieldFocused) { _, isFocused in
            if !isFocused {
                commitTitle()
            }
        }
    }

    private func finishMeeting() {
        Task {
            await model.finishMeeting()
        }
    }

    private func commitTitle() {
        let proposedTitle = editableTitle
        Task {
            await model.renameSelectedSession(to: proposedTitle)
        }
    }

    private var activeLabel: String {
        if isActiveMeeting {
            return model.isRecording ? "Recording" : "Starting"
        }

        return session.status.label
    }
}

private struct StatusBadge: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.red : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isActive ? .red : .secondary)
        }
    }
}

private struct StatusBlock: View {
    @EnvironmentObject private var model: OpenolaAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)

            if let progress = model.modelDownloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    if let phase = model.modelDownloadPhase {
                        Text(phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 340)
                .padding(.vertical, 4)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                if let destination = model.permissionSettingsDestination {
                    Button(destination.buttonTitle, action: model.openPermissionSettings)
                        .buttonStyle(.link)
                }
            }

            if let flashMessage = model.flashMessage {
                Text(flashMessage)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptBody: View {
    @EnvironmentObject private var model: OpenolaAppModel

    let session: MeetingSession
    let isActive: Bool

    private var segments: [TranscriptSegment] { session.transcriptSegments }

    var body: some View {
        if segments.isEmpty {
            Text(emptyStateText)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(segments) { segment in
                    TranscriptRow(
                        segment: segment,
                        displayName: model.displayName(
                            for: segment.speaker ?? "",
                            in: session
                        ),
                        sessionID: session.id
                    )
                    .id(segment.id)
                }
            }
        }
    }

    private var emptyStateText: String {
        if isActive {
            if model.isPreparingCapture && !model.isRecording {
                return "Preparing live transcription…"
            }

            return "Listening for both sides of the conversation…"
        }

        let trimmedTranscript = session.combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            return trimmedTranscript
        }

        return "No transcript yet."
    }
}

private struct TranscriptRow: View {
    @EnvironmentObject private var model: OpenolaAppModel

    let segment: TranscriptSegment
    let displayName: String
    let sessionID: MeetingSession.ID

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(displayName.isEmpty ? "Note" : displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speakerColor)
                .frame(width: 70, alignment: .leading)
                .onTapGesture {
                    guard canRename else { return }
                    renameText = displayName
                    isRenaming = true
                }
                .popover(isPresented: $isRenaming) {
                    VStack(spacing: 8) {
                        Text("Rename \"\(rawSpeaker)\"")
                            .font(.headline)

                        TextField("Name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit(commitRename)

                        HStack {
                            Button("Cancel") { isRenaming = false }
                                .keyboardShortcut(.cancelAction)
                            Button("Save", action: commitRename)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(12)
                }

            Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var rawSpeaker: String {
        segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? segment.speaker!
            : "Note"
    }

    private var canRename: Bool {
        rawSpeaker != "Note" && rawSpeaker != "Me"
    }

    private func commitRename() {
        isRenaming = false
        Task {
            await model.renameSpeaker(
                rawLabel: rawSpeaker,
                newName: renameText,
                inSessionID: sessionID
            )
        }
    }

    private static let speakerColors: [Color] = [.blue, .purple, .orange, .teal, .pink, .mint]

    private var speakerColor: Color {
        switch rawSpeaker {
        case "Me":
            return .red
        case "Them":
            return .secondary
        default:
            if rawSpeaker.hasPrefix("Speaker "),
               let number = Int(rawSpeaker.dropFirst("Speaker ".count)),
               number >= 2 {
                let index = (number - 2) % Self.speakerColors.count
                return Self.speakerColors[index]
            }
            return .secondary.opacity(0.6)
        }
    }
}

// MARK: - macOS NSVisualEffectView fix
//
// macOS automatically inserts an NSVisualEffectView inside the NSScrollView
// that backs SwiftUI's ScrollView in NavigationSplitView detail panes.
// This renders as a translucent horizontal bar over transcript content.
// The fix: embed an NSViewRepresentable inside the scroll view that walks
// up to its parent NSScrollView and hides the vibrancy overlay.

private struct ScrollViewVibrancyFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.frame = .zero
        DispatchQueue.main.async { Self.hideVibrancy(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.hideVibrancy(from: nsView) }
    }

    private static func hideVibrancy(from view: NSView) {
        // The NSVisualEffectView lives in the NSSplitView's titlebar area:
        // NSTitlebarBackgroundView > NSScrollPocket > NSHardPocketView
        //   > _NSScrollViewContentBackgroundView > NSVisualEffectView
        // Walk up to the window and search the entire tree for it.
        guard let contentView = view.window?.contentView else { return }
        hideContentBackgroundVibrancy(in: contentView)
    }

    private static func hideContentBackgroundVibrancy(in view: NSView) {
        let className = String(describing: type(of: view))
        // Target both the backdrop view and the scroll content background view
        if className == "NSHardPocketView"
            || className == "BackdropView"
            || className == "_NSScrollViewContentBackgroundView" {
            view.isHidden = true
            return
        }
        for sub in view.subviews {
            hideContentBackgroundVibrancy(in: sub)
        }
    }
}
