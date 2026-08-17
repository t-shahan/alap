import Foundation
import Observation

/// The message being written, and how the composer is presented.
///
/// A separate observable from `MailStore` so that typing a subject does not
/// invalidate views that read the thread list. Every keystroke here would
/// otherwise re-evaluate every row's body.
@MainActor
@Observable
final class Composer {
  /// How much of the composer is on screen.
  enum Presentation: Equatable {
    /// Not composing. The launch button is visible instead.
    case closed
    /// Full panel, bottom-right.
    case open
    /// Collapsed to its title bar, still holding the draft.
    ///
    /// The point of minimising rather than closing is that the draft survives
    /// while the mailbox stays usable — looking something up mid-message is
    /// the normal case, not an edge case.
    case minimized
  }

  enum Status: Equatable {
    case editing
    case sending
    /// Written to the outbox. NOT "sent" — the engine has not delivered it yet.
    case queued
    case failed(String)
  }

  /// What a reply needs to carry that a new message does not.
  struct ReplyContext: Equatable {
    let accountId: String
    let remoteThreadId: String
    let inReplyTo: String
    let references: [String]
  }

  private(set) var presentation: Presentation = .closed
  var status: Status = .editing

  var to = ""
  var cc = ""
  var subject = ""
  var body = ""
  var showsCc = false

  /// Non-nil when replying. Also pins the sending account.
  private(set) var replyContext: ReplyContext?

  /// The parent message, quoted. Appended at send time rather than typed into.
  private(set) var quotedBody = ""

  /// Whether the quote is shown in the composer.
  ///
  /// Collapsed by default behind a control, as every mail client does — the
  /// quote is context, not something being written, and showing it by default
  /// would mean scrolling past it to reach the message.
  var showsQuote = false

  /// The body as it will actually be sent.
  var composedBody: String {
    let written = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !quotedBody.isEmpty else { return written }
    return written + "\n\n" + quotedBody
  }
  /// Account to send from. For a reply this is the thread's account.
  var accountId: String?

  var isOpen: Bool { presentation == .open }
  var isVisible: Bool { presentation != .closed }

  /// True when the draft holds anything worth warning about before discarding.
  var hasContent: Bool {
    [to, cc, subject, body].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  var canSend: Bool {
    status != .sending
      && !recipients(from: to).isEmpty
      && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var title: String {
    if replyContext != nil {
      return subject.isEmpty ? "Reply" : subject
    }
    return subject.isEmpty ? "New Message" : subject
  }

  // MARK: - Opening

  func newMessage(from accountId: String?) {
    reset()
    self.accountId = accountId
    presentation = .open
  }

  /// Opens pre-filled as a reply.
  ///
  /// Recipients and threading are resolved by the caller, which has the thread
  /// loaded; recomputing them here would mean handing the composer the whole
  /// store.
  /// - Parameter quoting: The parent, already formatted for quoting.
  ///   Placed BELOW two blank lines with the cursor above it, which is where
  ///   people write — top-posting is what mail clients on this platform do, and
  ///   fighting it would only make the composer feel wrong.
  func reply(to recipients: [String], subject: String, quoting quoted: String,
             context: ReplyContext) {
    reset()
    self.to = recipients.joined(separator: ", ")
    self.subject = subject
    self.replyContext = context
    self.accountId = context.accountId
    self.quotedBody = quoted
    // The body starts EMPTY rather than pre-filled with the quote. The quote is
    // appended at send time, so it cannot be half-deleted by editing, and the
    // composer shows what was actually written rather than a wall of `>`.
    self.body = ""
    presentation = .open
  }

  func minimize() { presentation = .minimized }
  func expand() { presentation = .open }

  /// Closes and discards. Callers confirm first when `hasContent`.
  func close() {
    reset()
    presentation = .closed
  }

  private func reset() {
    to = ""; cc = ""; subject = ""; body = ""
    quotedBody = ""
    showsCc = false
    showsQuote = false
    replyContext = nil
    accountId = nil
    status = .editing
  }

  // MARK: - Address parsing

  /// Splits a recipient field into addresses.
  ///
  /// Accepts commas and semicolons, and pulls the address out of a
  /// `Name <addr@host>` form — which is what pasting from another mail client
  /// gives you, and what would otherwise be rejected as malformed.
  func recipients(from field: String) -> [String] {
    field
      .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
      .map { part -> String in
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"),
              let close = trimmed.lastIndex(of: ">"), open < close
        else { return trimmed }
        return String(trimmed[trimmed.index(after: open)..<close])
          .trimmingCharacters(in: .whitespaces)
      }
      .filter { Composer.looksLikeAddress($0) }
  }

  /// A deliberately loose check.
  ///
  /// Strict RFC 5322 validation rejects addresses that are perfectly
  /// deliverable, and the real verdict comes from Gmail anyway. This exists to
  /// catch a half-typed address before it becomes a failed send, not to be
  /// authoritative.
  static func looksLikeAddress(_ value: String) -> Bool {
    guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
    let domain = value[value.index(after: at)...]
    return !domain.isEmpty && domain.contains(".") && !value.contains(" ")
      && value.firstIndex(of: "@") == value.lastIndex(of: "@")
  }
}
