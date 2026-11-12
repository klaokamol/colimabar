import XCTest
@testable import ColimaBar

final class ComposeProjectTests: XCTestCase {
    func testParsesComposeLsJSON() {
        let output = #"[{"Name":"cbdemo","Status":"running(1)","ConfigFiles":"/tmp/demo/compose.yml"}]"#
        XCTAssertEqual(ComposeProject.parseList(output), [ComposeProject(name: "cbdemo", status: "running(1)")])
    }

    func testEmptyOrGarbageYieldsNoProjects() {
        XCTAssertEqual(ComposeProject.parseList("[]"), [])
        XCTAssertEqual(ComposeProject.parseList("Cannot connect to the Docker daemon"), [])
    }
}
