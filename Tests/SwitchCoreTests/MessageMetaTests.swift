import XCTest
import Martin
@testable import SwitchCore

final class MessageMetaTests: XCTestCase {

    // MARK: - Test Fixtures (XML strings for documentation)

    /*
     Message with meta type=tool tool=bash:
     <message xmlns="jabber:client" to="user@example.com" type="chat" id="msg1">
         <body>[Bash: ssh helga "ls -la"]</body>
         <meta xmlns="urn:switch:message-meta" type="tool" tool="bash"/>
     </message>

     Message with meta type=tool (no tool attr):
     <message xmlns="jabber:client" to="user@example.com" type="chat" id="msg2">
         <body>... [aggregated progress] ...</body>
         <meta xmlns="urn:switch:message-meta" type="tool"/>
     </message>

     Message with meta type=tool-result tool=bash:
     <message xmlns="jabber:client" to="user@example.com" type="chat" id="msg3">
         <body>total 42\ndrwxr-xr-x  5 user staff 160 Jan 28 10:00 .</body>
         <meta xmlns="urn:switch:message-meta" type="tool-result" tool="bash"/>
     </message>

     Message without meta element:
     <message xmlns="jabber:client" to="user@example.com" type="chat" id="msg4">
         <body>Hello, this is a regular message.</body>
     </message>
     */

    // MARK: - Helper

    private func createMetaElement(type: String?, tool: String?, xmlns: String = "urn:switch:message-meta") -> Element {
        let meta = Element(name: "meta", xmlns: xmlns)
        if let type = type {
            meta.attribute("type", newValue: type)
        }
        if let tool = tool {
            meta.attribute("tool", newValue: tool)
        }
        return meta
    }

    private func createMessageElement(body: String, meta: Element? = nil) -> Element {
        let message = Element(name: "message")
        let bodyEl = Element(name: "body", cdata: body)
        message.addChild(bodyEl)
        if let meta = meta {
            message.addChild(meta)
        }
        return message
    }

    // MARK: - Tests

    func testToolBashMessage() {
        let meta = createMetaElement(type: "tool", tool: "bash")
        let element = createMessageElement(body: "[Bash: ssh helga \"ls -la\"]", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .tool)
        XCTAssertEqual(result?.tool, "bash")
        XCTAssertTrue(result?.isToolRelated ?? false)
    }

    func testToolNoToolAttribute() {
        let meta = createMetaElement(type: "tool", tool: nil)
        let element = createMessageElement(body: "... progress ...", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .tool)
        XCTAssertNil(result?.tool)
        XCTAssertTrue(result?.isToolRelated ?? false)
    }

    func testToolResultBash() {
        let meta = createMetaElement(type: "tool-result", tool: "bash")
        let element = createMessageElement(body: "command output here", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .toolResult)
        XCTAssertEqual(result?.tool, "bash")
        XCTAssertTrue(result?.isToolRelated ?? false)
    }

    func testNoMetaElement() {
        let element = createMessageElement(body: "Regular message")

        let result = parseMessageMeta(from: element)

        XCTAssertNil(result)
    }

    func testUnknownMetaType() {
        let meta = createMetaElement(type: "system", tool: nil)
        let element = createMessageElement(body: "System message", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .unknown)
        XCTAssertFalse(result?.isToolRelated ?? true)
    }

    func testWrongNamespace() {
        let meta = createMetaElement(type: "tool", tool: "bash", xmlns: "urn:other:namespace")
        let element = createMessageElement(body: "Message", meta: meta)

        let result = parseMessageMeta(from: element)

        // Should return nil because namespace doesn't match
        XCTAssertNil(result)
    }

    func testMetaWithoutType() {
        let meta = createMetaElement(type: nil, tool: "bash")
        let element = createMessageElement(body: "Message", meta: meta)

        let result = parseMessageMeta(from: element)

        // Should return nil because type attribute is required
        XCTAssertNil(result)
    }

    func testToolReadMessage() {
        let meta = createMetaElement(type: "tool", tool: "read")
        let element = createMessageElement(body: "[Read: /path/to/file.txt]", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .tool)
        XCTAssertEqual(result?.tool, "read")
    }

    func testToolEditMessage() {
        let meta = createMetaElement(type: "tool", tool: "edit")
        let element = createMessageElement(body: "[Edit: updating file]", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .tool)
        XCTAssertEqual(result?.tool, "edit")
    }

    func testToolTaskMessage() {
        let meta = createMetaElement(type: "tool", tool: "task")
        let element = createMessageElement(body: "[Task: spawning subagent]", meta: meta)

        let result = parseMessageMeta(from: element)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .tool)
        XCTAssertEqual(result?.tool, "task")
    }
}
