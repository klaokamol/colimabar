import XCTest
@testable import ColimaBar

final class ComposeProjectTests: XCTestCase {
    func testParsesComposeLsJSON() {
        let output = #"[{"Name":"cbdemo","Status":"running(1)","ConfigFiles":"/tmp/demo/compose.yml"}]"#
        XCTAssertEqual(ComposeProject.parseList(output), [ComposeProject(name: "cbdemo", status: "running(1)", configFiles: "/tmp/demo/compose.yml")])
    }

    func testParentFolderIsRepoAboveComposeDir() {
        let output = #"[{"Name":"web","Status":"running(5)","ConfigFiles":"/x/taxhero/web/docker-compose.yml,/x/taxhero/web/docker-compose.override.yml"}]"#
        let project = ComposeProject.parseList(output)[0]
        XCTAssertEqual(project.folderLabel, "taxhero")
        XCTAssertEqual(project.configPaths.count, 2)
        XCTAssertEqual(project.runningCount, 5)
    }

    func testWorktreesOfOneRepoShareItsName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("repo-328p1")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/repo-328p1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("infra"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("infra"), withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/repo-328p1\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let files = "\(worktree.path)/infra/docker-compose.yml,\(main.path)/infra/docker-compose.yml"
        XCTAssertEqual(ComposeProject(name: "infra", status: "running(2)", configFiles: files).folderLabel, "repo")
    }

    func testRunningCountFromMixedStatus() {
        XCTAssertEqual(ComposeProject(name: "a", status: "exited(1), running(3)", configFiles: nil).runningCount, 3)
        XCTAssertNil(ComposeProject(name: "a", status: "exited(1)", configFiles: nil).runningCount)
    }

    func testEmptyOrGarbageYieldsNoProjects() {
        XCTAssertEqual(ComposeProject.parseList("[]"), [])
        XCTAssertEqual(ComposeProject.parseList("Cannot connect to the Docker daemon"), [])
    }
}
