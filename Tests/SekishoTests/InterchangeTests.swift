import Foundation
import XCTest
@testable import SekishoCore

final class InterchangeTests: XCTestCase {
    private var sample: Flow {
        var f = Flow(id: 7)
        f.scheme = "https"; f.host = "api.example.com"; f.port = 443; f.method = "POST"; f.path = "/v1/items?q=a b"
        f.requestHeaders = [.init("Content-Type", "application/json"), .init("X-Note", "it's \"quoted\"")]
        f.requestBody = Data("{\"text\":\"line1\\nline2 \\\\ back\"}".utf8)
        f.status = 201; f.reason = "Created"
        f.responseHeaders = [.init("Content-Type", "application/json")]
        f.responseBody = Data("{\"ok\":true}".utf8); f.responseSize = 11
        f.ended = f.started.addingTimeInterval(0.2)
        return f
    }

    func testSessionRoundTrip() throws {
        let file = SessionFile(flows: [sample], marks: Data("{}".utf8))
        let back = try SessionFile.decode(try file.encoded())
        XCTAssertEqual(back.flows.first?.url, sample.url)
        XCTAssertEqual(back.flows.first?.requestBody, sample.requestBody)
        XCTAssertThrowsError(try SessionFile.decode(Data("{\"format\":\"other\",\"version\":1,\"saved\":\"2026-01-01T00:00:00Z\",\"flows\":[]}".utf8)))
    }

    func testHARRoundTrip() throws {
        let flows = try Import.har(try Export.har([sample]))
        let f = try XCTUnwrap(flows.first)
        XCTAssertEqual(f.method, "POST")
        XCTAssertEqual(f.host, "api.example.com")
        XCTAssertEqual(f.status, 201)
        XCTAssertEqual(String(decoding: f.responseBody, as: UTF8.self), "{\"ok\":true}")
        XCTAssertTrue(f.imported)
    }

    func testCurlImport() throws {
        let f = try XCTUnwrap(Import.curl("""
        curl -X PUT 'https://api.example.com/v1/x?y=1' \\
          -H 'Content-Type: application/json' -H "X-Quote: say \\"hi\\"" \\
          --data-raw '{"a":1}' -u gino:secret --compressed
        """))
        XCTAssertEqual(f.method, "PUT")
        XCTAssertEqual(f.url, "https://api.example.com/v1/x?y=1")
        XCTAssertEqual(f.requestHeader("X-Quote"), "say \"hi\"")
        XCTAssertEqual(String(decoding: f.requestBody, as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(f.requestHeader("Authorization"), "Basic " + Data("gino:secret".utf8).base64EncodedString())
        XCTAssertEqual(Import.curl("curl example.com/a")?.url, "http://example.com/a")
        XCTAssertNil(Import.curl("wget example.com"))
    }

    func testCodeGeneratorsEscape() {
        for language in CodeLanguage.allCases {
            let code = CodeGen.generate(sample, language)
            XCTAssertTrue(code.contains("api.example.com"), language.rawValue)
            XCTAssertFalse(code.contains("Content-Length"), language.rawValue)
        }
        let js = CodeGen.generate(sample, .fetch)
        XCTAssertTrue(js.contains(#""X-Note": "it's \"quoted\"""#), js)
        XCTAssertTrue(js.contains(#"\\n"#) || js.contains(#"\n"#))
        XCTAssertEqual(CodeGen.literal("a\"b\\c\nd\u{1}"), #""a\"b\\c\nd\u0001""#)
        XCTAssertTrue(CodeGen.generate(sample, .python).contains("requests.request("))
        XCTAssertTrue(CodeGen.generate(sample, .go).contains("strings.NewReader("))
    }

    func testDiffRows() {
        let rows = TextDiff.rows("a\nb\nc", "a\nB\nc\nd")
        XCTAssertEqual(rows.map(\.kind), [.same, .changed, .same, .added])
    }

    func testWebSocketFrames() {
        // A masked client text frame "Hi", a fragmented binary message, a ping; split across feeds.
        let key: [UInt8] = [1, 2, 3, 4]
        let hi = Array("Hi".utf8).enumerated().map { $1 ^ key[$0 % 4] }
        var bytes: [UInt8] = [0x81, 0x82] + key + hi
        bytes += [0x02, 0x02, 0xAA, 0xBB, 0x80, 0x01, 0xCC]
        bytes += [0x89, 0x00]
        var client = WebSocketFrames(afterHTTPHeader: false)
        var got = client.feed(Data(bytes.prefix(5)))
        got += client.feed(Data(bytes.dropFirst(5)))
        XCTAssertEqual(got.map(\.0), [.text, .binary, .ping])
        XCTAssertEqual(String(decoding: got[0].1, as: UTF8.self), "Hi")
        XCTAssertEqual([UInt8](got[1].1), [0xAA, 0xBB, 0xCC])
        var server = WebSocketFrames(afterHTTPHeader: true)
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".utf8) + Data([0x81, 0x02] + Array("ok".utf8))
        XCTAssertEqual(server.feed(reply).map { String(decoding: $0.1, as: UTF8.self) }, ["ok"])
    }

    func testReviewRegressions() throws {
        // A hostile 64-bit WebSocket length must not crash or grow the buffer.
        var frames = WebSocketFrames(afterHTTPHeader: false)
        XCTAssertTrue(frames.feed(Data([0x82, 0x7F, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF8])).isEmpty)
        XCTAssertTrue(frames.broken)
        // Sub-second timings survive a session.
        var f = sample
        f.ended = f.started.addingTimeInterval(0.15)
        let back = try SessionFile.decode(try SessionFile(flows: [f]).encoded()).flows[0]
        XCTAssertEqual(back.duration ?? 0, 0.15, accuracy: 0.002)
        // HAR's "unknown" time.
        let har = Data(#"{"log":{"entries":[{"startedDateTime":"2026-10-19T10:00:00.000Z","time":-1,"request":{"method":"GET","url":"http://a.test/","headers":[]},"response":{"status":200,"statusText":"OK","headers":[],"content":{}}}]}}"#.utf8)
        XCTAssertEqual(try Import.har(har).first?.duration, 0)
        // curl: Chrome's $'…' quoting and options with values.
        let c = try XCTUnwrap(Import.curl(#"curl --retry 3 'https://a.test/x' -H $'X-A: it\'s' --data-raw $'{"a":"b\nc"}'"#))
        XCTAssertEqual(c.url, "https://a.test/x")
        XCTAssertEqual(c.requestHeader("X-A"), "it's")
        XCTAssertEqual(String(decoding: c.requestBody, as: UTF8.self), "{\"a\":\"b\nc\"}")
        // Generated Swift escapes controls the Swift way.
        var g = sample
        g.requestHeaders = [.init("X-C", "a\u{1}b")]
        XCTAssertTrue(CodeGen.generate(g, .urlSession).contains(#"a\u{1}b"#))
        // Wire validation.
        var w = sample
        w.host = "a\r\nX-Injected: 1"
        XCTAssertNotNil(w.wireProblem)
        w = sample
        w.method = "GET /x HTTP/1.1\r\n"
        XCTAssertNotNil(w.wireProblem)
        XCTAssertNil(sample.wireProblem)
        XCTAssertTrue(LocalDestination.isThisMac("localhost"))
        XCTAssertTrue(LocalDestination.isThisMac("127.0.0.2"))
        XCTAssertFalse(LocalDestination.isThisMac("example.com"))
    }

    func testScriptsLeaveWhatTheyDoNotTouch() {
        var f = Flow(id: 1)
        f.scheme = "https"; f.host = "a.test"; f.port = 443; f.path = "/p?ids=1&ids=2&q=a%2Bb&flag"
        f.requestHeaders = [.init("Host", "a.test"), .init("Content-Type", "application/octet-stream")]
        f.requestBody = Data([0xFF, 0x00, 0xFE])
        f.status = 200
        f.responseHeaders = [.init("Set-Cookie", "a=1"), .init("Set-Cookie", "b=2"), .init("Content-Type", "image/png")]
        f.responseBody = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])
        var rule = ScriptRule(pattern: "*")
        rule.code = "function onRequest(c, u, r) { return r; } function onResponse(c, u, q, r) { return r; }"
        let runner = ScriptRunner()
        let req = runner.runNow(.request, rule: rule, flow: f)
        XCTAssertEqual(req, f, "an identity script changes nothing")
        let res = runner.runNow(.response, rule: rule, flow: f)
        XCTAssertEqual(res.responseHeaders.filter { $0.name == "Set-Cookie" }.count, 2)
        XCTAssertEqual(res.responseBody, f.responseBody)
        rule.code = "function onRequest(c, u, r) { r.host = 'b.test'; return r; }"
        let moved = runner.runNow(.request, rule: rule, flow: f)
        XCTAssertEqual(moved.requestHeader("Host"), "b.test")
        XCTAssertEqual(moved.path, f.path, "the query keeps its exact encoding")
    }

    func testJSONKeepsOrderAndNumbers() throws {
        let raw = Data(#"{"zeta":1,"alpha":{"price":39.95,"big":9007199254740993,"e":1E-7},"list":[],"empty":{},"s":"caf\u00e9 \"q\" \ud83d\ude00"}"#.utf8)
        let pretty = try XCTUnwrap(BodyText.prettyJSON(raw))
        XCTAssertEqual(pretty, """
        {
          "zeta": 1,
          "alpha": {
            "price": 39.95,
            "big": 9007199254740993,
            "e": 1E-7
          },
          "list": [],
          "empty": {},
          "s": "caf\\u00e9 \\"q\\" \\ud83d\\ude00"
        }
        """)
        guard case .object(let members)? = JSONValue.parse(raw), case .string(let text, _) = members[4].value else { return XCTFail() }
        XCTAssertEqual(text, "café \"q\" 😀")
        XCTAssertNil(JSONValue.parse(Data("{\"a\":1,}".utf8)))
        XCTAssertNil(BodyText.prettyJSON(Data("plain text".utf8)))
    }
}
