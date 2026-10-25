import Foundation
import Observation
import os

struct ConnectedDevice: Equatable {
    var modelName: String
    var sku: String
    var metadata: DeviceMetadata
    var portName: String
    var firmwareTooOld: Bool
}

struct UploadItem: Identifiable, Equatable {
    let id = UUID()
    var fileName: String
    var slot: Int
    var progress: UploadProgress
}

@MainActor
@Observable
final class AppModel {
    enum ConnectionState: Equatable {
        case starting
        case searching
        case connecting(String)
        case connected(ConnectedDevice)
        case unsupported(String)
        case failed(String)
    }

    private(set) var connection: ConnectionState = .starting
    private(set) var sounds: [Sound] = []
    private(set) var isLoadingLibrary = false
    private(set) var uploads: [UploadItem] = []
    private(set) var playingSlot: Int?
    var errorMessage: String?
    let isSimulatedDevice: Bool

    private let transport: SysExTransport?
    private var client: TEClient?
    private var service: DeviceService?
    private var destination: EndpointID?
    private var tasks: [Task<Void, Never>] = []
    private var detailsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "EPSampleTool", category: "app")

    init() {
        #if targetEnvironment(simulator)
        transport = MockEPDevice()
        isSimulatedDevice = true
        #else
        isSimulatedDevice = false
        do {
            transport = try CoreMIDITransport()
        } catch {
            transport = nil
            connection = .failed(error.localizedDescription)
        }
        #endif
    }

    var device: ConnectedDevice? {
        if case .connected(let d) = connection { d } else { nil }
    }

    var usedSlots: Set<Int> { Set(sounds.map(\.slot)) }

    // MARK: Discovery

    func start() {
        guard let transport, tasks.isEmpty else { return }
        connection = .searching
        tasks.append(Task { [weak self] in
            for await msg in transport.incoming {
                await self?.route(msg)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in transport.setupChanged {
                self?.setupChanged()
            }
        })
        // Keep probing while nothing is connected, like the web app's 4-second check.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeIfIdle()
                try? await Task.sleep(for: .seconds(4))
            }
        })
    }

    private func probeIfIdle() async {
        guard let transport, connection == .searching else { return }
        for dest in transport.destinations() {
            try? await transport.send(TESysEx.identityRequest, to: dest.id)
        }
    }

    private func setupChanged() {
        guard let transport else { return }
        if let destination, !transport.isConnected(destination: destination) {
            disconnect()
        }
        if connection == .searching {
            Task { await probeIfIdle() }
        }
    }

    private func route(_ msg: IncomingSysEx) async {
        if let identity = TESysEx.parseIdentityReply(msg.bytes) {
            // Don't await: connecting needs this loop to keep delivering the device's replies.
            Task { await connect(source: msg.source, identity: identity) }
            return
        }
        if let client, msg.source == client.source {
            await client.handle(msg.bytes)
        }
    }

    private func connect(source: EndpointID, identity: TESysEx.Identity) async {
        guard let transport, connection == .searching,
              let dest = transport.destination(pairedWith: source) else { return }
        let portName = transport.destinations().first { $0.id == dest }?.name ?? "USB MIDI"
        connection = .connecting(portName)

        let client = TEClient(transport: transport, destination: dest, source: source, deviceID: identity.deviceID)
        self.client = client
        self.destination = dest
        do {
            let greet = try await client.request(.greet)
            let meta = DeviceMetadata(greeting: String(decoding: greet.data, as: UTF8.self))
            let sku = meta.effectiveSKU.isEmpty ? identity.sku : meta.effectiveSKU
            guard let modelName = EPModel.supportedSKUs[sku] else {
                connection = .unsupported(portName)
                return
            }
            let service = DeviceService(files: FileClient(client: client))
            try await service.prepare()
            self.service = service
            connection = .connected(ConnectedDevice(
                modelName: modelName, sku: sku, metadata: meta, portName: portName,
                firmwareTooOld: EPModel.isFirmwareTooOld(sku: sku, version: meta.osVersion)
            ))
            listenForFileEvents(client)
            await reloadLibrary()
        } catch {
            log.error("connect failed: \(error.localizedDescription)")
            await client.cancelAll()
            self.client = nil
            self.destination = nil
            connection = .searching
            errorMessage = "Couldn't talk to the device: \(error.localizedDescription)"
        }
    }

    private func disconnect() {
        detailsTask?.cancel()
        refreshTask?.cancel()
        uploadTask?.cancel()
        if let client { Task { await client.cancelAll() } }
        client = nil
        service = nil
        destination = nil
        sounds = []
        playingSlot = nil
        uploads.removeAll { $0.progress.isActive }
        connection = .searching
    }

    /// Reloads the library when the device reports files added, removed or moved.
    private func listenForFileEvents(_ client: TEClient) {
        tasks.append(Task { [weak self] in
            for await event in client.events {
                guard event.command == TESysEx.Command.file.rawValue,
                      let kind = event.data.first.flatMap(TEFile.Event.init(rawValue:)),
                      kind != .metadataUpdated else { continue }
                self?.scheduleRefresh()
            }
        })
    }

    private func scheduleRefresh() {
        guard uploadTask == nil else { return } // the upload queue reloads when it finishes
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.reloadLibrary()
        }
    }

    // MARK: Library

    func reloadLibrary() async {
        guard let service else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            let fresh = try await service.listSounds()
            let known = Dictionary(uniqueKeysWithValues: sounds.map { ($0.slot, $0) })
            sounds = fresh.map { s in
                // Keep details already fetched if the file didn't change.
                if let old = known[s.slot], old.size == s.size, old.channels != nil { return old }
                return s
            }
            loadDetails()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches names and formats one sound at a time in the background.
    private func loadDetails() {
        detailsTask?.cancel()
        guard let service else { return }
        let pending = sounds.filter { $0.channels == nil }
        detailsTask = Task { [weak self] in
            for sound in pending {
                if Task.isCancelled { return }
                guard let detailed = try? await service.details(for: sound) else { continue }
                guard let self, let i = self.sounds.firstIndex(where: { $0.slot == sound.slot && $0.size == sound.size }) else { continue }
                self.sounds[i] = detailed
            }
        }
    }

    func nextFreeSlots(_ count: Int, from start: Int = 1) -> [Int] {
        let used = usedSlots.union(uploads.filter(\.progress.isActive).map(\.slot))
        return Array(DeviceService.slotRange.filter { $0 >= start && !used.contains($0) }.prefix(count))
    }

    // MARK: Actions

    /// Queues files for upload into the next free slots (starting at `slot` if given).
    func upload(_ urls: [URL], startingAt slot: Int? = nil) {
        let slots = nextFreeSlots(urls.count, from: slot ?? 1)
        guard slots.count == urls.count else {
            errorMessage = DeviceServiceError.libraryFull.localizedDescription
            return
        }
        uploads.removeAll { !$0.progress.isActive }
        var jobs: [(URL, UUID)] = []
        for (url, slot) in zip(urls, slots) {
            let item = UploadItem(fileName: url.lastPathComponent, slot: slot, progress: .queued)
            uploads.append(item)
            jobs.append((url, item.id))
        }
        let previous = uploadTask
        uploadTask = Task { [weak self] in
            await previous?.value
            await self?.runUploads(jobs)
        }
    }

    private func runUploads(_ jobs: [(URL, UUID)]) async {
        detailsTask?.cancel()
        for (url, id) in jobs {
            guard let service, let slot = uploads.first(where: { $0.id == id })?.slot else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try await service.upload(url, toSlot: slot) { [weak self] p in
                    Task { @MainActor in self?.setProgress(id, p) }
                }
                setProgress(id, .done)
            } catch {
                setProgress(id, .failed(error.localizedDescription))
            }
        }
        uploadTask = nil
        await reloadLibrary()
    }

    private func setProgress(_ id: UUID, _ p: UploadProgress) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        // Late progress callbacks must not overwrite a final state.
        if case .done = uploads[i].progress { return }
        if case .failed = uploads[i].progress { return }
        uploads[i].progress = p
    }

    func clearFinishedUploads() {
        uploads.removeAll { !$0.progress.isActive }
    }

    func delete(_ sound: Sound) async {
        guard let service else { return }
        do {
            try await service.delete(slot: sound.slot)
            sounds.removeAll { $0.slot == sound.slot }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ sound: Sound, to name: String) async {
        guard let service else { return }
        do {
            let clean = try await service.rename(slot: sound.slot, to: name)
            if let i = sounds.firstIndex(where: { $0.slot == sound.slot }) { sounds[i].name = clean }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayback(_ sound: Sound) async {
        guard let service else { return }
        do {
            if playingSlot == sound.slot {
                try await service.stop(slot: sound.slot)
                playingSlot = nil
            } else {
                if let current = playingSlot { try? await service.stop(slot: current) }
                try await service.play(slot: sound.slot)
                playingSlot = sound.slot
                // The device doesn't report when a preview ends; clear the indicator after its length.
                let length = sound.duration ?? 2
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(min(length, 40) + 0.2))
                    if self?.playingSlot == sound.slot { self?.playingSlot = nil }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
