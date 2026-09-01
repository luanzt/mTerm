import Foundation
import AppKit
import SwiftTerm
import XCTest
@testable import mTerm

final class TerminalFileDropTests: XCTestCase {
    func testNativeTerminalRegistersForFinderFileURLs() {
        let terminal = FileDroppableTerminalView(frame: .zero)

        XCTAssertTrue(terminal.registeredDraggedTypes.contains(.fileURL))
    }

    func testNativeDropReadsFileURLFromPasteboard() {
        let pasteboard = NSPasteboard(name: .init("mterm-file-drop-\(UUID().uuidString)"))
        let url = URL(fileURLWithPath: "/tmp/Simulator Screenshot.png")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        XCTAssertEqual(FileDroppableTerminalView.fileURLs(from: pasteboard), [url])
    }

    func testFinderImageFileIsRecognizedAsImagePaste() {
        let pasteboard = NSPasteboard(name: .init("mterm-image-paste-\(UUID().uuidString)"))
        let url = URL(fileURLWithPath: "/tmp/Simulator Screenshot.png")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        XCTAssertTrue(TerminalImagePaste.hasImage(in: pasteboard))
    }

    func testClipboardBitmapIsRecognizedAsImagePaste() throws {
        let pasteboard = NSPasteboard(name: .init("mterm-bitmap-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try pngData(), forType: .png))

        XCTAssertTrue(TerminalImagePaste.hasImage(in: pasteboard))
    }

    func testFinderNonImageFileIsNotMistakenForGeneratedIconBitmap() throws {
        let pasteboard = NSPasteboard(name: .init("mterm-file-icon-paste-\(UUID().uuidString)"))
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(url.absoluteString, forType: .fileURL))
        XCTAssertTrue(item.setData(try pngData(), forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertEqual(FileDroppableTerminalView.fileURLs(from: pasteboard), [url])

        XCTAssertFalse(TerminalImagePaste.hasImage(in: pasteboard))
    }

    func testClipboardTextIsNotRecognizedAsImagePaste() {
        let pasteboard = NSPasteboard(name: .init("mterm-text-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("plain text", forType: .string))

        XCTAssertFalse(TerminalImagePaste.hasImage(in: pasteboard))
    }


    func testOnlyOMPInterceptsImageClipboard() throws {
        let pasteboard = NSPasteboard(name: .init("mterm-agent-image-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try pngData(), forType: .png))

        XCTAssertTrue(
            TerminalImagePaste.shouldHandle(pasteboard, foregroundCommand: "omp")
        )
        XCTAssertFalse(
            TerminalImagePaste.shouldHandle(pasteboard, foregroundCommand: "claude")
        )
        XCTAssertFalse(
            TerminalImagePaste.shouldHandle(pasteboard, foregroundCommand: "codex")
        )
        XCTAssertFalse(
            TerminalImagePaste.shouldHandle(pasteboard, foregroundCommand: nil)
        )
    }

    func testCoordinatorMaterializesClipboardBitmapInsteadOfForwardingStaleCleanShotURL() throws {
        let pasteboard = NSPasteboard(name: .init("mterm-omp-image-paste-\(UUID().uuidString)"))
        let staleURL = URL(
            fileURLWithPath:
                "/Users/test/Library/Application Support/CleanShot/media/missing/CleanShot 2026-08-16.png"
        )
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(staleURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(item.setData(try pngData(), forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let terminal = RecordingLocalProcessTerminalView(frame: .zero)
        let coordinator = TerminalHostView.Coordinator(restorationIntent: nil)
        coordinator.foregroundCommand = "omp"

        XCTAssertTrue(coordinator.receiveImagePaste(pasteboard, in: terminal))

        let input = String(decoding: terminal.sentBytes, as: UTF8.self)
        let prefix = "\u{1B}[200~"
        let suffix = "\u{1B}[201~"
        XCTAssertTrue(input.hasPrefix(prefix))
        XCTAssertTrue(input.hasSuffix(suffix))
        let materializedPath = String(input.dropFirst(prefix.count).dropLast(suffix.count))
        guard !materializedPath.isEmpty else {
            return XCTFail("Expected a materialized clipboard image path")
        }
        defer { try? FileManager.default.removeItem(atPath: materializedPath) }
        XCTAssertNotEqual(materializedPath, staleURL.path)
        XCTAssertEqual(URL(fileURLWithPath: materializedPath).pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedPath))
        XCTAssertNotNil(NSImage(contentsOfFile: materializedPath))
    }

    func testRecognizedOMPImageFailureIsConsumedWithoutForwardingStaleURL() {
        let pasteboard = NSPasteboard(name: .init("mterm-invalid-image-paste-\(UUID().uuidString)"))
        let staleURL = URL(
            fileURLWithPath:
                "/Users/test/Library/Application Support/CleanShot/media/missing/CleanShot.png"
        )
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(staleURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(item.setString(staleURL.path, forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let terminal = RecordingLocalProcessTerminalView(frame: .zero)
        let coordinator = TerminalHostView.Coordinator(restorationIntent: nil)
        coordinator.foregroundCommand = "omp"

        XCTAssertTrue(coordinator.receiveImagePaste(pasteboard, in: terminal))
        XCTAssertTrue(terminal.sentBytes.isEmpty)
    }

    func testShellInputForNoFilesIsEmpty() {
        XCTAssertEqual(TerminalFileDrop.shellInput(for: []), "")
    }

    func testShellInputEscapesSpacesAndSeparatesMultipleFiles() {
        let urls = [
            URL(fileURLWithPath: "/tmp/first file.txt"),
            URL(fileURLWithPath: "/tmp/second.txt"),
        ]

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: urls),
            "/tmp/first\\ file.txt /tmp/second.txt "
        )
    }

    func testShellInputEscapesOnlyShellSpecialCharacters() {
        let url = URL(fileURLWithPath: "/tmp/it's here.txt")

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: [url]),
            "/tmp/it\\'s\\ here.txt "
        )
    }

    func testShellInputLeavesSimplePathUnquoted() {
        let url = URL(fileURLWithPath: "/tmp/script.sh")

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: [url]),
            "/tmp/script.sh "
        )
    }

    func testShellInputEscapesExpansionAndGlobCharacters() {
        let url = URL(fileURLWithPath: "/tmp/$draft*.txt")

        XCTAssertEqual(
            TerminalFileDrop.shellInput(for: [url]),
            "/tmp/\\$draft\\*.txt "
        )
    }

    func testShellInputDoesNotExecuteDroppedFile() {
        let url = URL(fileURLWithPath: "/tmp/script.sh")

        XCTAssertFalse(TerminalFileDrop.shellInput(for: [url]).contains("\n"))
    }

    func testImageDropUsesRawBracketedPathWithoutTrailingSpace() {
        let url = URL(fileURLWithPath: "/tmp/Simulator Screenshot.png")

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: [url],
            bracketedPaste: true,
            foregroundCommand: nil
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(
            String(decoding: chunks[0], as: UTF8.self),
            "\u{1B}[200~/tmp/Simulator Screenshot.png\u{1B}[201~"
        )
    }

    func testOMPDropUsesBracketedPasteBeforeTerminalModeIsObserved() {
        let url = URL(fileURLWithPath: "/tmp/screenshot.png")

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: [url],
            bracketedPaste: false,
            foregroundCommand: "omp"
        )

        XCTAssertEqual(
            chunks.map { String(decoding: $0, as: UTF8.self) },
            ["\u{1B}[200~/tmp/screenshot.png\u{1B}[201~"]
        )
    }

    func testBracketedPasteEmitsOneEventPerDroppedImage() {
        let urls = [
            URL(fileURLWithPath: "/tmp/one.png"),
            URL(fileURLWithPath: "/tmp/two.jpg"),
        ]

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: urls,
            bracketedPaste: true,
            foregroundCommand: nil
        )

        XCTAssertEqual(chunks.count, 2)
    }

    func testImageDropForcesBracketedPasteBeforeTerminalModeIsObserved() {
        let url = URL(fileURLWithPath: "/tmp/screenshot.png")

        let chunks = TerminalFileDrop.terminalInputChunks(
            for: [url],
            bracketedPaste: false,
            foregroundCommand: nil
        )

        XCTAssertEqual(
            chunks.map { String(decoding: $0, as: UTF8.self) },
            ["\u{1B}[200~/tmp/screenshot.png\u{1B}[201~"]
        )
    }

    private func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 8,
            bitsPerPixel: 32
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class RecordingLocalProcessTerminalView: LocalProcessTerminalView {
    private(set) var sentBytes: [UInt8] = []

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sentBytes.append(contentsOf: data)
    }
}
