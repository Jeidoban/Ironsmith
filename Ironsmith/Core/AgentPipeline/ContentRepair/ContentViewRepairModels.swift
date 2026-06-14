import Foundation

struct ContentViewRepairSnippet: Equatable, Sendable {
    let startLine: Int
    let endLine: Int
    let text: String
}

struct RepairRootCauseKey: Equatable, Sendable {
    let kind: String
    let value: String
    let isBatchable: Bool
}
