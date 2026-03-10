// CommandRegistry.swift
// Calyx
//
// Registers and searches commands for the command palette.

import Foundation

@MainActor
class CommandRegistry {

    private var commands: [Command] = []
    private var frequencyMap: [String: Int] = [:]

    func register(_ command: Command) {
        commands.append(command)
    }

    func search(query: String) -> [Command] {
        let scored = commands.compactMap { cmd -> (Command, Int)? in
            guard cmd.isAvailable() else { return nil }
            let matchScore = FuzzyMatcher.score(query: query, candidate: cmd.title)
            guard matchScore > 0 else { return nil }
            let freqBoost = frequencyMap[cmd.id, default: 0]
            return (cmd, matchScore + freqBoost)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func recordUsage(_ commandID: String) {
        frequencyMap[commandID, default: 0] += 1
    }

    var allCommands: [Command] { commands }
}
