import Foundation
import Testing

@testable import Latchkey

@Suite struct CapabilityTests {
    static let readTool = Tool.make("demo_read", title: "Read", description: "Reads.", readOnly: true)
    static let writeTool = Tool.make(
        "demo_write", title: "Write", description: "Writes.", readOnly: false, destructive: true)

    static func registry(_ level: AccessLevel) -> CapabilityRegistry {
        let cap = Capability(
            id: "demo", title: "Demo", summary: "",
            readTools: [ToolEntry(tool: readTool, handler: { _ in .text("read") })],
            writeTools: [ToolEntry(tool: writeTool, handler: { _ in .text("wrote") })])
        return CapabilityRegistry(capabilities: [cap], levels: ["demo": level])
    }

    @Test func levelsDecideWhichToolsExist() {
        #expect(Self.registry(.off).tools.isEmpty, "Constitution III")
        #expect(Self.registry(.readOnly).tools.map(\.name) == ["demo_read"])
        #expect(Self.registry(.readWrite).tools.map(\.name) == ["demo_read", "demo_write"])
    }

    @Test func toolsOutsideTheLevelCannotBeCalled() async {
        let result = await Self.registry(.readOnly).call(tool: "demo_write", arguments: .object([:]))
        #expect(result.isError)
        let ok = await Self.registry(.readWrite).call(tool: "demo_write", arguments: .object([:]))
        #expect(!ok.isError)
    }

    @Test func everyToolDeclaresBothHints() {
        // Claude requires readOnlyHint and destructiveHint on every tool.
        for tool in [Self.readTool, Self.writeTool] {
            #expect(tool.annotations?.readOnlyHint != nil)
            #expect(tool.annotations?.destructiveHint != nil)
        }
    }

    @Test func everythingStartsFullyOn() {
        // Spec 002 FR-121, specs 003–006 (Toni, 2026-10-22).
        #expect(Set(CapabilityRegistry.defaultLevels.keys) == Set(CapabilityRegistry.all))
        #expect(CapabilityRegistry.defaultLevels.values.allSatisfy { $0 == .readWrite })
    }

    @Test func activityTitles() {
        let e = TraceEntry(
            at: Date(), tool: "notes_create", arguments: "{}", result: "{}", isError: true, durationMS: 3)
        #expect(ActivityFormat.title(e).hasSuffix("notes create (failed)"))
        #expect(ActivityFormat.clip(String(repeating: "x", count: 200)).count == 80)
    }
}
