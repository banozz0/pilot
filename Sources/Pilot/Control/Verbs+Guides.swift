import Foundation
import PilotCore

extension ControlVerbs {
    /// The AI agent's skills read as guides (Ask Pilot, Sven Q180, 2026-10-16; skills since P29, Q268): one per kind of
    /// job, read with `pilot guide <name>` only when the job comes up, so the prompt (Packaging/pilot-agent.md) carries one
    /// line per skill and no more. The agent runs with skills off and only `pilot` to call (AIChat.Agent.claudeArguments),
    /// so the skills come through the verb, their bodies alone: AISkills.guides, the old topic names included.
    func registerGuides(skills: @escaping @Sendable @MainActor () -> [AISkill] = { AISkills.guides }) {
        register(ControlVerb("guide", help: "How to go about one kind of job, for Pilot's AI helper: binds, preset, layouts, settings, explain, troubleshoot, catalogue, theme.",
                             usage: "pilot guide [<topic>]", flags: []) { call throws(ControlError) in
            let skills = skills()
            guard !skills.isEmpty else { throw ControlError(.notReady, "Pilot's skills are missing from the app") }
            guard let word = call.words.first else {
                return .string(ControlVerb.columns(skills.map { ($0.name, $0.when) }).joined(separator: "\n"))
            }
            // Only a listed name is read, so no word reaches past the skills' folder.
            let name = AISkills.renamed[word] ?? word
            guard let skill = skills.first(where: { $0.name == name }) else {
                throw ControlError(.badValue, "no guide \(word); guides: \(skills.map(\.name).joined(separator: ", "))")
            }
            return .string(skill.body)
        })
    }
}
