import FoundationModels

@available(macOS 26.0, *)
actor SentenceRefiner {
    static let shared = SentenceRefiner()

    nonisolated static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func refine(_ text: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: "입력한 문장을 자연스럽고 명확하게 다듬으세요. 설명, 인사, 따옴표 없이 다듬은 문장만 출력하세요."
        )
        return try await session.respond(to: text).content
    }
}
