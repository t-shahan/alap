/**
 * The Swift ↔ JavaScript bridge protocol.
 *
 * This file is the contract. It is imported by the JS bridge, and its shapes
 * are mirrored by `Codable` structs on the Swift side. Changing anything here
 * means changing `ZeroBridge.swift` in lockstep.
 *
 * Everything crosses as a JSON string, because that is the only payload type
 * WKWebView's two transports agree on:
 *
 *   Swift → JS   `callAsyncJavaScript("window.__zeroBridge.receive(...)")`
 *   JS → Swift   `window.webkit.messageHandlers.zeroBridge.postMessage(...)`
 *
 * Every command carries an `id` that the corresponding event echoes back, so
 * Swift can correlate replies without relying on ordering.
 */

/** Commands sent from Swift into the web view. */
export type Command =
  | {
      readonly type: 'subscribe'
      /** Caller-assigned correlation id; also the subscription handle. */
      readonly id: string
      /** Dotted path into the query registry, e.g. `threads.unifiedInbox`. */
      readonly query: string
      readonly args?: unknown
    }
  | {
      readonly type: 'unsubscribe'
      readonly id: string
    }
  | {
      readonly type: 'mutate'
      readonly id: string
      /** Dotted path into the mutator registry, e.g. `threads.archive`. */
      readonly mutator: string
      readonly args?: unknown
    }

/** Events pushed from the web view up to Swift. */
export type Event =
  | {
      readonly type: 'ready'
    }
  | {
      /** A subscription produced new rows. Fires on every change. */
      readonly type: 'update'
      readonly id: string
      readonly rows: unknown
      /**
       * `unknown` means these are local-only results and the server has not
       * confirmed completeness yet; `complete` means the server has answered.
       * Swift uses this to decide whether an empty result means "no data" or
       * "not loaded yet" — the difference between an empty inbox and a
       * flash of "nothing here".
       */
      readonly resultType: 'unknown' | 'complete'
    }
  | {
      readonly type: 'mutateResult'
      readonly id: string
      readonly ok: boolean
      readonly error?: string
    }
  | {
      readonly type: 'connection'
      readonly state: string
      readonly reason?: string
    }
  | {
      readonly type: 'error'
      readonly id?: string
      readonly message: string
    }

/** Name of the WKScriptMessageHandler Swift registers. */
export const HANDLER_NAME = 'zeroBridge'

/** Global the Swift side calls into. */
export const GLOBAL_NAME = '__zeroBridge'
