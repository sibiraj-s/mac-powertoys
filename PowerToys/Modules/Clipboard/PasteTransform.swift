import AppKit

extension ClipItem.RichText {
    var attributedString: NSAttributedString? {
        switch self {
        case .html(let html):
            try? NSAttributedString(
                data: Data(html.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            )
        case .rtf(let data):
            NSAttributedString(rtf: data, documentAttributes: nil)
        }
    }
}

/// Text conversions behind the paste formats.
enum PasteTransform {
    // MARK: JSON

    /// `text` as indented JSON: valid JSON is re-indented with its key order kept, and a CSV or
    /// TSV table becomes an array of objects keyed by the header row.
    static func json(from text: String) -> String? {
        prettyJSON(text) ?? tableJSON(text)
    }

    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        else { return nil }
        return indent(json: trimmed)
    }

    static func tableJSON(_ text: String) -> String? {
        let delimiter: Character = text.prefix { $0 != "\n" }.contains("\t") ? "\t" : ","
        let rows = parseTable(text, delimiter: delimiter)
        guard rows.count >= 2, let header = rows.first, header.count >= 2,
              rows.allSatisfy({ $0.count == header.count })
        else { return nil }
        let objects = rows.dropFirst().map { row in
            "{" + zip(header, row).map { "\(quoted($0)):\(quoted($1))" }.joined(separator: ",") + "}"
        }
        return indent(json: "[" + objects.joined(separator: ",") + "]")
    }

    /// Splits delimited text into rows of fields. Quoted fields may hold delimiters, newlines and
    /// doubled quotes; blank lines are skipped.
    static func parseTable(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = text.makeIterator()
        var pending = characters.next()

        func endRow() {
            row.append(field)
            if row != [""] { rows.append(row) }
            row = []
            field = ""
        }

        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character.isNewline {
                // "\r\n" is a single Character in Swift, so this covers both line endings.
                endRow()
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func quoted(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Re-indents valid JSON two spaces per level without reordering anything.
    private static func indent(json: String) -> String {
        var output = ""
        var level = 0
        var inString = false
        var isEscaped = false
        let characters = Array(json)

        func newline() {
            output.append("\n" + String(repeating: "  ", count: level))
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if inString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                // Keep empty containers on one line.
                var next = index
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == (character == "{" ? "}" : "]") {
                    output.append(character)
                    output.append(characters[next])
                    index = next + 1
                } else {
                    output.append(character)
                    level += 1
                    newline()
                }
            case "}", "]":
                level -= 1
                newline()
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output.append(": ")
            case _ where character.isWhitespace:
                break
            default:
                output.append(character)
            }
        }
        return output
    }

    // MARK: Markdown

    /// Bold, italic, code, links, headings and lists from rich text as Markdown.
    static func markdown(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        var output = ""
        var previousWasListItem = false
        var location = 0

        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)

            var content = paragraph
            while content.length > 0, isLineBreak(string.character(at: NSMaxRange(content) - 1)) {
                content.length -= 1
            }
            guard content.length > 0,
                  !string.substring(with: content).allSatisfy(\.isWhitespace)
            else { continue }

            let style = attributed.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let lists = style?.textLists ?? []
            var prefix = ""
            if let list = lists.last {
                // AppKit draws list markers into the text, such as "\t•\t" or "\t1.\t".
                if let marker = string.substring(with: content).prefixMatch(of: #/\t*[^\t]{0,8}\t/#) {
                    let length = marker.output.utf16.count
                    content = NSRange(location: content.location + length, length: content.length - length)
                }
                prefix = String(repeating: "  ", count: lists.count - 1) + (list.isOrdered ? "1. " : "- ")
            }

            let heading = lists.isEmpty ? headingLevel(of: attributed.attributedSubstring(from: content)) : 0
            if heading > 0 {
                prefix = String(repeating: "#", count: heading) + " "
            }
            let line = prefix + inlineMarkdown(attributed.attributedSubstring(from: content), includesBold: heading == 0)

            let isListItem = !lists.isEmpty
            if !output.isEmpty {
                output += previousWasListItem && isListItem ? "\n" : "\n\n"
            }
            output += line
            previousWasListItem = isListItem
        }
        return output
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    /// 1 or 2 for a paragraph set entirely in a large font, as browsers render h1 and h2.
    private static func headingLevel(of paragraph: NSAttributedString) -> Int {
        var smallest = CGFloat.infinity
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, _, _ in
            smallest = min(smallest, (value as? NSFont)?.pointSize ?? 0)
        }
        switch smallest {
        case 22..<CGFloat.infinity: return 1
        case 17..<22: return 2
        default: return 0
        }
    }

    private struct InlineStyle: Equatable {
        var isBold = false
        var isItalic = false
        var isCode = false
        var link: String?
    }

    private static func inlineMarkdown(_ text: NSAttributedString, includesBold: Bool) -> String {
        var runs: [(text: String, style: InlineStyle)] = []
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let link: String? = switch attributes[.link] {
            case let url as URL: url.absoluteString
            case let string as String: string
            default: nil
            }
            let style = InlineStyle(
                isBold: includesBold && traits.contains(.bold),
                isItalic: traits.contains(.italic),
                isCode: traits.contains(.monoSpace),
                link: link
            )
            let piece = string.substring(with: range)
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += piece
            } else {
                runs.append((piece, style))
            }
        }
        return runs.map { render($0.text, $0.style) }.joined()
    }

    private static func render(_ text: String, _ style: InlineStyle) -> String {
        var result = text
        if style.isCode {
            result = wrap(result, "`", "`")
        } else {
            let marker = (style.isBold ? "**" : "") + (style.isItalic ? "*" : "")
            if !marker.isEmpty {
                result = wrap(result, marker, marker)
            }
        }
        if let link = style.link {
            result = wrap(result, "[", "](\(link))")
        }
        return result
    }

    /// Puts markers around the text but outside its surrounding spaces, since "** bold **" isn't bold.
    private static func wrap(_ text: String, _ opening: String, _ closing: String) -> String {
        let leading = text.prefix { $0.isWhitespace }
        let rest = text.dropFirst(leading.count)
        let trailing = rest.reversed().prefix { $0.isWhitespace }
        let core = rest.dropLast(trailing.count)
        guard !core.isEmpty else { return text }
        return leading + opening + core + closing + String(trailing.reversed())
    }
}
