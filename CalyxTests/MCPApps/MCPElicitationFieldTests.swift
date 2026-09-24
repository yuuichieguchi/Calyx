//
//  MCPElicitationFieldTests.swift
//  CalyxTests
//
//  `MCPElicitationField.init(name:schema:isRequired:)` (MCPElicitationPanel.swift):
//  pins the `schema["default"]` prefill of `text`, `isOn`, and `choice`
//  performed by `prefill(from:)`. The previous `??` chain crashed the
//  Release (-O, whole-module) Swift compiler in CopyPropagation, so the
//  helper must keep exactly this behavior. `AnyCodable`'s typed accessors
//  (JSONRPC.swift) never coerce across storage cases, so e.g. an int
//  default never satisfies `stringValue`.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPElicitationFieldTests: XCTestCase {

    // MARK: - string field

    func test_stringDefault_prefillsTextAndChoice() {
        let field = MCPElicitationField(
            name: "name",
            schema: ["type": AnyCodable("string"), "default": AnyCodable("Ada")],
            isRequired: false
        )
        XCTAssertEqual(field.text, "Ada")
        XCTAssertEqual(field.choice, "Ada")
        XCTAssertFalse(field.isOn)
        XCTAssertEqual(field.kind, .text)
        XCTAssertEqual(field.value, AnyCodable("Ada"))
        XCTAssertTrue(field.isValid)
    }

    // MARK: - integer field

    func test_intDefault_prefillsTextAsStringifiedInt() {
        let field = MCPElicitationField(
            name: "count",
            schema: ["type": AnyCodable("integer"), "default": AnyCodable(3)],
            isRequired: false
        )
        XCTAssertEqual(field.text, "3")
        XCTAssertNil(field.choice)
        XCTAssertFalse(field.isOn)
        XCTAssertEqual(field.kind, .number(integer: true))
        XCTAssertEqual(field.value, AnyCodable(3))
        XCTAssertTrue(field.isValid)
    }

    // MARK: - number field

    func test_doubleDefault_prefillsTextAsStringifiedDouble() {
        let field = MCPElicitationField(
            name: "ratio",
            schema: ["type": AnyCodable("number"), "default": AnyCodable(1.5)],
            isRequired: false
        )
        XCTAssertEqual(field.text, "1.5")
        XCTAssertNil(field.choice)
        XCTAssertFalse(field.isOn)
        XCTAssertEqual(field.kind, .number(integer: false))
        XCTAssertEqual(field.value, AnyCodable(1.5))
    }

    // MARK: - boolean field

    func test_boolDefaultTrue_setsIsOnTrue_textEmpty_choiceNil() {
        let field = MCPElicitationField(
            name: "flag",
            schema: ["type": AnyCodable("boolean"), "default": AnyCodable(true)],
            isRequired: false
        )
        XCTAssertTrue(field.isOn)
        XCTAssertEqual(field.text, "")
        XCTAssertNil(field.choice)
        XCTAssertEqual(field.kind, .boolean)
        XCTAssertEqual(field.value, AnyCodable(true))
    }

    func test_boolDefaultFalse_setsIsOnFalse() {
        let field = MCPElicitationField(
            name: "flag",
            schema: ["type": AnyCodable("boolean"), "default": AnyCodable(false)],
            isRequired: false
        )
        XCTAssertFalse(field.isOn)
        XCTAssertEqual(field.text, "")
        XCTAssertNil(field.choice)
        XCTAssertEqual(field.value, AnyCodable(false))
    }

    // MARK: - cross-type default

    func test_intDefaultOnStringField_prefillsTextOnly() {
        let field = MCPElicitationField(
            name: "name",
            schema: ["type": AnyCodable("string"), "default": AnyCodable(3)],
            isRequired: false
        )
        XCTAssertEqual(field.text, "3")
        XCTAssertNil(field.choice)
        XCTAssertFalse(field.isOn)
    }

    // MARK: - enum/choice field

    func test_enumField_stringDefault_prefillsChoice() {
        let field = MCPElicitationField(
            name: "color",
            schema: [
                "type": AnyCodable("string"),
                "enum": AnyCodable([AnyCodable("red"), AnyCodable("green")]),
                "default": AnyCodable("green"),
            ],
            isRequired: false
        )
        XCTAssertEqual(field.choice, "green")
        XCTAssertEqual(field.text, "green")
        XCTAssertFalse(field.isOn)
        XCTAssertEqual(
            field.kind,
            .choice([
                MCPElicitationChoice(value: "red", title: "red"),
                MCPElicitationChoice(value: "green", title: "green"),
            ])
        )
        XCTAssertEqual(field.value, AnyCodable("green"))
    }

    // MARK: - no default

    func test_noDefault_leavesTextEmptyIsOnFalseChoiceNil() {
        let field = MCPElicitationField(
            name: "name",
            schema: ["type": AnyCodable("string")],
            isRequired: true
        )
        XCTAssertEqual(field.text, "")
        XCTAssertFalse(field.isOn)
        XCTAssertNil(field.choice)
        XCTAssertNil(field.value)
        XCTAssertFalse(field.isValid)
    }

    // MARK: - non-scalar default

    func test_arrayDefault_leavesTextEmptyIsOnFalseChoiceNil() {
        let field = MCPElicitationField(
            name: "tags",
            schema: [
                "type": AnyCodable("string"),
                "default": AnyCodable([AnyCodable("a"), AnyCodable("b")]),
            ],
            isRequired: false
        )
        XCTAssertEqual(field.text, "")
        XCTAssertFalse(field.isOn)
        XCTAssertNil(field.choice)
    }

    func test_dictionaryDefault_leavesTextEmptyIsOnFalseChoiceNil() {
        let field = MCPElicitationField(
            name: "name",
            schema: [
                "type": AnyCodable("string"),
                "default": AnyCodable(["k": AnyCodable("v")]),
            ],
            isRequired: false
        )
        XCTAssertEqual(field.text, "")
        XCTAssertFalse(field.isOn)
        XCTAssertNil(field.choice)
    }

    func test_nullDefault_leavesTextEmptyIsOnFalseChoiceNil() {
        let field = MCPElicitationField(
            name: "name",
            schema: ["type": AnyCodable("string"), "default": AnyCodable.null],
            isRequired: false
        )
        XCTAssertEqual(field.text, "")
        XCTAssertFalse(field.isOn)
        XCTAssertNil(field.choice)
    }
}
