import Foundation

// MARK: - Switch Question v1

// Mirrors the JSON payload sent by Switch in:
// <meta xmlns="urn:switch:message-meta" type="question"> <payload format="json">...</payload>

public struct SwitchQuestionEnvelopeV1: Codable, Hashable, Sendable {
    public let version: Int?
    public let engine: String?
    public let requestId: String
    public let questions: [SwitchQuestionV1]

    public init(version: Int? = 1, engine: String? = nil, requestId: String, questions: [SwitchQuestionV1]) {
        self.version = version
        self.engine = engine
        self.requestId = requestId
        self.questions = questions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case engine
        case requestId = "request_id"
        case questions
    }
}

public struct SwitchQuestionV1: Codable, Hashable, Sendable {
    public let header: String?
    public let question: String?
    public let options: [SwitchQuestionOptionV1]?
    public let multiple: Bool?

    public init(header: String? = nil, question: String? = nil, options: [SwitchQuestionOptionV1]? = nil, multiple: Bool? = nil) {
        self.header = header
        self.question = question
        self.options = options
        self.multiple = multiple
    }
}

public struct SwitchQuestionOptionV1: Codable, Hashable, Sendable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct SwitchQuestionReplyEnvelopeV1: Codable, Hashable, Sendable {
    public let version: Int?
    public let requestId: String
    public let answers: [[String]]?
    public let text: String?

    public init(version: Int? = 1, requestId: String, answers: [[String]]? = nil, text: String? = nil) {
        self.version = version
        self.requestId = requestId
        self.answers = answers
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestId = "request_id"
        case answers
        case text
    }
}
