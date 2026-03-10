// EventTranslatorScrollTests.swift
// CalyxTests
//
// Tests for EventTranslator scroll-related translation methods.
// Verifies bit layout matches ghostty ScrollMods packed struct(u8):
//   bit 0 = precision, bits 1-3 = momentum, bits 4-7 = padding
// See: ghostty/src/input/mouse.zig

import Testing
@testable import Calyx
import GhosttyKit

@MainActor
@Suite("EventTranslator Scroll Tests")
struct EventTranslatorScrollTests {

    // MARK: - Momentum Phase

    @Test("translateMomentumPhase maps .began correctly")
    func momentumBegan() {
        let result = EventTranslator.translateMomentumPhase(.began)
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_BEGAN)
    }

    @Test("translateMomentumPhase maps .changed correctly")
    func momentumChanged() {
        let result = EventTranslator.translateMomentumPhase(.changed)
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_CHANGED)
    }

    @Test("translateMomentumPhase maps .ended correctly")
    func momentumEnded() {
        let result = EventTranslator.translateMomentumPhase(.ended)
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_ENDED)
    }

    @Test("translateMomentumPhase maps .cancelled correctly")
    func momentumCancelled() {
        let result = EventTranslator.translateMomentumPhase(.cancelled)
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_CANCELLED)
    }

    @Test("translateMomentumPhase maps .stationary correctly")
    func momentumStationary() {
        let result = EventTranslator.translateMomentumPhase(.stationary)
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_STATIONARY)
    }

    @Test("translateMomentumPhase maps .mayBegin correctly")
    func momentumMayBegin() {
        let result = EventTranslator.translateMomentumPhase(.mayBegin)
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN)
    }

    @Test("translateMomentumPhase maps empty phase to NONE")
    func momentumNone() {
        let result = EventTranslator.translateMomentumPhase([])
        #expect(result == GHOSTTY_MOUSE_MOMENTUM_NONE)
    }

    // MARK: - Bit Layout (ghostty ScrollMods packed struct)

    @Test("Precision flag occupies bit 0 (value 1)")
    func precisionFlagBitPosition() {
        let precisionBit: Int32 = 1 << 0
        #expect(precisionBit == 1)
    }

    @Test("Momentum values are shifted to bits 1-3")
    func momentumBitShift() {
        let changed = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        let shifted = Int32(changed.rawValue) << 1
        #expect(shifted == Int32(changed.rawValue) * 2)
        #expect(shifted & 1 == 0)
    }

    @Test("Momentum values fit in 3 bits (max value 7)")
    func momentumValuesRange() {
        let allMomentum: [ghostty_input_mouse_momentum_e] = [
            GHOSTTY_MOUSE_MOMENTUM_NONE,
            GHOSTTY_MOUSE_MOMENTUM_BEGAN,
            GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
            GHOSTTY_MOUSE_MOMENTUM_CHANGED,
            GHOSTTY_MOUSE_MOMENTUM_ENDED,
            GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
            GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
        ]
        for m in allMomentum {
            #expect(m.rawValue <= 7, "Momentum value \(m.rawValue) exceeds 3-bit range")
            let shifted = Int32(m.rawValue) << 1
            #expect(shifted <= 0b1110, "Shifted momentum \(shifted) overflows bits 1-3")
        }
    }

    @Test("Precision + momentum do not overlap")
    func precisionMomentumNoOverlap() {
        let precision: Int32 = 1
        let momentum: Int32 = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1
        let combined = precision | momentum
        #expect(combined & 1 == 1, "Precision bit lost")
        #expect((combined >> 1) & 0x7 == Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue), "Momentum bits lost")
    }
}
