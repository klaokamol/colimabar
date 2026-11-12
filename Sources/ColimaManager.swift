import Foundation

enum ColimaStatus: String, Equatable {
    case running = "Running"
    case stopped = "Stopped"
    case starting = "Starting..."
    case stopping = "Stopping..."
    case deleting = "Deleting..."
    case unknown = "Unknown"

    var isRunning: Bool { self == .running }
    var isStopped: Bool { self == .stopped }
    var isTransitioning: Bool { self == .starting || self == .stopping || self == .deleting }
}

struct ColimaInstance: Identifiable, Equatable {
    let id: String
    let name: String
    var status: ColimaStatus
    let arch: String
    let cpus: Int
    let memory: UInt64
    let disk: UInt64

    var memoryFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)
    }

    var diskFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(disk), countStyle: .file)
    }
}

enum LoadState: Equatable {
    case loading
    case loaded
    case error(String)
}

@MainActor
final class ColimaManager: ObservableObject {
    @Published private(set) var instances: [ColimaInstance] = []
    @Published private(set) var loadState: LoadState = .loading
    /// Set when a start/stop command fails; cleared on the next successful
    /// action or refresh. Surfaced in the menu so failures are not silent.
    @Published private(set) var actionError: String?
    @Published private(set) var composeProjects: [String: [ComposeProject]] = [:]

    private let colimaPath: String
    private var statusCheckTimer: Timer?
    private var watcher: DirectoryWatcher?
    private var listed: [ColimaInstance] = [] { didSet { publishInstances() } }
    private var pending: [String: ColimaInstance] = [:] { didSet { publishInstances() } }
    private var reloadGeneration = 0
    // ponytail: watches only ~/.colima/_lima, ignores COLIMA_HOME/LIMA_HOME; read them from the user's shell if needed
    private static let limaHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".colima/_lima", isDirectory: true)

    var hasRunningInstance: Bool {
        instances.contains { $0.status.isRunning }
    }

    init() {
        self.colimaPath = Self.findColimaPath()
        startStatusChecking()
    }

    deinit {
        statusCheckTimer?.invalidate()
    }

    private static func findColimaPath() -> String {
        let possiblePaths = [
            "/opt/homebrew/bin/colima",
            "/usr/local/bin/colima",
            "/usr/bin/colima"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return "colima"
    }

    /// Auto-refresh interval in seconds, persisted across launches.
    /// Falls back to 5s when unset.
    static let refreshIntervalKey = "refreshInterval"

    var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
        return stored > 0 ? stored : 5.0
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: Self.refreshIntervalKey)
        scheduleTimer()
    }

    func startStatusChecking() {
        refreshInstances()
        scheduleTimer()
        watcher = DirectoryWatcher(root: Self.limaHome) { [weak self] in
            self?.refreshInstances()
        }
    }

    private func scheduleTimer() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInstances()
            }
        }
    }

    func refreshInstances() {
        Task { await reload() }
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let result = await runCommand([colimaPath, "ls", "--json"])
        guard generation == reloadGeneration else { return }
        if result.exitCode == 0 {
            listed = Self.parseInstances(result.output)
            loadState = .loaded
            actionError = nil
            await refreshComposeProjects()
        } else {
            loadState = .error(Self.friendlyError(from: result.output))
        }
    }

    private func publishInstances() {
        let next = Self.overlay(listed, pending: pending)
        if next != instances {
            instances = next
        }
    }

    /// Turn raw command output into a short, user-facing message. `colima ls`
    /// failing usually means colima is missing from PATH or not installed.
    private static func friendlyError(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("no such file")
            || trimmed.lowercased().contains("not found") {
            return "Colima not found. Install with: brew install colima"
        }
        return trimmed
    }

    nonisolated static func overlay(_ listed: [ColimaInstance], pending: [String: ColimaInstance]) -> [ColimaInstance] {
        let shown = listed.map { instance in
            guard let action = pending[instance.name] else { return instance }
            var updated = instance
            updated.status = action.status
            return updated
        }
        let listedNames = Set(listed.map(\.name))
        let unlisted = pending.values
            .filter { !listedNames.contains($0.name) }
            .sorted { $0.name < $1.name }
        return shown + unlisted
    }

    nonisolated static func parseInstances(_ output: String) -> [ColimaInstance] {
        var results: [ColimaInstance] = []

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String,
                  let statusStr = json["status"] as? String else {
                continue
            }

            let status: ColimaStatus
            switch statusStr.lowercased() {
            case "running": status = .running
            case "stopped": status = .stopped
            default: status = .unknown
            }

            let instance = ColimaInstance(
                id: name,
                name: name,
                status: status,
                arch: json["arch"] as? String ?? "unknown",
                cpus: (json["cpus"] as? NSNumber)?.intValue ?? 0,
                memory: (json["memory"] as? NSNumber)?.uint64Value ?? 0,
                disk: (json["disk"] as? NSNumber)?.uint64Value ?? 0
            )
            results.append(instance)
        }

        return results
    }

    func start(profile: String) {
        transition(profile, "start", from: .stopped, showing: .starting)
    }

    func stop(profile: String) {
        transition(profile, "stop", from: .running, showing: .stopping)
    }

    func restart(profile: String) {
        transition(profile, "restart", from: .running, showing: .starting)
    }

    func startAll() {
        for instance in instances where instance.status.isStopped {
            start(profile: instance.name)
        }
    }

    func stopAll() {
        for instance in instances where instance.status.isRunning {
            stop(profile: instance.name)
        }
    }

    /// Create a new instance by starting a fresh profile with the given
    /// resources. colima takes CPUs as a count and memory/disk in GiB.
    func create(name: String, cpus: Int, memoryGiB: Int, diskGiB: Int) {
        guard !instances.contains(where: { $0.name == name }) else { return }
        let gib: UInt64 = 1 << 30
        let placeholder = ColimaInstance(
            id: name,
            name: name,
            status: .starting,
            arch: "unknown",
            cpus: cpus,
            memory: UInt64(max(memoryGiB, 0)) * gib,
            disk: UInt64(max(diskGiB, 0)) * gib
        )
        perform(placeholder, [
            "start", "-p", name,
            "--cpu", String(cpus),
            "--memory", String(memoryGiB),
            "--disk", String(diskGiB)
        ], failure: "Failed to create \(name)")
    }

    func delete(profile: String) {
        guard var instance = instances.first(where: { $0.name == profile }),
              !instance.status.isTransitioning else { return }
        instance.status = .deleting
        perform(instance, ["delete", "-p", profile, "-f"], failure: "Failed to delete \(profile)")
    }

    func shellCommand(profile: String) -> String {
        let quoted = "'" + profile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(colimaPath) ssh -p \(quoted)"
    }

    private func transition(_ profile: String, _ verb: String, from required: ColimaStatus, showing: ColimaStatus) {
        guard var instance = instances.first(where: { $0.name == profile }),
              instance.status == required else { return }
        instance.status = showing
        perform(instance, [verb, "-p", profile], failure: "Failed to \(verb) \(profile)")
    }

    private func perform(_ placeholder: ColimaInstance, _ arguments: [String], failure: String) {
        pending[placeholder.name] = placeholder
        Task {
            let result = await runCommand([colimaPath] + arguments)
            await reload()
            pending[placeholder.name] = nil
            if result.exitCode != 0 {
                actionError = failure
            }
        }
    }

    private func refreshComposeProjects() async {
        var projects: [String: [ComposeProject]] = [:]
        for instance in instances where instance.status.isRunning {
            let result = await runCommand([
                "docker", "-H", ComposeProject.dockerHost(profile: instance.name),
                "compose", "ls", "--format", "json"
            ])
            if result.exitCode == 0 {
                projects[instance.name] = ComposeProject.parseList(result.output)
            }
        }
        composeProjects = projects
    }

    func composeDown(_ target: ComposeTarget) {
        Task {
            let result = await runCommand([
                "docker", "-H", ComposeProject.dockerHost(profile: target.profile),
                "compose", "-p", target.project, "down"
            ])
            actionError = result.exitCode == 0 ? nil : "Failed to down \(target.project)"
            await refreshComposeProjects()
        }
    }

    private func runCommand(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe

                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = environment

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    let output = String(data: data, encoding: .utf8) ?? ""

                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Error: \(error.localizedDescription)", 1))
                }
            }
        }
    }
}
