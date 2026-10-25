import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let device: ConnectedDevice

    @State private var showImporter = false
    @State private var search = ""
    @State private var renaming: Sound?
    @State private var newName = ""
    @State private var deleting: Sound?
    @State private var showDeviceInfo = false

    private var filtered: [Sound] {
        guard !search.isEmpty else { return model.sounds }
        let q = search.lowercased()
        return model.sounds.filter { $0.name.lowercased().contains(q) || String(format: "%03d", $0.slot).hasPrefix(q) }
    }

    var body: some View {
        List {
            Section {
                DeviceHeader(device: device, soundCount: model.sounds.count) { showDeviceInfo = true }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if !model.uploads.isEmpty {
                Section {
                    ForEach(model.uploads) { UploadRow(item: $0) }
                } header: {
                    HStack {
                        Text("Uploads")
                        Spacer()
                        if !model.uploads.contains(where: \.progress.isActive) {
                            Button("Clear") { model.clearFinishedUploads() }
                                .font(.footnote)
                        }
                    }
                }
            }

            Section {
                if model.sounds.isEmpty && model.isLoadingLibrary {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if filtered.isEmpty {
                    Text(search.isEmpty ? "No sounds on the device yet." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { sound in
                    SoundRow(sound: sound, isPlaying: model.playingSlot == sound.slot)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await model.togglePlayback(sound) } }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = sound } label: { Label("Delete", systemImage: "trash") }
                            Button { beginRename(sound) } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.gray)
                        }
                        .contextMenu {
                            Button { Task { await model.togglePlayback(sound) } } label: {
                                Label(model.playingSlot == sound.slot ? "Stop" : "Preview on device", systemImage: "speaker.wave.2")
                            }
                            Button { beginRename(sound) } label: { Label("Rename", systemImage: "pencil") }
                            Divider()
                            Button(role: .destructive) { deleting = sound } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            } header: {
                HStack {
                    Text("Sound library")
                    Spacer()
                    if model.isLoadingLibrary { ProgressView().controlSize(.mini) }
                }
            } footer: {
                if !model.sounds.isEmpty {
                    Text("Tap a sound to hear it on the device.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search by name or slot")
        .refreshable { await model.reloadLibrary() }
        .navigationTitle("Sounds")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Add sounds", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.upload(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio)) ?? false }
            guard !audio.isEmpty else { return false }
            model.upload(audio)
            return true
        }
        .alert("Rename sound", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let sound = renaming { Task { await model.rename(sound, to: newName) } }
            }
        } message: {
            Text("Up to 16 characters. Names are stored in lowercase ASCII.")
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "sound")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from device", role: .destructive) {
                if let sound = deleting { Task { await model.delete(sound) } }
            }
        } message: {
            Text("This removes slot \(deleting.map { String(format: "%03d", $0.slot) } ?? "") from the device. It can't be undone.")
        }
        .sheet(isPresented: $showDeviceInfo) {
            DeviceInfoSheet(device: device)
        }
    }

    private func beginRename(_ sound: Sound) {
        newName = sound.name
        renaming = sound
    }
}

private struct DeviceHeader: View {
    let device: ConnectedDevice
    let soundCount: Int
    let onInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.modelName)
                        .font(.title3.weight(.semibold))
                    Text("Firmware \(device.metadata.osVersion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Device details")
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(soundCount), total: 999)
                    .tint(Theme.accent)
                Text("\(soundCount) of 999 slots used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if device.firmwareTooOld {
                Label("This firmware is older than the official tool supports. Update the device before uploading.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .padding(.vertical, 4)
    }
}

struct SoundRow: View {
    let sound: Sound
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%03d", sound.slot))
                .font(Theme.slotFont)
                .foregroundStyle(isPlaying ? Theme.accent : .secondary)
                .frame(minWidth: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the sound on the device")
    }

    private var detail: String {
        var parts: [String] = []
        if let d = sound.duration { parts.append(String(format: "%.2f s", d)) }
        if let c = sound.channels { parts.append(c == 1 ? "mono" : "stereo") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(sound.size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

private struct UploadRow: View {
    let item: UploadItem

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%03d", item.slot))
                .font(Theme.slotFont)
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName).lineLimit(1)
                switch item.progress {
                case .queued:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                case .converting:
                    Text("Converting").font(.caption).foregroundStyle(.secondary)
                case .sending(let f):
                    ProgressView(value: f).tint(Theme.accent)
                case .done:
                    Text("Uploaded").font(.caption).foregroundStyle(.green)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            statusIcon
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.progress {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .converting, .queued: ProgressView().controlSize(.small)
        case .sending: EmptyView()
        }
    }
}

private struct DeviceInfoSheet: View {
    let device: ConnectedDevice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Model", value: device.modelName)
                LabeledContent("SKU", value: device.sku)
                LabeledContent("Firmware", value: device.metadata.osVersion)
                LabeledContent("Serial", value: device.metadata.serial)
                LabeledContent("Mode", value: device.metadata.mode)
                LabeledContent("Port", value: device.portName)
            }
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium])
    }
}
