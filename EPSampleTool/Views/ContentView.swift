import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if let device = model.device {
                    LibraryView(device: device)
                } else {
                    ConnectView(state: model.connection, simulated: model.isSimulatedDevice)
                }
            }
            .animation(.default, value: model.device == nil)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ConnectView: View {
    let state: AppModel.ConnectionState
    let simulated: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 140, height: 140)
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: isWaiting)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if case .connecting = state {
                ProgressView()
            }

            if isWaiting {
                VStack(alignment: .leading, spacing: 14) {
                    Step(number: 1, text: "Connect the device to this iPhone or iPad with a USB-C cable.")
                    Step(number: 2, text: "Turn the device on.")
                    Step(number: 3, text: "It shows up here automatically.")
                }
                .padding(20)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 420)
            }
            Spacer()
            if simulated {
                Label("Simulator: using a simulated EP-133", systemImage: "desktopcomputer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .navigationTitle("EP Samples")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isWaiting: Bool {
        switch state {
        case .starting, .searching: true
        default: false
        }
    }

    private var icon: String {
        switch state {
        case .failed: "exclamationmark.triangle"
        case .unsupported: "questionmark.circle"
        default: "cable.connector"
        }
    }

    private var title: String {
        switch state {
        case .starting, .searching: "Connect your EP"
        case .connecting(let name): "Connecting to \(name)…"
        case .unsupported(let name): "\(name) isn't supported"
        case .failed: "MIDI isn't available"
        case .connected(let d): d.modelName
        }
    }

    private var subtitle: String {
        switch state {
        case .starting, .searching: "Works with EP-133 K.O. II, EP-1320 Medieval and EP-40 Riddim."
        case .connecting: "Reading the sound library."
        case .unsupported: "This app only works with EP-133, EP-1320 and EP-40."
        case .failed(let message): message
        case .connected: ""
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(.white)
            Text(text)
                .font(.callout)
        }
    }
}
