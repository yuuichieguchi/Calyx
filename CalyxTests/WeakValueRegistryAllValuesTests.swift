import XCTest
@testable import Calyx

private final class RegistryEntry {}

final class WeakValueRegistryAllValuesTests: XCTestCase {

    func test_allValues_returnsEveryLiveValue() {
        let registry = WeakValueRegistry<Int, RegistryEntry>()
        let first = RegistryEntry()
        let second = RegistryEntry()
        registry.register(1, value: first)
        registry.register(2, value: second)

        let values = registry.allValues()

        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains { $0 === first })
        XCTAssertTrue(values.contains { $0 === second })
    }

    func test_allValues_excludesReleasedValue() {
        let registry = WeakValueRegistry<Int, RegistryEntry>()
        let survivor = RegistryEntry()
        registry.register(1, value: survivor)
        var released: RegistryEntry? = RegistryEntry()
        registry.register(2, value: released!)
        released = nil

        let values = registry.allValues()

        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(values.first === survivor)
        XCTAssertNil(released)
    }

    func test_allValues_emptyRegistry_returnsEmpty() {
        let registry = WeakValueRegistry<Int, RegistryEntry>()

        XCTAssertTrue(registry.allValues().isEmpty)
    }
}
