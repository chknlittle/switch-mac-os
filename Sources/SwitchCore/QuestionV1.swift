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

    private enum AltCodingKeys: String, CodingKey {
        case requestId
        case requestIdSnake = "request_id"
        case questions
    }

    public init(from decoder: Decoder) throws {
        // Be tolerant: some senders may use requestId instead of request_id.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.engine = try container.decodeIfPresent(String.self, forKey: .engine)

        if let rid = try container.decodeIfPresent(String.self, forKey: .requestId) {
            self.requestId = rid
        } else {
            let alt = try decoder.container(keyedBy: AltCodingKeys.self)
            if let rid = try alt.decodeIfPresent(String.self, forKey: .requestId) {
                self.requestId = rid
            } else if let rid = try alt.decodeIfPresent(String.self, forKey: .requestIdSnake) {
                self.requestId = rid
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.requestId,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing request_id/requestId")
                )
            }
        }

        self.questions = (try container.decodeIfPresent([SwitchQuestionV1].self, forKey: .questions)) ?? []
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

    private enum DecodingKeys: String, CodingKey {
        case header
        case question
        case options
        case multiple
        case multiSelect = "multiSelect"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        self.header = try container.decodeIfPresent(String.self, forKey: .header)
        self.question = try container.decodeIfPresent(String.self, forKey: .question)
        self.options = try container.decodeIfPresent([SwitchQuestionOptionV1].self, forKey: .options)
        if let m = try container.decodeIfPresent(Bool.self, forKey: .multiple) {
            self.multiple = m
        } else {
            self.multiple = try container.decodeIfPresent(Bool.self, forKey: .multiSelect)
        }
    }
}

public struct SwitchQuestionOptionV1: Codable, Hashable, Sendable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }

    private enum DecodingKeys: String, CodingKey {
        case label
        case value
        case name
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        if let l = try container.decodeIfPresent(String.self, forKey: .label) {
            self.label = l
        } else if let v = try container.decodeIfPresent(String.self, forKey: .value) {
            self.label = v
        } else if let n = try container.decodeIfPresent(String.self, forKey: .name) {
            self.label = n
        } else {
            throw DecodingError.keyNotFound(
                DecodingKeys.label,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing label/value/name")
            )
        }
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
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

    private enum AltCodingKeys: String, CodingKey {
        case requestId
        case requestIdSnake = "request_id"
        case answers
        case text
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AltCodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.answers = try container.decodeIfPresent([[String]].self, forKey: .answers)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)

        if let rid = try container.decodeIfPresent(String.self, forKey: .requestIdSnake) {
            self.requestId = rid
        } else if let rid = try container.decodeIfPresent(String.self, forKey: .requestId) {
            self.requestId = rid
        } else {
            throw DecodingError.keyNotFound(
                AltCodingKeys.requestIdSnake,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing request_id/requestId")
            )
        }
    }
}
