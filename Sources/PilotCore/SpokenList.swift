/// Names as a sentence lists them: "Slack", "Slack and Discord", "Slack, Discord and Mail"; `joiner` "or" for a choice.
public func spokenList(_ names: [String], joiner: String = "and") -> String {
    guard let last = names.last else { return "" }
    return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " \(joiner) " + last
}
