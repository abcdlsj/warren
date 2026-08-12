import Foundation
import XCTest
@testable import BurrowTerminalRenderer
import BurrowDomain
import BurrowProtocol
import BurrowClientCore

final class BurrowTerminalRendererTests: XCTestCase {
    func testEmberPaletteMatchesSupersetDefaultDarkTheme() {
        XCTAssertEqual(TerminalPalette.ember.count, 16)
        XCTAssertEqual(TerminalPalette.ember[0], TerminalPaletteColor(red: 0x15, green: 0x11, blue: 0x10))
        XCTAssertEqual(TerminalPalette.ember[1], TerminalPaletteColor(red: 0xdc, green: 0x6b, blue: 0x6b))
        XCTAssertEqual(TerminalPalette.ember[8], TerminalPaletteColor(red: 0x5c, green: 0x58, blue: 0x56))
        XCTAssertEqual(TerminalPalette.ember[15], TerminalPaletteColor(red: 0xff, green: 0xff, blue: 0xff))
    }

    func testOutputMustBeStrictlyOrdered() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(
            sessionID: sessionID,
            clientID: ClientID()
        )
        let viewport = try XCTUnwrap(TerminalViewport(columns: 80, rows: 24))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(
            for: attachment,
            viewport: viewport,
            anchor: RecoveryAnchor(epoch: 3, sequence: 0)
        )

        try await renderer.render(try frame(sessionID: sessionID, epoch: 3, sequence: 0, bytes: [65]), on: surface)
        try await renderer.render(try frame(sessionID: sessionID, epoch: 3, sequence: 1, bytes: [66, 67]), on: surface)

        do {
            try await renderer.render(
                try frame(sessionID: sessionID, epoch: 3, sequence: 4, bytes: [68]),
                on: surface
            )
            XCTFail("Out-of-order output must be rejected")
        } catch {
            XCTAssertEqual(
                error as? TerminalRendererError,
                .outputOutOfOrder(expected: 3, received: 4)
            )
        }

        let state = try await state(of: surface, from: renderer)
        XCTAssertEqual(state.outputs, [Data([65]), Data([66, 67])])
        XCTAssertTrue(state.needsReanchor)
    }

    func testEpochMismatchRequiresExplicitReanchor() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let viewport = try XCTUnwrap(TerminalViewport(columns: 100, rows: 30))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(
            for: attachment,
            viewport: viewport,
            anchor: RecoveryAnchor(epoch: 1, sequence: 7)
        )

        do {
            try await renderer.render(
                try frame(sessionID: sessionID, epoch: 2, sequence: 0, bytes: [88]),
                on: surface
            )
            XCTFail("An epoch change must require reanchor")
        } catch {
            XCTAssertEqual(
                error as? TerminalRendererError,
                .outputEpochMismatch(expected: 1, received: 2)
            )
        }

        do {
            try await renderer.render(
                try frame(sessionID: sessionID, epoch: 1, sequence: 7, bytes: [89]),
                on: surface
            )
            XCTFail("Frames must remain blocked until reanchor")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .reanchorRequired(surface.id))
        }

        try await renderer.reanchor(RecoveryAnchor(epoch: 2, sequence: 0), on: surface)
        try await renderer.render(try frame(sessionID: sessionID, epoch: 2, sequence: 0, bytes: [90]), on: surface)

        let state = try await state(of: surface, from: renderer)
        XCTAssertEqual(state.expectedAnchor, RecoveryAnchor(epoch: 2, sequence: 1))
        XCTAssertFalse(state.needsReanchor)
        XCTAssertEqual(state.reanchors, [RecoveryAnchor(epoch: 2, sequence: 0)])
    }

    func testInputEventsMapToTerminalBytes() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let viewport = try XCTUnwrap(TerminalViewport(columns: 80, rows: 24))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(for: attachment, viewport: viewport)

        try await renderer.send(.text("hi"), to: surface)
        try await renderer.send(.bytes(Data([0xF0, 0x9F])), to: surface)
        try await renderer.send(.escape, to: surface)
        try await renderer.send(.control("c"), to: surface)
        try await renderer.send(.tab, to: surface)
        try await renderer.send(.arrow(.up), to: surface)
        try await renderer.send(.arrow(.left), to: surface)

        let state = try await state(of: surface, from: renderer)
        XCTAssertEqual(
            state.inputs,
            [
                Data([0x68, 0x69]),
                Data([0xF0, 0x9F]),
                Data([0x1B]),
                Data([0x03]),
                Data([0x09]),
                Data([0x1B, 0x5B, 0x41]),
                Data([0x1B, 0x5B, 0x44]),
            ]
        )
    }

    func testDisposeOnlyDestroysSurface() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let otherSessionID = TerminalSessionID()
        let otherAttachment = TerminalAttachment(sessionID: otherSessionID, clientID: ClientID())
        let viewport = try XCTUnwrap(TerminalViewport(columns: 80, rows: 24))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(for: attachment, viewport: viewport)
        let otherSurface = try await renderer.createSurface(for: otherAttachment, viewport: viewport)

        await renderer.dispose(surface)

        let events = await renderer.events()
        XCTAssertEqual(events, [.dispose(surface.id)])
        let otherState = try await state(of: otherSurface, from: renderer)
        XCTAssertEqual(otherState.surface.sessionID, otherSessionID)
        do {
            try await renderer.send(.text("disposed"), to: surface)
            XCTFail("A disposed surface must reject further operations")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .surfaceDisposed(surface.id))
        }
    }

    private func frame(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        bytes: [UInt8]
    ) throws -> BinaryOutputFrame {
        let header = try XCTUnwrap(
            BinaryOutputFrameHeader(
                sessionID: sessionID,
                epoch: epoch,
                sequence: sequence,
                payloadLength: bytes.count
            )
        )
        return BinaryOutputFrame(header: header, payload: Data(bytes))
    }

    private func state(
        of surface: TerminalSurface,
        from renderer: InMemoryTerminalRenderer
    ) async throws -> InMemoryTerminalRenderer.SurfaceState {
        let value = await renderer.state(for: surface)
        return try XCTUnwrap(value)
    }
}
