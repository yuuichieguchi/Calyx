import Foundation
import Testing
@testable import Calyx

private let vscodeBreakBefore = "([{‘“〈《「『【〔（［｛｢£¥＄￡￥+＋"
private let vscodeBreakAfter = " \t})]?|/&.,;¢°′″‰℃、。｡､￠，．：；？！％・･ゝゞヽヾーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ々〻ｧｨｩｪｫｬｭｮｯｰ”〉》」』】〕）］｝｣"

private struct BreakClasses {
    let before: String
    let after: String
    static let vscodeDefaults = BreakClasses(before: vscodeBreakBefore, after: vscodeBreakAfter)
}

private let pipe = UInt16(UInt8(ascii: "|"))

private func strippedText(_ annotated: String) -> String {
    String(decoding: annotated.utf16.filter { $0 != pipe }, as: UTF16.self)
}

private func outputLineIndex(of offset: Int, in projection: DiffLineProjection) -> Int {
    projection.breakOffsets.dropLast().filter { $0 <= offset }.count
}

private func annotated(_ text: String, _ projection: DiffLineProjection?) -> String {
    guard let projection else { return text }
    var units: [UInt16] = []
    var previousLine = 0
    for (offset, unit) in text.utf16.enumerated() {
        let line = outputLineIndex(of: offset, in: projection)
        if line != previousLine {
            previousLine = line
            units.append(pipe)
        }
        units.append(unit)
    }
    return String(decoding: units, as: UTF16.self)
}

private func everyUnitOnItsOwnLine(_ text: String) -> String {
    var units: [UInt16] = []
    for (index, unit) in text.utf16.enumerated() {
        if index > 0 { units.append(pipe) }
        units.append(unit)
    }
    return String(decoding: units, as: UTF16.self)
}

private func lineBreakData(
    _ classes: BreakClasses, tabSize: Int, breakAfter: Int, columnsForFullWidthChar: Double = 2,
    wrappingIndent: DiffWrappingIndent = .none, wordBreak: DiffWordBreak = .normal,
    text: String, previous: DiffLineProjection? = nil, useTwoCellFullwidthCharacters: Bool = false
) -> DiffLineProjection? {
    if let previous {
        return DiffLineBreaks.compute(
            text, previous: previous, tabSize: tabSize, wrappingColumn: breakAfter,
            columnsForFullWidthChar: columnsForFullWidthChar, wrappingIndent: wrappingIndent, wordBreak: wordBreak,
            useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters,
            breakBeforeCharacters: classes.before, breakAfterCharacters: classes.after)
    }
    return DiffLineBreaks.compute(
        text, tabSize: tabSize, wrappingColumn: breakAfter,
        columnsForFullWidthChar: columnsForFullWidthChar, wrappingIndent: wrappingIndent, wordBreak: wordBreak,
        useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters,
        breakBeforeCharacters: classes.before, breakAfterCharacters: classes.after)
}

@discardableResult
private func assertLineBreaks(
    _ classes: BreakClasses, _ tabSize: Int, _ breakAfter: Int, _ expected: String,
    _ wrappingIndent: DiffWrappingIndent = .none, _ wordBreak: DiffWordBreak = .normal,
    sourceLocation: SourceLocation = #_sourceLocation
) -> DiffLineProjection? {
    let text = strippedText(expected)
    let data = lineBreakData(classes, tabSize: tabSize, breakAfter: breakAfter,
                             wrappingIndent: wrappingIndent, wordBreak: wordBreak, text: text)
    #expect(annotated(text, data) == expected, sourceLocation: sourceLocation)
    return data
}

private func expectSameProjection(_ a: DiffLineProjection?, _ b: DiffLineProjection?,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
    guard let a, let b else {
        #expect(a == nil && b == nil, sourceLocation: sourceLocation)
        return
    }
    #expect(a.breakOffsets == b.breakOffsets, sourceLocation: sourceLocation)
    #expect(a.wrappedTextIndentLength == b.wrappedTextIndentLength, sourceLocation: sourceLocation)
    #expect(a.breakOffsetsVisibleColumn.count == b.breakOffsetsVisibleColumn.count, sourceLocation: sourceLocation)
    for (x, y) in zip(a.breakOffsetsVisibleColumn, b.breakOffsetsVisibleColumn) {
        #expect(abs(x - y) < 0.001, sourceLocation: sourceLocation)
    }
}

private func assertIncrementalLineBreaks(
    _ classes: BreakClasses, _ text: String, _ tabSize: Int,
    _ breakAfter1: Int, _ annotated1: String, _ breakAfter2: Int, _ annotated2: String,
    _ wrappingIndent: DiffWrappingIndent = .none, _ columnsForFullWidthChar: Double = 2,
    _ useTwoCellFullwidthCharacters: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(text == strippedText(annotated1), "fixture sanity", sourceLocation: sourceLocation)
    #expect(text == strippedText(annotated2), "fixture sanity", sourceLocation: sourceLocation)
    func data(_ breakAfter: Int, previous: DiffLineProjection?) -> DiffLineProjection? {
        lineBreakData(classes, tabSize: tabSize, breakAfter: breakAfter, columnsForFullWidthChar: columnsForFullWidthChar,
                      wrappingIndent: wrappingIndent, text: text, previous: previous,
                      useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters)
    }
    let direct1 = data(breakAfter1, previous: nil)
    #expect(annotated(text, direct1) == annotated1, "direct 1", sourceLocation: sourceLocation)
    let direct2 = data(breakAfter2, previous: nil)
    #expect(annotated(text, direct2) == annotated2, "direct 2", sourceLocation: sourceLocation)
    if let direct1 {
        let twoFromOne = data(breakAfter2, previous: direct1)
        #expect(annotated(text, twoFromOne) == annotated2, "2 from 1", sourceLocation: sourceLocation)
        expectSameProjection(twoFromOne, direct2, sourceLocation: sourceLocation)
    }
    if let direct2 {
        let oneFromTwo = data(breakAfter1, previous: direct2)
        #expect(annotated(text, oneFromTwo) == annotated1, "1 from 2", sourceLocation: sourceLocation)
        expectSameProjection(oneFromTwo, direct1, sourceLocation: sourceLocation)
    }
}

@Suite
struct DiffLineBreaksTests {

    @Test func defaultBreakCharacters_matchVSCodeEditorOptions() {
        #expect(DiffLineBreaks.defaultBreakBeforeCharacters == vscodeBreakBefore)
        #expect(DiffLineBreaks.defaultBreakAfterCharacters == vscodeBreakAfter)
    }

    @Test func defaultParameters_useVSCodeDefaults() {
        let text = "this is a line of (text), text that sits on a line"
        let explicit = lineBreakData(.vscodeDefaults, tabSize: 4, breakAfter: 24, wrappingIndent: .same, text: text)
        let implicit = DiffLineBreaks.compute(text, tabSize: 4, wrappingColumn: 24, columnsForFullWidthChar: 2,
                                              wrappingIndent: .same, wordBreak: .normal)
        #expect(implicit == explicit)
        #expect(implicit?.breakOffsets == [18, 41, 50])
    }

    @Test func projection_segmentCountAndLastOffset() throws {
        let projection = try #require(assertLineBreaks(BreakClasses(before: "(", after: "\t)."), 4, 5, "aaaaa|a.|aaa.|aa"))
        #expect(projection.breakOffsets == [5, 7, 11, 13])
        #expect(projection.breakOffsetsVisibleColumn == [5, 7, 11, 13])
        #expect(projection.segmentCount == 4)
        #expect(projection.wrappedTextIndentLength == 0)
    }

    @Test func monospaceLineBreaksComputer() {
        let f = BreakClasses(before: "(", after: "\t).")
        assertLineBreaks(f, 4, 5, "")
        assertLineBreaks(f, 4, 5, "aaa")
        assertLineBreaks(f, 4, 5, "aaaaa")
        assertLineBreaks(f, 4, -1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        assertLineBreaks(f, 4, 5, "aaaaa|a")
        assertLineBreaks(f, 4, 5, "aaaaa|.")
        assertLineBreaks(f, 4, 5, "aaaaa|a.|aaa.|aa")
        assertLineBreaks(f, 4, 5, "aaaaa|a..|aaa.|aa")
        assertLineBreaks(f, 4, 5, "aaaaa|a...|aaa.|aa")
        assertLineBreaks(f, 4, 5, "aaaaa|a....|aaa.|aa")
        assertLineBreaks(f, 4, 5, "\t")
        assertLineBreaks(f, 4, 5, "\t|aaa")
        assertLineBreaks(f, 4, 5, "\t|a\t|aa")
        assertLineBreaks(f, 4, 5, "aa\ta")
        assertLineBreaks(f, 4, 5, "aa\t|aa")
        assertLineBreaks(f, 4, 5, "aaa.|aa")
        assertLineBreaks(f, 4, 5, "aaa(.|aa")
        assertLineBreaks(f, 4, 5, "aaa))|).aaa")
        assertLineBreaks(f, 4, 5, "aaa))|).|aaaa")
        assertLineBreaks(f, 4, 5, "aaa)|().|aaa")
        assertLineBreaks(f, 4, 5, "aaa|(().|aaa")
        assertLineBreaks(f, 4, 5, "aa.|(().|aaa")
        assertLineBreaks(f, 4, 5, "aa.|(.).|aaa")
    }

    @Test func noWrapNeeded_returnsNil() {
        let f = BreakClasses(before: "(", after: "\t).")
        #expect(lineBreakData(f, tabSize: 4, breakAfter: 5, text: "") == nil)
        #expect(lineBreakData(f, tabSize: 4, breakAfter: 5, text: "aaaaa") == nil)
        #expect(lineBreakData(f, tabSize: 4, breakAfter: -1, text: "aaaaaaaaaaaa") == nil)
    }

    @Test func incremental1() {
        let f = BreakClasses.vscodeDefaults
        assertIncrementalLineBreaks(
            f, "just some text and more", 4,
            10, "just some |text and |more",
            15, "just some text |and more"
        )
        assertIncrementalLineBreaks(
            f, "Cu scripserit suscipiantur eos, in affert pericula contentiones sed, cetero sanctus et pro. Ius vidit magna regione te, sit ei elaboraret liberavisse. Mundi verear eu mea, eam vero scriptorem in, vix in menandri assueverit. Natum definiebas cu vim. Vim doming vocibus efficiantur id. In indoctum deseruisse voluptatum vim, ad debitis verterem sed.", 4,
            47, "Cu scripserit suscipiantur eos, in affert |pericula contentiones sed, cetero sanctus et |pro. Ius vidit magna regione te, sit ei |elaboraret liberavisse. Mundi verear eu mea, |eam vero scriptorem in, vix in menandri |assueverit. Natum definiebas cu vim. Vim |doming vocibus efficiantur id. In indoctum |deseruisse voluptatum vim, ad debitis verterem |sed.",
            142, "Cu scripserit suscipiantur eos, in affert pericula contentiones sed, cetero sanctus et pro. Ius vidit magna regione te, sit ei elaboraret |liberavisse. Mundi verear eu mea, eam vero scriptorem in, vix in menandri assueverit. Natum definiebas cu vim. Vim doming vocibus efficiantur |id. In indoctum deseruisse voluptatum vim, ad debitis verterem sed."
        )
        assertIncrementalLineBreaks(
            f, "An his legere persecuti, oblique delicata efficiantur ex vix, vel at graecis officiis maluisset. Et per impedit voluptua, usu discere maiorum at. Ut assum ornatus temporibus vis, an sea melius pericula. Ea dicunt oblique phaedrum nam, eu duo movet nobis. His melius facilis eu, vim malorum temporibus ne. Nec no sale regione, meliore civibus placerat id eam. Mea alii fabulas definitionem te, agam volutpat ad vis, et per bonorum nonumes repudiandae.", 4,
            57, "An his legere persecuti, oblique delicata efficiantur ex |vix, vel at graecis officiis maluisset. Et per impedit |voluptua, usu discere maiorum at. Ut assum ornatus |temporibus vis, an sea melius pericula. Ea dicunt |oblique phaedrum nam, eu duo movet nobis. His melius |facilis eu, vim malorum temporibus ne. Nec no sale |regione, meliore civibus placerat id eam. Mea alii |fabulas definitionem te, agam volutpat ad vis, et per |bonorum nonumes repudiandae.",
            58, "An his legere persecuti, oblique delicata efficiantur ex |vix, vel at graecis officiis maluisset. Et per impedit |voluptua, usu discere maiorum at. Ut assum ornatus |temporibus vis, an sea melius pericula. Ea dicunt oblique |phaedrum nam, eu duo movet nobis. His melius facilis eu, |vim malorum temporibus ne. Nec no sale regione, meliore |civibus placerat id eam. Mea alii fabulas definitionem |te, agam volutpat ad vis, et per bonorum nonumes |repudiandae."
        )
        assertIncrementalLineBreaks(
            f, "\t\t\"owner\": \"vscode\",", 4,
            14, "\t\t\"owner|\": |\"vscod|e\",",
            16, "\t\t\"owner\":| |\"vscode\"|,",
            .same
        )
        assertIncrementalLineBreaks(
            f, "🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇&👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬", 4,
            51, "🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇&|👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬",
            50, "🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇|&|👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬",
            .same
        )
        assertIncrementalLineBreaks(
            f, "🐇👬&🌞🌖", 4,
            5, "🐇👬&|🌞🌖",
            4, "🐇👬|&|🌞🌖",
            .same
        )
        assertIncrementalLineBreaks(
            f, "\t\tfunc('🌞🏇🍼🌞🏇🍼🐇&👬🌖🌞👬🌖🌞🏇🍼🐇👬', WrappingIndent.Same);", 4,
            26, "\t\tfunc|('🌞🏇🍼🌞🏇🍼🐇&|👬🌖🌞👬🌖🌞🏇🍼🐇|👬', |WrappingIndent.|Same);",
            27, "\t\tfunc|('🌞🏇🍼🌞🏇🍼🐇&|👬🌖🌞👬🌖🌞🏇🍼🐇|👬', |WrappingIndent.|Same);",
            .same
        )
        assertIncrementalLineBreaks(
            f, "factory, \"xtxtfunc(x\"🌞🏇🍼🌞🏇🍼🐇&👬🌖🌞👬🌖🌞🏇🍼🐇👬x\"", 4,
            16, "factory, |\"xtxtfunc|(x\"🌞🏇🍼🌞🏇🍼|🐇&|👬🌖🌞👬🌖🌞🏇🍼|🐇👬x\"",
            17, "factory, |\"xtxtfunc|(x\"🌞🏇🍼🌞🏇🍼🐇|&👬🌖🌞👬🌖🌞🏇🍼|🐇👬x\"",
            .same
        )
    }

    @Test func issue95686_loopForever() {
        let text = "\t\t\t\t\t\t<tr dmx-class:table-danger=\"(alt <= 50)\" dmx-class:table-warning=\"(alt <= 200)\" dmx-class:table-primary=\"(alt <= 400)\" dmx-class:table-info=\"(alt <= 800)\" dmx-class:table-success=\"(alt >= 400)\">"
        assertIncrementalLineBreaks(
            .vscodeDefaults, text, 4,
            179, "\t\t\t\t\t\t<tr dmx-class:table-danger=\"(alt <= 50)\" dmx-class:table-warning=\"(alt <= 200)\" dmx-class:table-primary=\"(alt <= 400)\" dmx-class:table-info=\"(alt <= 800)\" |dmx-class:table-success=\"(alt >= 400)\">",
            1, everyUnitOnItsOwnLine(text),
            .same
        )
    }

    @Test func issue110392_crashOnResize() {
        let text = "你好 **hello** **hello** **hello-world** hey there!"
        assertIncrementalLineBreaks(
            .vscodeDefaults, text, 4,
            15, "你好 **hello** |**hello** |**hello-world**| hey there!",
            1, everyUnitOnItsOwnLine(text),
            .same, 1.6605405405405405
        )
    }

    @Test func cjkAndKinsokuShori() {
        let f = BreakClasses(before: "(", after: "\t)")
        assertLineBreaks(f, 4, 5, "aa \u{5b89}|\u{5b89}")
        assertLineBreaks(f, 4, 5, "\u{3042} \u{5b89}|\u{5b89}")
        assertLineBreaks(f, 4, 5, "\u{3042}\u{3042}|\u{5b89}\u{5b89}")
        assertLineBreaks(f, 4, 5, "aa |\u{5b89})\u{5b89}|\u{5b89}")
        assertLineBreaks(f, 4, 5, "aa \u{3042}|\u{5b89}\u{3042})|\u{5b89}")
        assertLineBreaks(f, 4, 5, "aa |(\u{5b89}aa|\u{5b89}")
    }

    private let cjkClasses = BreakClasses(before: "(", after: "\t)")

    private func wrap(_ text: String, breakAfter: Int, columns: Double, twoCells: Bool) -> String {
        annotated(text, lineBreakData(cjkClasses, tabSize: 4, breakAfter: breakAfter, columnsForFullWidthChar: columns,
                                      text: text, useTwoCellFullwidthCharacters: twoCells))
    }

    @Test func twoCellFullWidthCharacterWidth() {
        let text = "\u{3042}\u{3042}\u{3042}\u{3042}"
        #expect(wrap(text, breakAfter: 5, columns: 3, twoCells: false) == "\u{3042}|\u{3042}|\u{3042}|\u{3042}")
        #expect(wrap(text, breakAfter: 5, columns: 3, twoCells: true) == "\u{3042}\u{3042}|\u{3042}\u{3042}")
        #expect(wrap(text, breakAfter: 5, columns: 2, twoCells: false) == "\u{3042}\u{3042}|\u{3042}\u{3042}")
    }

    @Test func twoCellWidthDeterminesWhetherContinuationIndentFits() {
        let text = "    \u{3042}\u{3042}\u{3042}"
        func indent(_ breakAfter: Int, _ columns: Double, _ twoCells: Bool) -> Int? {
            lineBreakData(cjkClasses, tabSize: 4, breakAfter: breakAfter, columnsForFullWidthChar: columns,
                          wrappingIndent: .same, text: text, useTwoCellFullwidthCharacters: twoCells)?.wrappedTextIndentLength
        }
        #expect(indent(6, 3, false) == 0)
        #expect(indent(6, 3, true) == 4)
        #expect(indent(5, 1, false) == 4)
        #expect(indent(5, 1, true) == 0)
    }

    @Test func twoCellWidthUsesSharedFullWidthClassification() {
        let fullwidthAscii = String(repeating: "\u{FF21}", count: 4)
        let vaiSyllables = String(repeating: "\u{A500}", count: 4)
        #expect(wrap(fullwidthAscii, breakAfter: 5, columns: 3, twoCells: false) == "\u{FF21}|\u{FF21}|\u{FF21}|\u{FF21}")
        #expect(wrap(fullwidthAscii, breakAfter: 5, columns: 3, twoCells: true) == "\u{FF21}\u{FF21}|\u{FF21}\u{FF21}")
        #expect(wrap(vaiSyllables, breakAfter: 5, columns: 3, twoCells: false) == "\u{A500}|\u{A500}|\u{A500}|\u{A500}")
        #expect(wrap(vaiSyllables, breakAfter: 5, columns: 3, twoCells: true) == "\u{A500}\u{A500}|\u{A500}\u{A500}")
    }

    @Test func twoCellWidthPreservesNaturalControlCharacterMetrics() {
        #expect(wrap("\u{0001}\u{0001}", breakAfter: 4, columns: 3, twoCells: false) == "\u{0001}|\u{0001}")
        #expect(wrap("\u{0001}\u{0001}", breakAfter: 4, columns: 3, twoCells: true) == "\u{0001}|\u{0001}")
        let natural = lineBreakData(cjkClasses, tabSize: 4, breakAfter: 3, columnsForFullWidthChar: 3,
                                    text: "\u{0001}\t", useTwoCellFullwidthCharacters: false)
        let twoCells = lineBreakData(cjkClasses, tabSize: 4, breakAfter: 3, columnsForFullWidthChar: 3,
                                     text: "\u{0001}\t", useTwoCellFullwidthCharacters: true)
        #expect(natural?.breakOffsetsVisibleColumn == [3, 4])
        #expect(twoCells?.breakOffsetsVisibleColumn == [3, 4])
    }

    @Test func twoCellWidthTreatsCombiningMarksIndependently() {
        let text = "\u{3042}\u{0301}aa"
        #expect(text.utf16.count == 4)
        #expect(wrap(text, breakAfter: 4, columns: 3, twoCells: false) == "\u{3042}|\u{0301}aa")
        #expect(wrap(text, breakAfter: 4, columns: 3, twoCells: true) == "\u{3042}|\u{0301}aa")
    }

    @Test func twoCellWidthSupportsIncrementalLineBreaks() {
        let f = BreakClasses.vscodeDefaults
        assertIncrementalLineBreaks(
            f, "ああああああ", 4,
            5, "ああ|ああ|ああ",
            7, "あああ|あああ",
            .none, 3, true
        )
        assertIncrementalLineBreaks(
            f, "    ああああ", 4,
            8, "    ああ|ああ",
            10, "    あああ|あ",
            .same, 3, true
        )
        let text = "你好 **hello** **hello** **hello-world** hey there!"
        assertIncrementalLineBreaks(
            f, text, 4,
            15, "你好 **hello** |**hello** |**hello-world**| hey there!",
            1, everyUnitOnItsOwnLine(text),
            .same, 1.6605405405405405, true
        )
    }

    @Test func wrappingIndentSame() {
        assertLineBreaks(BreakClasses(before: "", after: "\t "), 4, 38, " *123456789012345678901234567890123456|7890", .same)
    }

    @Test func issue16332_scrollBarOverlayingText() {
        assertLineBreaks(BreakClasses(before: "", after: "\t "), 4, 24,
                         "a/ very/long/line/of/tex|t/that/expands/beyon|d/your/typical/line/|of/code/", .indent)
    }

    @Test func issue35162_wrappingIndentNotConsistent() {
        let projection = assertLineBreaks(BreakClasses(before: "", after: "\t "), 4, 24,
                                          "                t h i s |i s |a l |o n |g l |i n |e", .indent)
        #expect(projection?.wrappedTextIndentLength == 20)
    }

    @Test func issue75494_surrogatePairs() {
        assertLineBreaks(BreakClasses(before: "\t", after: " "), 4, 49,
                         "🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼|🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼|🐇👬", .same)
    }

    @Test func issue75494_surrogatePairsOverrun1() {
        assertLineBreaks(.vscodeDefaults, 4, 4, "🐇👬|&|🌞🌖", .same)
    }

    @Test func issue75494_surrogatePairsOverrun2() {
        assertLineBreaks(.vscodeDefaults, 4, 17, "factory, |\"xtxtfunc|(x\"🌞🏇🍼🌞🏇🍼🐇|&👬🌖🌞👬🌖🌞🏇🍼|🐇👬x\"", .same)
    }

    @Test func wrappingIndentDeepIndent() {
        let projection = assertLineBreaks(BreakClasses(before: "", after: "\t "), 4, 26,
                                          "        W e A r e T e s t |i n g D e |e p I n d |e n t a t |i o n", .deepIndent)
        #expect(projection?.wrappedTextIndentLength == 16)
    }

    @Test func issue33366_punctuation() {
        assertLineBreaks(.vscodeDefaults, 4, 23, "this is a line of |text, text that sits |on a line", .same)
    }

    @Test func issue152773_bracketFollowedByComma() {
        assertLineBreaks(.vscodeDefaults, 4, 24, "this is a line of |(text), text that sits |on a line", .same)
    }

    @Test func issue112382_controlCharacters() {
        assertLineBreaks(.vscodeDefaults, 4, 6, "\u{06}\u{06}\u{06}|\u{06}\u{06}\u{06}", .same)
    }

    @Test func cjkWordBreakNormal() {
        assertLineBreaks(.vscodeDefaults, 4, 5, "你好|1111", .same, .normal)
    }

    @Test func cjkWordBreakKeepAll() {
        assertLineBreaks(.vscodeDefaults, 4, 8, "你好1111", .same, .keepAll)
    }

    @Test func returnedProjections_alwaysHaveMoreThanOneSegment() {
        let texts = ["a", "ab", "abc def", "foo_bar it's 3.14 かなカナ漢字ひらがな end", "\t\tindented words here",
                     "x" + String(repeating: " y", count: 40), String(repeating: "漢", count: 30), "😀😀😀 a b"]
        for text in texts {
            for column in 1...45 {
                var previous: DiffLineProjection?
                for wrap in [column, column + 3, max(1, column - 2), column] {
                    let projection = lineBreakData(.vscodeDefaults, tabSize: 4, breakAfter: wrap, wrappingIndent: .same,
                                                   text: text, previous: previous)
                    if let projection {
                        #expect(projection.segmentCount > 1, "\(text) at \(wrap): a projection is a wrapped row")
                    }
                    previous = projection
                }
            }
        }
    }
}
