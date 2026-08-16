import Foundation
@testable import Alap

/// JSON in the exact shape Zero delivers, so these tests exercise the real
/// decoders rather than hand-built structs.
///
/// Building rows directly would skip `Rows.swift` entirely, and decoding is
/// where schema drift actually bites: a column renamed in Postgres surfaces as
/// a silent nil, not a compile error.
enum Fixtures {
  static func thread(
    id: String,
    accountId: String = "acct_1",
    remoteThreadId: String = "t1",
    subject: String = "Subject",
    lastMessageAt: Double = 1_700_000_000_000,
    unreadCount: Int = 0,
    isStarred: Bool = false
  ) -> String {
    """
    {"id":"\(id)","accountId":"\(accountId)","remoteThreadId":"\(remoteThreadId)",
     "subject":"\(subject)","snippet":"snippet",
     "participants":[{"name":"Ada","email":"ada@example.com"}],
     "lastMessageAt":\(lastMessageAt),"messageCount":1,"unreadCount":\(unreadCount),
     "hasAttachments":false,"isStarred":\(isStarred)}
    """
  }

  static func threadList(_ ids: [String]) -> String {
    "[" + ids.map { thread(id: $0) }.joined(separator: ",") + "]"
  }

  static func attachment(
    id: String,
    filename: String = "invoice.pdf",
    mimeType: String = "application/pdf",
    sizeBytes: Int = 1024,
    isInline: Bool = false,
    remoteAttachmentId: String? = "remote-att-1",
    localPath: String? = nil,
    contentHash: String? = nil
  ) -> String {
    func optional(_ value: String?) -> String {
      value.map { "\"\($0)\"" } ?? "null"
    }
    return """
      {"id":"\(id)","filename":"\(filename)","mimeType":"\(mimeType)",
       "sizeBytes":\(sizeBytes),"isInline":\(isInline),
       "remoteAttachmentId":\(optional(remoteAttachmentId)),
       "localPath":\(optional(localPath)),"contentHash":\(optional(contentHash))}
      """
  }

  static func message(
    id: String,
    threadId: String = "th1",
    fromName: String = "Ada Okonkwo",
    fromEmail: String = "ada@example.com",
    to: [(String, String)] = [("Me", "me@example.com")],
    subject: String = "Subject",
    rfc822MessageId: String? = "parent@example.com",
    attachments: [String] = []
  ) -> String {
    let recipients = to
      .map { "{\"name\":\"\($0.0)\",\"email\":\"\($0.1)\"}" }
      .joined(separator: ",")
    let messageId = rfc822MessageId.map { "\"\($0)\"" } ?? "null"
    return """
      {"id":"\(id)","threadId":"\(threadId)","fromName":"\(fromName)",
       "fromEmail":"\(fromEmail)","toRecipients":[\(recipients)],"ccRecipients":[],
       "subject":"\(subject)","snippet":"snippet","sentAt":1700000000000,
       "isRead":true,"isStarred":false,"hasAttachments":\(!attachments.isEmpty),
       "rfc822MessageId":\(messageId),"body":null,
       "attachments":[\(attachments.joined(separator: ","))]}
      """
  }

  static func detail(id: String = "th1", subject: String = "Subject",
                     messages: [String]) -> String {
    """
    {"id":"\(id)","subject":"\(subject)","messages":[\(messages.joined(separator: ","))]}
    """
  }

  static func account(
    id: String = "acct_1",
    email: String = "me@example.com",
    displayName: String = "Me"
  ) -> String {
    """
    [{"id":"\(id)","emailAddress":"\(email)","displayName":"\(displayName)",
      "provider":"gmail","color":"#0a84ff","sortOrder":0,"createdAt":0}]
    """
  }

  /// The account's labels. INBOX matters most: archiving is the removal of
  /// that label, so without it `archive` cannot build its mutation at all.
  static func labels(accountId: String = "acct_1") -> String {
    """
    [{"id":"\(accountId)|INBOX","accountId":"\(accountId)","remoteId":"INBOX",
      "name":"Inbox","kind":"system","sortOrder":0,"unreadCount":3,"totalCount":10},
     {"id":"\(accountId)|TRASH","accountId":"\(accountId)","remoteId":"TRASH",
      "name":"Trash","kind":"system","sortOrder":1,"unreadCount":0,"totalCount":2}]
    """
  }

  static func outbox(id: String, op: String = "download_attachment",
                     status: String = "pending", lastError: String? = nil) -> String {
    let error = lastError.map { "\"\($0)\"" } ?? "null"
    return """
      {"id":"\(id)","op":"\(op)","status":"\(status)","lastError":\(error)}
      """
  }

  /// Writes a real file, so tests that depend on disk state test disk state.
  ///
  /// The attachment cache lives in `~/Library/Caches` and can be reclaimed by
  /// macOS at any time, so "the row says downloaded" and "the file is there"
  /// are genuinely different conditions and both must be reachable.
  static func temporaryFile(contents: String = "pdf bytes") -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mailtests-\(UUID().uuidString).pdf")
    try? Data(contents.utf8).write(to: url)
    return url
  }
}
