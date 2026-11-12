import Foundation

@MainActor
final class DirectoryWatcher {
    private let root: URL
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
        rebuild()
    }

    deinit {
        debounceTask?.cancel()
        sources.forEach { $0.cancel() }
    }

    nonisolated static func watchedDirectories(for root: URL, fileManager: FileManager = .default) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else {
            var anchor = root.deletingLastPathComponent()
            while !fileManager.fileExists(atPath: anchor.path), anchor.path != "/" {
                anchor = anchor.deletingLastPathComponent()
            }
            return [anchor]
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        return [root.deletingLastPathComponent(), root] + children
    }

    private func rebuild() {
        sources.forEach { $0.cancel() }
        sources = Self.watchedDirectories(for: root).compactMap(makeSource)
    }

    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.changed()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            rebuild()
            onChange()
        }
    }
}
