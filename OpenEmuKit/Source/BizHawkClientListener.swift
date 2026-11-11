// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
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

import Foundation
import Network
import OpenEmuBase
internal import os.log

/// Accepts Archipelago's BizHawk Client on 127.0.0.1, ports 43055–43059.
///
/// Each game takes the first free port, so several games can be open at once. One client at a time:
/// the port closes while a client is connected, and a game may get a different port when it reopens.
/// Every message is answered by `BizHawkClientCodec`, with memory steps run between two frames
/// through `ArchipelagoConnections`. All state belongs to `queue`.
final class BizHawkClientListener: @unchecked Sendable {

    /// A client message is a few kilobytes at most; anything this large without a line break is not one.
    private static let maximumBufferedBytes = 4 * 1024 * 1024

    /// How long to wait before trying the ports again when all of them are taken.
    private static let retryDelay: TimeInterval = 2

    private let queue: DispatchQueue
    private let codec: BizHawkClientCodec
    private unowned let connections: ArchipelagoConnections

    private var listener: NWListener?
    private var client: NWConnection?
    private var received = Data()
    private var busy = false
    private var stopped = false

    init(queue: DispatchQueue, codec: BizHawkClientCodec, connections: ArchipelagoConnections) {
        self.queue = queue
        self.codec = codec
        self.connections = connections
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        listen(on: BizHawkClientCodec.ports.lowerBound)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        stopped = true
        dropClient()
        listener?.cancel()
        listener = nil
    }

    func dropClient() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let client else { return }
        client.cancel()
        self.client = nil
        received.removeAll()
        busy = false
        connections.clientDisconnected()
        os_log(.info, log: .archipelago, "BizHawk Client disconnected")
        if !stopped && listener == nil {
            listen(on: BizHawkClientCodec.ports.lowerBound)
        }
    }

    // MARK: - Listening

    private func listen(on port: UInt16) {
        guard !stopped else { return }
        guard BizHawkClientCodec.ports.contains(port), let nwPort = NWEndpoint.Port(rawValue: port) else {
            os_log(.error, log: .archipelago, "No free port for BizHawk Client between %d and %d",
                   BizHawkClientCodec.ports.lowerBound, BizHawkClientCodec.ports.upperBound)
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                guard let self, self.listener == nil, self.client == nil else { return }
                self.listen(on: BizHawkClientCodec.ports.lowerBound)
            }
            return
        }

        // Loopback only: nothing outside this Mac can connect. There is no authentication, as in BizHawk's own
        // connector, so any program on this Mac can. docs/archipelago.md and the Debug checkbox say so.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            listen(on: port + 1)
            return
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                os_log(.info, log: .archipelago, "Waiting for BizHawk Client on 127.0.0.1:%d", port)
            case .failed, .waiting:
                // Another game or emulator has this port: try the next one.
                listener.cancel()
                if self.listener === listener {
                    self.listener = nil
                    self.listen(on: port + 1)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard client == nil, connections.acceptsClients else {
            connection.cancel()
            return
        }

        // Stop listening while a client is connected, as BizHawk's connector does. A second client must be
        // refused outright: only then does Archipelago's client move on to the next port and find the next game.
        listener?.cancel()
        listener = nil

        client = connection
        received.removeAll()
        busy = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.client === connection else { return }
            switch state {
            case .failed, .cancelled:
                self.dropClient()
            default:
                break
            }
        }
        connection.start(queue: queue)
        os_log(.info, log: .archipelago, "BizHawk Client connected")
        receive(on: connection)
    }

    // MARK: - Messages

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.client === connection else { return }

            if let data, !data.isEmpty {
                self.received.append(data)
                if self.received.count > Self.maximumBufferedBytes {
                    os_log(.error, log: .archipelago, "BizHawk Client sent too much without a line break")
                    self.dropClient()
                    return
                }
                self.handleNextLine()
            }

            if isComplete || error != nil {
                self.dropClient()
            } else {
                self.receive(on: connection)
            }
        }
    }

    /// Answers buffered lines one at a time, in order. The client waits for each reply before sending more.
    private func handleNextLine() {
        guard !busy, let client, let newline = received.firstIndex(of: UInt8(ascii: "\n")) else { return }

        let lineData = received[received.startIndex..<newline]
        received.removeSubrange(received.startIndex...newline)
        let line = String(decoding: lineData, as: UTF8.self)

        guard connections.acceptsClients else {
            dropClient()
            return
        }

        switch codec.decode(line) {
        case .reply(let text):
            send(text, to: client)

        case .run(let request):
            busy = true
            connections.run(request.operations) { [weak self] results in
                guard let self, self.client === client else { return }
                self.busy = false
                self.send(self.codec.encode(request, results: results), to: client)
            }
        }
    }

    private func send(_ text: String, to connection: NWConnection) {
        connection.send(content: Data((text + "\n").utf8), completion: .contentProcessed { [weak self] error in
            guard let self, self.client === connection else { return }
            if error != nil {
                self.dropClient()
            } else {
                self.handleNextLine()
            }
        })
    }
}
