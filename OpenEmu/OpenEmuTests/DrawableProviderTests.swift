// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import XCTest
@testable import OpenEmuKit

final class DrawableProviderTests: XCTestCase {
    func testTakeReturnsWithoutWaitingForDisplay() {
        let queue = DispatchQueue(label: "test.drawables.blocked")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let provider = DrawableProvider<Int>(queue: queue) {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return 1
        }
        defer { provider.stop() }
        XCTAssertNil(provider.take())
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let start = Date()
        XCTAssertNil(provider.take())
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        release.signal()
        queue.sync {}
        XCTAssertEqual(provider.take(), 1)
    }

    func testOnlyOneAcquisitionCanBePending() {
        let queue = DispatchQueue(label: "test.drawables.bounded")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var requests = 0
        let provider = DrawableProvider<Int>(queue: queue) {
            requests += 1
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return requests
        }
        XCTAssertNil(provider.take())
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        for _ in 0..<100 { XCTAssertNil(provider.take()) }
        release.signal()
        queue.sync {}
        provider.stop()
        XCTAssertEqual(requests, 1)
    }

    func testResizeDiscardsAnAcquisitionAlreadyInProgress() {
        let queue = DispatchQueue(label: "test.drawables.resize")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var requests = 0
        let provider = DrawableProvider<Int>(queue: queue) {
            requests += 1
            if requests == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return requests
        }
        defer { provider.stop() }
        XCTAssertNil(provider.take())
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        provider.invalidate()
        release.signal()
        queue.sync {}
        XCTAssertNil(provider.take())
        queue.sync {}
        XCTAssertEqual(provider.take(), 2)
    }

    func testStopDiscardsPendingResultAndPreventsMoreRequests() {
        let queue = DispatchQueue(label: "test.drawables.stop")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var requests = 0
        let provider = DrawableProvider<Int>(queue: queue) {
            requests += 1
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            return requests
        }
        XCTAssertNil(provider.take())
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        provider.stop()
        release.signal()
        queue.sync {}
        XCTAssertNil(provider.take())
        queue.sync {}
        XCTAssertEqual(requests, 1)
    }

    func testStopCancelsAnAcquisitionThatHasNotStarted() {
        let queue = DispatchQueue(label: "test.drawables.cancel")
        queue.suspend()
        var requests = 0
        let provider = DrawableProvider<Int>(queue: queue) {
            requests += 1
            return requests
        }
        XCTAssertNil(provider.take())
        provider.stop()
        queue.resume()
        queue.sync {}
        XCTAssertNil(provider.take())
        XCTAssertEqual(requests, 0)
    }

    func testUnavailableDrawableIsRetriedOnNextFrame() {
        let queue = DispatchQueue(label: "test.drawables.retry")
        var requests = 0
        let provider = DrawableProvider<Int>(queue: queue) {
            requests += 1
            return requests == 1 ? nil : requests
        }
        defer { provider.stop() }
        XCTAssertNil(provider.take())
        queue.sync {}
        XCTAssertNil(provider.take())
        queue.sync {}
        XCTAssertEqual(provider.take(), 2)
    }
}
