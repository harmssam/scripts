import SwiftUI

struct LiveMaintenanceSheet: View {
    enum Phase { case confirmation, running, succeeded(String), failed(String) }

    let title: String
    let detail: String
    let requiredPhrase: String
    let accent: Color
    let run: () async throws -> String
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var phase: Phase = .confirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: "wrench.and.screwdriver.fill")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            switch phase {
            case .confirmation:
                Text(detail).font(BurrowType.body).foregroundStyle(.secondary)
                Label("This runs the connected Mole engine on this Mac.", systemImage: "externaldrive.fill.badge.checkmark")
                    .font(BurrowType.data).foregroundStyle(accent)
                Text("Type **\(requiredPhrase)** to continue.").font(BurrowType.body)
                TextField(requiredPhrase, text: $phrase).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(.plain)
                    Spacer()
                    Button("Run now") { start() }
                        .buttonStyle(PrimaryCapsuleButtonStyle(accent: accent))
                        .disabled(phrase != requiredPhrase)
                }
            case .running:
                ProgressView().controlSize(.large)
                Text("Mole is working… Keep Burrow open until it finishes.")
                    .font(BurrowType.body).foregroundStyle(.secondary)
            case .succeeded(let output):
                Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                outputView(output)
                closeButton
            case .failed(let message):
                Label("Mole could not finish", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                outputView(message)
                closeButton
            }
        }
        .padding(26)
        .frame(width: 600)
        .frame(minHeight: 300)
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool { if case .running = phase { true } else { false } }
    private var closeButton: some View {
        HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(PrimaryCapsuleButtonStyle(accent: accent)) }
    }
    private func outputView(_ text: String) -> some View {
        ScrollView { Text(text.isEmpty ? "Mole completed successfully." : text).font(BurrowType.data).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 220).padding(12).burrowPanel()
    }
    private func start() {
        guard phrase == requiredPhrase else { return }
        phase = .running
        Task {
            do { phase = .succeeded(try await run()) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }
}
