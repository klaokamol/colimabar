import Foundation

struct ComposeProject: Decodable, Equatable {
    let name: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case status = "Status"
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
