// IMAPCommand.swift
// Base protocol for all IMAP commands

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// A protocol for all IMAP commands that know their handler type.
///
/// Refines `SendableMetatype` so a conformance can never be actor-isolated. Every command is
/// handed down to `IMAPConnection`, whose `nonisolated` `async` execution path runs on the
/// concurrent executor, and a conformance that *may* be isolated cannot cross into one — which
/// is what the compiler warns about at each `executeCommand` forwarding site otherwise. Stating
/// the requirement on the protocol rather than at those call sites is the narrower change: it is
/// a marker protocol with no runtime representation, it matches what every conformer here
/// already is (plain non-isolated `struct`s in this module — `IMAPCommand` is internal, so no
/// other module can add an isolated one), and it changes nothing about where commands execute.
protocol IMAPCommand: SendableMetatype where ResultType: Sendable {
    /// The result type this command produces
    associatedtype ResultType

    /// The handler type used to process this command
    associatedtype HandlerType: IMAPCommandHandler where HandlerType.ResultType == ResultType

    /// Default timeout for this command type
    var timeoutSeconds: Int { get }

    /// Check if the command is valid before execution
    func validate() throws

    /// Send the command to the server.
    func send(on channel: Channel, tag: String) async throws
}

/// A command that can be represented as a tagged IMAP command.
protocol IMAPTaggedCommand: IMAPCommand {
    /// Convert this high-level command to a NIO TaggedCommand.
    func toTaggedCommand(tag: String) -> TaggedCommand
}

// Provide reasonable defaults.
extension IMAPCommand {
    var timeoutSeconds: Int { return 5 }

    func validate() throws {
        // Default implementation does no validation
    }
}

extension IMAPTaggedCommand {
    func send(on channel: Channel, tag: String) async throws {
        let taggedCommand = toTaggedCommand(tag: tag)
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(taggedCommand))
        try await channel.writeAndFlush(wrapped).get()
    }
}
