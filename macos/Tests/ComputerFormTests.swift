import Foundation
import Testing

@testable import Latchkey

/// Background control of a web form (bug report 2026-11-03, spec 006 FR-511 to FR-514): keys go
/// only where the focus really is, the answer says what the field holds and what else changed,
/// dropdowns are chosen by name, and long windows are listed in parts.
@Suite struct ComputerFormTests {
    /// A pretend app: its window's elements and values can change as the test acts.
    final class Form: @unchecked Sendable {
        private let lock = NSLock()
        var items: [AppElement]
        var values: [String: String] = [:]
        var focusOn: String?
        var refuseFocus: Set<String> = []
        var pressed: [String] = []
        /// What a press does: change values or show more elements.
        var onPress: [String: (Form) -> Void] = [:]
        var onType: ((Form, String) -> Void)?

        init(_ items: [AppElement]) { self.items = items }
        func with<T>(_ body: (Form) -> T) -> T { lock.withLock { body(self) } }
    }

    final class TypingPoster: InputPoster, @unchecked Sendable {
        let form: Form
        private(set) var typed: [String] = []
        init(_ form: Form) { self.form = form }
        func post(_ e: InputEvent) {
            guard case .text(let s) = e else { return }
            typed.append(s)
            form.with { f in
                if let on = f.focusOn { f.values[on, default: ""] += s }
                f.onType?(f, s)
            }
        }
    }

    static func el(_ ref: String, _ role: String, _ label: String, value: String? = nil, parent: String? = nil)
        -> AppElement
    {
        AppElement(ref: ref, role: role, label: label, value: value, element: nil, parent: parent)
    }

    func env(_ form: Form, pid: pid_t) -> (ComputerEnvironment, TypingPoster) {
        let poster = TypingPoster(form)
        var e = ComputerToolTests().env(FakeScreen(), FakePoster())
        e.settle = .milliseconds(1)
        e.appControl = AppControl(
            find: { $0.lowercased() == "safari" ? AppTarget(name: "Safari", pid: pid) : nil },
            elements: { _ in
                form.with { f in
                    AppListing(
                        items: f.items.map {
                            var x = $0; x.value = f.values[$0.ref] ?? $0.value; return x
                        })
                }
            },
            press: { el in
                form.with { f in
                    f.pressed.append(el.ref)
                    f.onPress[el.ref]?(f)
                }
                return true
            },
            focus: { el in
                form.with { f in if !f.refuseFocus.contains(el.ref) { f.focusOn = el.ref } }
                return true  // as macOS: yes, whether or not it did
            },
            poster: { _ in poster },
            picture: { _ in PreparedImage(data: NotesFixture.pngPixel, mimeType: "image/png") },
            focusCheck: { _, el in
                form.with { f in
                    f.focusOn == el.ref
                        ? .inside
                        : .elsewhere(
                            f.focusOn.map { r in "AXPopUpButton \"\(f.items.first { $0.ref == r }?.label ?? r)\"" }
                                ?? "nothing")
                }
            },
            focused: { _ in form.with { f in f.focusOn.map { "AXTextField \"\($0)\"" } } },
            value: { el in form.with { f in f.values[el.ref] ?? f.items.first { $0.ref == el.ref }?.value } })
        return (e, poster)
    }

    func act(_ e: ComputerEnvironment, _ args: [String: JSONValue]) async -> ToolResult {
        let tool = ComputerCapability.writeTools(env: e).first { $0.tool.name == "computer_act" }!
        return await tool.handler(.object(args.merging(["app": .string("Safari")]) { a, _ in a }))
    }

    func look(_ e: ComputerEnvironment, _ args: [String: JSONValue] = [:]) async -> ToolResult {
        let tool = ComputerCapability.readTools(env: e).first { $0.tool.name == "computer_look" }!
        return await tool.handler(
            .object(args.merging(["app": .string("Safari"), "show": .string("ui")]) { a, _ in a }))
    }

    static let page: [AppElement] = [
        el("e1", "AXTextField", "City", value: ""),
        el("e2", "AXPopUpButton", "Country", value: "Finland"),
        el("e3", "AXComboBox", "State", value: ""),
        el("e4", "AXCheckBox", "Claim", value: "0"),
        el("e5", "AXCheckBox", "Claim", value: "0"),
        el("e6", "AXStaticText", "", value: "Payment"),
    ]

    @Test func typingWhereTheFocusWontGoTypesNothing() async {
        let form = Form(Self.page)
        form.focusOn = "e2"
        form.refuseFocus = ["e3"]
        let (e, poster) = env(form, pid: 9101)
        _ = await look(e)
        let r = await act(e, ["action": .string("type"), "ref": .string("e3"), "text": .string("California")])
        #expect(r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("didn't take the keyboard focus"), "\(r.plainText)")
        #expect(r.plainText.contains("Country"), "says where the focus is: \(r.plainText)")
        #expect(r.plainText.contains("nothing was typed"))
        #expect(poster.typed.isEmpty)
        #expect(form.values["e2"] == nil, "the dropdown that had the focus got no keys")
    }

    /// Live check 2026-11-03: an app behind others names no focused element; the flags say.
    @Test func whereTheFocusIsComesFromTheFlagsWhenTheAppSaysNothing() async {
        let form = Form(Self.page)
        form.focusOn = "e1"
        form.refuseFocus = ["e6"]
        var (e, poster) = env(form, pid: 9112)
        e.appControl.focused = { _ in nil }
        e.appControl.focusCheck = { _, el in form.with { $0.focusOn == el.ref } ? .inside : .elsewhere("nothing") }
        e.appControl.isFocused = { el in form.with { $0.focusOn == el.ref } }
        _ = await look(e)
        let r = await act(e, ["action": .string("type"), "ref": .string("e6"), "text": .string("x")])
        #expect(r.isError && r.plainText.contains("(it is on e1 AXTextField \"City\")"), "\(r.plainText)")
        #expect(poster.typed.isEmpty)
        let k = await act(e, ["action": .string("key"), "keys": .string("tab")])
        #expect(k.plainText.contains("where the keyboard focus is: e1 AXTextField \"City\""), "\(k.plainText)")
    }

    /// Live check 2026-11-03: a WebKit app just started lists only its title bar on the first
    /// look, its page once asked again; Chrome-style apps need their accessibility switched on.
    @Test func aFirstLookWithOnlyTheTitleBarLooksAgain() async {
        let form = Form(Self.page)
        var (e, _) = env(form, pid: 9113)
        let woken = Locked(0)
        let looks = Locked(0)
        e.appControl.wake = { _ in woken.mutate { $0 += 1 } }
        e.appControl.elements = { _ in
            looks.mutate { $0 += 1 }
            return looks.value == 1
                ? AppListing(items: [
                    Self.el("e1", "AXWindow", "FormLab"), Self.el("e2", "AXButton", ""), Self.el("e3", "AXButton", ""),
                ]) : AppListing(items: Self.page)
        }
        let r = await look(e)
        #expect(r.plainText.contains("AXComboBox \"State\""), "\(r.plainText)")
        #expect(woken.value == 1 && looks.value == 2)
        let again = await look(e)  // a full look isn't repeated
        #expect(!again.isError && looks.value == 3 && woken.value == 1)
    }

    @Test func typingSaysTheValueNow() async {
        let form = Form(Self.page)
        let (e, _) = env(form, pid: 9102)
        _ = await look(e)
        let r = await act(e, ["action": .string("type"), "ref": .string("e1"), "text": .string("Oakland")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("e1's value now: \"Oakland\""), "\(r.plainText)")
    }

    @Test func typingWithoutARefSaysWhereTheKeysWent() async {
        let form = Form(Self.page)
        form.focusOn = "e1"
        let (e, _) = env(form, pid: 9103)
        _ = await look(e)
        let r = await act(e, ["action": .string("type"), "text": .string("x")])
        #expect(r.plainText.contains("where the keyboard focus is: AXTextField \"e1\""), "\(r.plainText)")
    }

    @Test func whatElseChangedIsTold() async {
        let form = Form(Self.page)
        form.onPress["e3"] = { f in
            f.values["e4"] = "1"
            f.values["e5"] = "1"
        }
        let (e, _) = env(form, pid: 9104)
        _ = await look(e)
        let r = await act(e, ["action": .string("press"), "ref": .string("e3")])
        #expect(r.plainText.contains("Also changed in the window"), "\(r.plainText)")
        #expect(r.plainText.contains("e4 AXCheckBox \"Claim\": \"0\" → \"1\""), "\(r.plainText)")
        #expect(r.plainText.contains("e5 AXCheckBox"), "\(r.plainText)")
        #expect(!r.plainText.contains("e3 AXComboBox \"State\": "), "the pressed one is not 'also'")
    }

    @Test func aNativeDropdownIsChosenByTypingItsName() async {
        let form = Form(Self.page)
        form.onType = { f, s in
            if f.focusOn == "e2" {
                f.values["e2"] =
                    ["Finland", "Sweden", "United States"].first { $0.lowercased().hasPrefix(s.lowercased()) }
                    ?? "Finland"
            }
        }
        let (e, _) = env(form, pid: 9105)
        _ = await look(e)
        let r = await act(e, ["action": .string("choose"), "ref": .string("e2"), "option": .string("united states")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("Chose \"United States\""), "\(r.plainText)")
        #expect(form.pressed.isEmpty, "the menu was never opened over the owner's screen")
        let wrong = await act(e, ["action": .string("choose"), "ref": .string("e2"), "option": .string("Norway")])
        #expect(wrong.isError && wrong.plainText.contains("no choice called \"Norway\""), "\(wrong.plainText)")
    }

    @Test func aWebDropdownIsPressedOpenAndItsOptionPressed() async {
        let form = Form(Self.page)
        form.onPress["e3"] = { f in
            f.items += [
                Self.el("e7", "AXList", "", parent: "e3"),
                Self.el("e8", "AXStaticText", "Arizona", value: "Arizona", parent: "e7"),
                Self.el("e9", "AXStaticText", "California", value: "California", parent: "e7"),
            ]
        }
        form.onPress["e9"] = { f in f.values["e3"] = "California" }
        let (e, poster) = env(form, pid: 9106)
        _ = await look(e)
        let r = await act(e, ["action": .string("choose"), "ref": .string("e3"), "option": .string("California")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(form.pressed == ["e3", "e9"])
        #expect(r.plainText.contains("its value now: \"California\""), "\(r.plainText)")
        #expect(poster.typed.isEmpty)
    }

    @Test func aDropdownThatListsWhatIsTypedGetsTheNameTyped() async {
        let form = Form(Self.page)
        form.onType = { f, s in
            if f.focusOn == "e3", s == "Texas" {
                f.items += [
                    Self.el("e7", "AXList", "", parent: "e3"),
                    Self.el("e8", "AXStaticText", "", value: "Texas", parent: "e7"),
                ]
            }
        }
        form.onPress["e8"] = { f in f.values["e3"] = "Texas" }
        let (e, _) = env(form, pid: 9107)
        _ = await look(e)
        let r = await act(e, ["action": .string("choose"), "ref": .string("e3"), "option": .string("Texas")])
        #expect(!r.isError, "\(r.plainText)")
        #expect(form.pressed == ["e3", "e8"])
    }

    @Test func aDropdownWithoutTheOptionSaysSo() async {
        let form = Form(Self.page)
        let (e, _) = env(form, pid: 9108)
        _ = await look(e)
        let r = await act(e, ["action": .string("choose"), "ref": .string("e4"), "option": .string("Guam")])
        #expect(r.isError && r.plainText.contains("no choice called \"Guam\" showed"), "\(r.plainText)")
    }

    @Test func chooseNeedsAnApp() async {
        let form = Form(Self.page)
        let (e, _) = env(form, pid: 9109)
        let tool = ComputerCapability.writeTools(env: e).first { $0.tool.name == "computer_act" }!
        let r = await tool.handler(.object(["action": .string("choose"), "ref": .string("e3")]))
        #expect(r.isError && r.plainText.contains("choose needs app"))
    }

    @Test func aLongWindowIsListedInPartsFromOneLook() async {
        var items: [AppElement] = []
        for i in 1...650 { items.append(Self.el("e\(i)", "AXTextField", "Field \(i)", value: "")) }
        let form = Form(items)
        let (e, _) = env(form, pid: 9110)
        let first = await look(e)
        #expect(first.plainText.contains("[e300]") && !first.plainText.contains("[e301]"))
        #expect(first.plainText.contains("the same with after e300"), "\(first.plainText.suffix(300))")
        form.with { f in f.items.removeFirst() }  // the window changed; the references must not
        let second = await look(e, ["after": .string("e300")])
        #expect(second.plainText.contains("[e301] AXTextField \"Field 301\""), "\(second.plainText.prefix(400))")
        #expect(second.plainText.contains("From the look at Safari's window"))
        let last = await look(e, ["after": .string("e600")])
        #expect(last.plainText.contains("[e650]") && !last.plainText.contains("More follows"))
        let matched = await look(e, ["match": .string("Field 64")])
        #expect(matched.plainText.contains("[e64]") && matched.plainText.contains("[e640]"))
        #expect(!matched.plainText.contains("[e65]"))
    }
}

@Suite struct AppListingTests {
    typealias T = ComputerFormTests

    @Test func repeatedLabelTextIsLeftOut() {
        let l = AppListing(items: [
            T.el("e1", "AXStaticText", "", value: "First Name "),
            T.el("e2", "AXStaticText", "", value: "First Name"),
            T.el("e3", "AXTextField", "First Name", value: ""),
            T.el("e4", "AXComboBox", "State", value: "Cal"),
            T.el("e5", "AXStaticText", "", value: "Cal", parent: "e4"),
            T.el("e6", "AXStaticText", "", value: "Total due"),
            T.el("e7", "AXStaticText", "", value: "Total due"),
            T.el("e8", "AXButton", "Submit"),
        ])
        #expect(l.page().shown.map(\.ref) == ["e3", "e4", "e6", "e8"])
    }

    @Test func withinListsOnlyWhatIsInside() {
        let l = AppListing(items: [
            T.el("e1", "AXGroup", "Payment"),
            T.el("e2", "AXRadioButton", "Zelle", parent: "e1"),
            T.el("e3", "AXGroup", "Inner", parent: "e1"),
            T.el("e4", "AXRadioButton", "Check", parent: "e3"),
            T.el("e5", "AXButton", "Submit"),
        ])
        #expect(l.page(within: "e1").shown.map(\.ref) == ["e2", "e3", "e4"])
        #expect(l.page(within: "e3").shown.map(\.ref) == ["e4"])
        #expect(l.page(match: "submit").shown.map(\.ref) == ["e5"])
    }

    @Test func aCutWalkIsSaid() async {
        let form = ComputerFormTests.Form([T.el("e1", "AXButton", "A")])
        var (e, _) = ComputerFormTests().env(form, pid: 9111)
        e.appControl.elements = { _ in AppListing(items: [T.el("e1", "AXButton", "A")], cut: true) }
        let r = await ComputerFormTests().look(e)
        #expect(r.plainText.contains("has more than Latchkey reads in one look"), "\(r.plainText)")
    }
}
