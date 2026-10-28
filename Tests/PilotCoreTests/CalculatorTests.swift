import Testing
@testable import PilotCore

/// Card agent-bo-95422933: sums and conversions answered at the menu's root.
@Suite("Calculator")
struct CalculatorTests {
    @Test("Arithmetic: + - * / ^ %, brackets, unary minus, a decimal comma, × and ÷")
    func arithmetic() {
        let sums = ["12*49": "588", "2^10": "1024", "(1+2)*3": "9", "7/2": "3.5", "-3+5": "2", "1,5*2": "3", "10 % 3": "1",
                    "6 × 7": "42", "9 ÷ 4": "2.25", "2^3^2": "512", "1/3": "0.3333333333"]
        for (sum, want) in sums { #expect(Calculator.answer(sum) == want, "\(sum)") }
    }

    @Test("Conversions: a number, a unit, in or to, a unit of the same kind")
    func conversions() {
        #expect(Calculator.answer("5 km in mi") == "3.106855961 mi")
        #expect(Calculator.answer("100 f to c") == "37.77777778 c")
        #expect(Calculator.answer("1 gb in mb") == "1000 mb")
        #expect(Calculator.answer("12 in to cm") == "30.48 cm")
        // Foundation's pound is 0.453592 kg, not the exact 0.45359237, so the sixth digit differs from a hand sum.
        #expect(Calculator.answer("2.5kg in lb") == "5.51156105 lb")
    }

    @Test("No answer for a bare number, a word, mixed kinds, division by zero or broken sums")
    func noAnswer() {
        for text in ["42", "-42", "2024-10-06", "firefox", "5 km in kg", "1/0", "2**3", "(1+2", "", "tr hola", "5 km in", "in to"] {
            #expect(Calculator.answer(text) == nil, "\(text)")
        }
    }

    @Test("At the root the answer is the first row over a matching app, Return copies it, and an action row stays")
    func root() throws {
        let app = MenuEntry(title: "Calculator", target: .app("com.apple.calculator"), home: .apps)
        let unbound = MenuEntry(title: "12*49 grid", target: .action("windows.grid"))
        var nav = MenuNavigator(entries: [app, unbound])
        nav.query = "12*49"
        let answer = try #require(Calculator.entries(for: "12*49").first)
        #expect(answer.isAnswer && answer.frecencyKey == nil && answer.kind == .answer)
        nav.provide(.answer, [answer])
        #expect(nav.rows.first == answer)
        #expect(nav.handle(.return) == .run(answer))
        #expect(answer.target == .copy("588"))
        #expect(nav.rows.contains(unbound), "an unbound action matching the same search stays listed beside the answer")
        nav.provide(.answer, [])
        #expect(nav.rows.contains(unbound) && !nav.rows.contains(answer), "taking the answer away leaves the action")
    }
}
