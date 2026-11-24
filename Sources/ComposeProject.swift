import Foundation

struct ComposeProject: Decodable, Equatable {
    let name: String
    let status: String
    let configFiles: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case status = "Status"
        case configFiles = "ConfigFiles"
    }

    var configPaths: [String] {
        configFiles?.split(separator: ",").map(String.init) ?? []
    }

    var runningCount: Int? {
        guard let range = status.range(of: #"running\((\d+)\)"#, options: .regularExpression) else { return nil }
        return Int(status[range].filter(\.isNumber))
    }

    var folderLabel: String? {
        var names: [String] = []
        for path in configPaths {
            let name = Self.repoName(composeDir: URL(fileURLWithPath: path).deletingLastPathComponent())
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? nil : names.joined(separator: " + ")
    }

    static func repoName(composeDir: URL) -> String {
        var dir = composeDir
        while dir.pathComponents.count > 1 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                if !isDir.boolValue,
                   let content = try? String(contentsOf: git, encoding: .utf8),
                   let range = content.range(of: "/.git/worktrees/") {
                    let mainRepo = content[..<range.lowerBound].replacingOccurrences(of: "gitdir: ", with: "")
                    return URL(fileURLWithPath: mainRepo).lastPathComponent
                }
                return dir.lastPathComponent
            }
            dir = dir.deletingLastPathComponent()
        }
        return composeDir.deletingLastPathComponent().lastPathComponent
    }

    static func parseList(_ output: String) -> [ComposeProject] {
        guard let data = output.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ComposeProject].self, from: data)) ?? []
    }

    // ponytail: assumes ~/.colima, ignores COLIMA_HOME; read it from the user's shell if needed
    static func dockerHost(profile: String) -> String {
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".colima/\(profile)/docker.sock").path
        return "unix://\(socket)"
    }
}

struct ComposeTarget {
    let profile: String
    let project: String
}
