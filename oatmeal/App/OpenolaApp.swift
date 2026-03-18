import SwiftUI
import Sparkle

private final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/st-imdev/oatmeal-meeting-notes/main/appcast.xml"
    }
}

@main
struct OpenolaApp: App {
    @StateObject private var model = OpenolaAppModel()
    private let sparkleDelegate = SparkleDelegate()
    private var updaterController: SPUStandardUpdaterController

    init() {
        let delegate = sparkleDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 640)
        }
        .defaultSize(width: 940, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            CommandGroup(after: .newItem) {
                Button("New Meeting") {
                    Task {
                        await model.startFreshMeeting()
                    }
                }
                .keyboardShortcut("n")
                .disabled(model.isBusy || model.hasActiveMeeting || !model.isModelReady)
            }

            CommandMenu("Meeting") {
                Button(model.isPaused ? "Resume Recording" : "Pause Recording") {
                    if model.isPaused {
                        model.resumeMeeting()
                    } else {
                        model.pauseMeeting()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(!model.hasActiveMeeting || (!model.isRecording && !model.isPaused))

                Divider()

                Button("Copy Transcript") {
                    model.copySelectedTranscript()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedSession?.combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

                Button("Finish Meeting") {
                    Task {
                        await model.finishMeeting()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.hasActiveMeeting)

                Button("Reveal Vault") {
                    model.revealVault()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Show Meeting Folder") {
                    model.revealSelectedMeeting()
                }
                .disabled(model.selectedSessionID == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520)
                .padding(20)
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: OpenolaAppModel
    @State private var apiKeyField: String = ""
    @State private var modelField: String = ""
    @State private var userNameField: String = ""

    var body: some View {
        Form {
            Section("Your Name") {
                TextField("Name", text: $userNameField, prompt: Text("Me"))
                    .onAppear { userNameField = model.userName }
                    .onChange(of: userNameField) { _, newValue in
                        model.setUserName(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                Text("Replaces \"Me\" in transcripts. Leave blank to show \"Me\".")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Audio") {
                Picker("Microphone", selection: selectedMicrophoneBinding) {
                    Text(model.systemDefaultMicrophoneLabel)
                        .tag("")

                    ForEach(model.availableMicrophones) { microphone in
                        Text(microphone.label)
                            .tag(microphone.uid)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.hasActiveMeeting)

                Button("Refresh Inputs", action: model.refreshMicrophones)

                if model.hasActiveMeeting {
                    Text("Microphone changes apply to the next meeting.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("OpenRouter") {
                SecureField("API Key", text: $apiKeyField)
                    .onAppear { apiKeyField = model.openRouterApiKey }
                    .onChange(of: apiKeyField) { _, newValue in
                        model.setOpenRouterApiKey(newValue)
                    }

                TextField("Model", text: $modelField)
                    .onAppear { modelField = model.openRouterModel }
                    .onSubmit {
                        let trimmed = modelField.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            model.setOpenRouterModel(trimmed)
                        }
                    }

                Text("Used for LLM-powered meeting summaries after each meeting.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Storage") {
                LabeledContent("Vault") {
                    Text(model.vaultRootURL.path)
                        .textSelection(.enabled)
                }

                Button("Reveal in Finder", action: model.revealVault)
            }

            Section("API") {
                if let apiBaseURL = model.apiBaseURL {
                    LabeledContent("Base URL") {
                        Text(apiBaseURL.absoluteString)
                            .textSelection(.enabled)
                    }

                    Button("Copy API URL", action: model.copyAPIURL)
                } else {
                    Text("The local API is still starting.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selectedMicrophoneBinding: Binding<String> {
        Binding(
            get: { model.selectedMicrophoneUID ?? "" },
            set: { newValue in
                model.setSelectedMicrophone(uid: newValue.isEmpty ? nil : newValue)
            }
        )
    }
}
