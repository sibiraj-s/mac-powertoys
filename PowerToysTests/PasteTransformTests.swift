import AppKit
import Testing
@testable import PowerToys

struct PasteTransformJSONTests {
    @Test func reindentsKeepingKeyOrder() {
        let json = PasteTransform.json(from: #" {"z":1,"a":[true,null,"x, y"],"e":{},"l":[]} "#)
        #expect(json == """
        {
          "z": 1,
          "a": [
            true,
            null,
            "x, y"
          ],
          "e": {},
          "l": []
        }
        """)
    }

    @Test func leavesStringsAlone() {
        let json = PasteTransform.json(from: #"["a: {b}, \"c\" [d]"]"#)
        #expect(json == "[\n  \"a: {b}, \\\"c\\\" [d]\"\n]")
    }

    @Test func csvBecomesArrayOfObjects() {
        let json = PasteTransform.json(from: "name,zip\nAda,02134\n\"Smith, J\",\"say \"\"hi\"\"\"\n")
        #expect(json == """
        [
          {
            "name": "Ada",
            "zip": "02134"
          },
          {
            "name": "Smith, J",
            "zip": "say \\"hi\\""
          }
        ]
        """)
    }

    @Test func tsvWithWindowsLineEndings() {
        let json = PasteTransform.json(from: "a\tb\r\n1\t2\r\n")
        #expect(json == "[\n  {\n    \"a\": \"1\",\n    \"b\": \"2\"\n  }\n]")
    }

    @Test func quotedFieldsCanSpanLines() {
        let rows = PasteTransform.parseTable("a,b\n\"line 1\nline 2\",x\n\n", delimiter: ",")
        #expect(rows == [["a", "b"], ["line 1\nline 2", "x"]])
    }

    @Test(arguments: [
        "just some words",
        "{not json",
        "a,b\n1,2,3",   // ragged rows
        "single\ncolumn", // one column isn't a table
        "a,b",          // header only
    ])
    func nonJSONIsRejected(text: String) {
        #expect(PasteTransform.json(from: text) == nil)
    }
}

struct PasteTransformMarkdownTests {
    private let body = NSFont.systemFont(ofSize: 13)

    private func text(_ string: String, _ attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: body].merging(attributes) { $1 })
    }

    private func joined(_ parts: NSAttributedString...) -> NSAttributedString {
        let result = NSMutableAttributedString()
        parts.forEach(result.append)
        return result
    }

    @Test func boldItalicCodeAndLinks() {
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        let source = joined(
            text("Say "),
            text("hello ", [.font: NSFont.boldSystemFont(ofSize: 13)]),
            text("to", [.font: italic]),
            text(" the "),
            text("docs", [.link: URL(string: "https://example.com")!]),
            text(" and run "),
            text("make", [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        )
        #expect(PasteTransform.markdown(from: source) == "Say **hello** *to* the [docs](https://example.com) and run `make`")
    }

    @Test func paragraphsAndHeadings() {
        let source = joined(
            text("Title\n", [.font: NSFont.boldSystemFont(ofSize: 24)]),
            text("Section\n", [.font: NSFont.boldSystemFont(ofSize: 18)]),
            text("First.\n\nSecond.")
        )
        #expect(PasteTransform.markdown(from: source) == "# Title\n\n## Section\n\nFirst.\n\nSecond.")
    }

    @Test func listsDropRenderedMarkers() {
        func item(_ string: String, ordered: Bool, depth: Int = 1) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.textLists = (0..<depth).map { _ in NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0) }
            return text("\t\(ordered ? "1." : "•")\t\(string)\n", [.paragraphStyle: style])
        }
        let source = joined(
            text("Intro\n"),
            item("one", ordered: false),
            item("nested", ordered: false, depth: 2),
            item("two", ordered: false),
            text("Then\n"),
            item("first", ordered: true)
        )
        #expect(PasteTransform.markdown(from: source) == "Intro\n\n- one\n  - nested\n- two\n\nThen\n\n1. first")
    }

    @Test func htmlRoundTrip() {
        let item = ClipItem(
            text: "Hello world",
            richText: .html(#"<meta charset="utf-8"><p>Hello <b>world</b> and <a href="https://a.b/">link</a></p>"#),
            date: .now
        )
        #expect(PasteFormat.markdown.contents(of: item) == .text("Hello **world** and [link](https://a.b/)"))
    }
}
