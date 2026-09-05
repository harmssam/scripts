import SwiftUI

struct DiskAccessGuide: View {
    let level: DiskAccessLevel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: level == .full ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(level == .full ? Color(hex: 0x63D6A4) : Color(hex: 0xE6B75F))
                VStack(alignment: .leading, spacing: 3) {
                    Text(level == .full ? "Full Disk Access is on" : "Finish setting up disk access")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(level == .full ? "Burrow can inspect all supported locations." : "Burrow stays useful in limited mode, but protected locations will be omitted.")
                        .font(BurrowType.body).foregroundStyle(.secondary)
                }
            }

            if level == .limited {
                VStack(alignment: .leading, spacing: 12) {
                    guideStep(1, "Open Privacy & Security → Full Disk Access")
                    guideStep(2, "Enable Burrow in the application list")
                    guideStep(3, "Return here and relaunch Burrow if macOS asks")
                }
                .padding(16)
                .burrowPanel()

                Text("Until access is granted, previews remain available with reduced coverage and maintenance execution stays locked.")
                    .font(BurrowType.data).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Not now") { dismiss() }.buttonStyle(.plain)
                if level == .limited {
                    Button("Open System Settings") { openURL(settingsURL) }
                        .buttonStyle(PrimaryCapsuleButtonStyle(accent: Color(hex: 0xE6B75F)))
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryCapsuleButtonStyle(accent: Color(hex: 0x63D6A4)))
                }
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").font(BurrowType.label).foregroundStyle(.black.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Color(hex: 0xE6B75F), in: Circle())
            Text(text).font(BurrowType.body)
        }
    }
}

struct SafetyGatePanel: View {
    let gate: SafetyGate
    let accent: Color
    var openAccessGuide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: gate.canExecute ? "checkmark.shield.fill" : "lock.shield.fill")
                    .foregroundStyle(gate.canExecute ? Color(hex: 0x63D6A4) : accent)
                Text(gate.canExecute ? "Ready for confirmation" : "Preview only")
                    .font(BurrowType.title)
                Spacer()
                Text(gate.canPreview ? "PREVIEW AVAILABLE" : "UNAVAILABLE").font(BurrowType.label).foregroundStyle(.secondary)
            }

            ForEach(gate.requirements, id: \.self) { requirement in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: requirement == .fullDiskAccessRequired ? "lock.fill" : "circle.fill")
                        .font(.system(size: 7)).foregroundStyle(accent)
                    Text(requirement.message).font(BurrowType.data).foregroundStyle(.secondary)
                    Spacer()
                    if requirement == .fullDiskAccessRequired, let openAccessGuide {
                        Button("Set up") { openAccessGuide() }.buttonStyle(.plain).foregroundStyle(accent)
                    }
                }
            }
        }
        .padding(15)
        .burrowPanel()
        .accessibilityElement(children: .contain)
    }
}

struct ExecutionConfirmationView: View {
    let confirmation: ExecutionConfirmation
    let gate: SafetyGate
    let accent: Color
    let onConfirm: (String) -> Void
    @State private var phrase = ""

    private func authorized(at date: Date) -> Bool {
        confirmation.isAuthorized(
            typedPhrase: phrase,
            now: date,
            gate: gate
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm \(confirmation.operation.title)", systemImage: "checkmark.shield")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
            Text("This action is bound to plan \(confirmation.shortFingerprint), containing \(confirmation.itemCount) items\(sizeSuffix).")
                .font(BurrowType.body).foregroundStyle(.secondary)

            SafetyGatePanel(gate: gate, accent: accent)

            Text("Type **\(confirmation.requiredPhrase)** to confirm the exact plan.")
                .font(BurrowType.body)
            TextField(confirmation.requiredPhrase, text: $phrase).textFieldStyle(.roundedBorder)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secondsRemaining = max(0, Int(confirmation.planExpiresAt.timeIntervalSince(context.date).rounded(.up)))
                HStack {
                    Text(secondsRemaining > 0
                         ? "Expires in \(secondsRemaining)s · \(confirmation.planExpiresAt.formatted(date: .omitted, time: .shortened))"
                         : "Expired · build a fresh preview")
                        .font(BurrowType.label)
                        .foregroundStyle(secondsRemaining > 0 ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Run demo scenario") { onConfirm(phrase) }
                        .buttonStyle(PrimaryCapsuleButtonStyle(accent: accent))
                        .disabled(!authorized(at: context.date))
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var sizeSuffix: String {
        ", totaling \(ByteFormatter.string(confirmation.affectedBytes))"
    }
}

struct ExecutionFlowSheet: View {
    let model: ExecutionPresentationModel
    let currentPreviewFingerprint: String
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var closeAfterCancellation = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.mode.label, systemImage: "testtube.2")
                    .font(BurrowType.label)
                    .foregroundStyle(accent)
                Spacer()
                Button(model.isExecuting ? (model.isCancellationRequested ? "Stopping…" : "Cancel demo") : "Close") {
                    if model.isExecuting {
                        closeAfterCancellation = true
                        model.cancel()
                    } else {
                        dismiss()
                    }
                }
                    .buttonStyle(.plain)
                    .disabled(model.isCancellationRequested)
                    .help(model.isExecuting ? "Cancel the in-memory demo; this window closes after it settles." : "Close")
            }

            switch model.state {
            case .review(let review):
                reviewView(review)
            case .confirming(_, let confirmation, let gate):
                ExecutionConfirmationView(
                    confirmation: confirmation, gate: gate, accent: accent
                ) { phrase in
                    model.authorizeAndExecute(
                        typedPhrase: phrase, currentPreviewFingerprint: currentPreviewFingerprint
                    )
                }
            case .executing(_, let progress):
                ExecutionProgressView(progress: progress, accent: accent) { model.cancel() }
            case .receipt(_, let receipt):
                OperationReceiptView(receipt: receipt, accent: accent)
            case .stale:
                ContentUnavailableView(
                    "Preview changed",
                    systemImage: "arrow.clockwise.circle",
                    description: Text("This exact plan is stale. Close this window and build a fresh preview. No files were changed.")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Stopped safely", systemImage: "exclamationmark.shield",
                    description: Text(message)
                )
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 410)
        .interactiveDismissDisabled(model.isExecuting)
        .onChange(of: currentPreviewFingerprint) { _, fingerprint in
            model.invalidateIfPreviewChanged(to: fingerprint)
        }
        .onChange(of: model.isExecuting) { wasExecuting, isExecuting in
            if wasExecuting, !isExecuting, closeAfterCancellation { dismiss() }
        }
        .onDisappear { model.cancel() }
        .task {
            while !Task.isCancelled {
                model.refreshExpiry()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func reviewView(_ review: ExecutionPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Review the exact demo plan", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Plan \(review.shortFingerprint) is bound to preview \(review.previewFingerprint.prefix(8).uppercased()).")
                .font(BurrowType.body).foregroundStyle(.secondary)

            HStack(spacing: 24) {
                reviewMetric("Operation", review.operation.title)
                reviewMetric("Demo items", "\(review.itemCount)")
                reviewMetric("Known bytes", ByteFormatter.string(review.affectedBytes))
            }
            .padding(16).burrowPanel()

            Label(
                "Demo only: the in-memory transport replays progress events and cannot access the filesystem.",
                systemImage: "lock.shield.fill"
            )
            .font(BurrowType.data).foregroundStyle(accent)

            HStack {
                Spacer()
                Button("Continue to confirmation") {
                    model.requestConfirmation(currentPreviewFingerprint: currentPreviewFingerprint)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(accent: accent))
            }
        }
    }

    private func reviewMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BurrowType.data)
            Text(label.uppercased()).font(BurrowType.label).foregroundStyle(.secondary)
        }
    }
}

struct ExecutionProgressView: View {
    let progress: ExecutionProgress
    let accent: Color
    let requestCancellation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.cancellationRequested ? "Stopping safely…" : progress.currentTask).font(BurrowType.title)
                Spacer()
                Text("\(progress.completedItems) / \(progress.totalItems)").font(BurrowType.data)
            }
            ProgressView(value: progress.fraction).tint(accent)
            HStack {
                Text(progress.cancellationRequested ? "Finishing the current atomic step." : "You can cancel between atomic steps.")
                    .font(BurrowType.label).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: requestCancellation)
                    .disabled(progress.cancellationRequested)
            }
        }
        .padding(16).burrowPanel()
    }
}

struct OperationReceiptView: View {
    let receipt: OperationReceipt
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: outcomeIcon).font(.title2).foregroundStyle(outcomeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.outcome.title).font(BurrowType.title)
                    Text("Receipt \(receipt.id.uuidString.prefix(8)) · plan \(receipt.planFingerprint.prefix(8))")
                        .font(BurrowType.label).foregroundStyle(.secondary)
                }
                Spacer()
                if let bytes = receipt.completedBytes {
                    Text("\(ByteFormatter.string(bytes)) processed").font(BurrowType.data)
                }
            }

            HStack(spacing: 18) {
                receiptCount("Completed", receipt.completedCount)
                receiptCount("Skipped", receipt.skippedCount)
                receiptCount("Failed", receipt.failedCount)
                Spacer()
                Text(receipt.finishedAt.formatted(date: .abbreviated, time: .shortened)).font(BurrowType.label).foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(receipt.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: itemIcon(item.status)).foregroundStyle(item.status == .failed ? .orange : accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(BurrowType.body)
                                Text(item.detail).font(BurrowType.label).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.status.rawValue.uppercased()).font(BurrowType.label).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 220)
            .clipped()
        }
        .padding(16).burrowPanel()
    }

    private func receiptCount(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(BurrowType.data)
            Text(label.uppercased()).font(BurrowType.label).foregroundStyle(.secondary)
        }
    }

    private var outcomeIcon: String {
        switch receipt.outcome {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .partiallyCompleted: "circle.lefthalf.filled"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var outcomeColor: Color { receipt.outcome == .completed ? accent : .orange }

    private func itemIcon(_ status: ReceiptItemStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }
}
