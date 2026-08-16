/**
 * The Zero client host.
 *
 * This bundle runs inside a headless WKWebView owned by the Mac app. WebKit
 * supplies IndexedDB, WebSocket and fetch, so the Zero client runs completely
 * unmodified — no polyfills, and no extra binary in the app bundle, because
 * WebKit is a system framework.
 *
 * The web view is never displayed. It exists solely to host the Zero client
 * and relay reactive query results up to SwiftUI.
 *
 * If the JSON relay ever becomes a measurable bottleneck, the escape hatch is
 * JavaScriptCore with a custom `kvStore` backed by the C++ SQLite layer — the
 * same seam React Native uses. That swap would not change this protocol.
 */

import {Zero} from '@rocicorp/zero'
import {mutators} from '@mailapp/shared/mutators'
import {queries} from '@mailapp/shared/queries'
import {schema} from '@mailapp/shared/schema'
import {GLOBAL_NAME, HANDLER_NAME, type Command, type Event} from './protocol.ts'

/** A materialized Zero view. Structural, to avoid depending on internal types. */
type View = {
  readonly data: unknown
  addListener: (fn: (data: unknown, resultType?: {type: string}) => void) => () => void
  destroy: () => void
}

declare global {
  interface Window {
    [GLOBAL_NAME]: {receive: (json: string) => void}
    webkit?: {
      messageHandlers?: Record<string, {postMessage: (body: unknown) => void}>
    }
    /** Set by the dev harness so the bridge can be driven in a browser. */
    __zeroBridgeOnEvent?: (event: Event) => void
  }
}

const CACHE_URL = 'http://localhost:4848'

/** Live subscriptions, keyed by the id Swift assigned. */
const views = new Map<string, {view: View; unlisten: () => void}>()

/** Active preloads, keyed by id, so they can be replaced or cancelled. */
const preloads = new Map<string, {cleanup: () => void}>()

/**
 * Sends an event up to Swift.
 *
 * Falls back to `__zeroBridgeOnEvent` when no WebKit handler is present, which
 * is what lets `dev.html` exercise this exact code path in a normal browser.
 */
function emit(event: Event): void {
  const handler = window.webkit?.messageHandlers?.[HANDLER_NAME]
  if (handler) {
    handler.postMessage(JSON.stringify(event))
    return
  }
  window.__zeroBridgeOnEvent?.(event)
}

/**
 * Walks a dotted path into a registry object.
 *
 * Registries are nested (`queries.threads.unifiedInbox`), and Swift addresses
 * them by string. Resolving here rather than exposing arbitrary evaluation
 * keeps the surface Swift can reach limited to what is actually registered.
 */
function resolve(registry: unknown, path: string): unknown {
  let node: unknown = registry
  for (const segment of path.split('.')) {
    if (typeof node !== 'object' || node === null || !(segment in node)) {
      throw new Error(`unknown path: ${path}`)
    }
    node = (node as Record<string, unknown>)[segment]
  }
  return node
}

const zero = new Zero({
  cacheURL: CACHE_URL,
  schema,
  mutators,
})

// Surface connection state so the UI can disable input while offline. In the
// local-sidecar topology this should essentially never leave `connected`,
// since the socket never leaves the loopback interface — if it does, something
// is genuinely wrong and the user should see it.
zero.connection.state.subscribe(state => {
  emit({type: 'connection', state: state.name, reason: (state as {reason?: string}).reason})
})

function subscribe(cmd: Extract<Command, {type: 'subscribe'}>): void {
  // Replacing an existing id is legal: SwiftUI re-renders re-subscribe with
  // the same handle when their arguments change.
  unsubscribe(cmd.id)

  const queryFactory = resolve(queries, cmd.query)
  if (typeof queryFactory !== 'function') {
    throw new Error(`not a query: ${cmd.query}`)
  }

  const view = zero.materialize(queryFactory(cmd.args ?? {})) as unknown as View

  const push = (data: unknown, result?: {type: string}) => {
    emit({
      type: 'update',
      id: cmd.id,
      rows: data,
      resultType: result?.type === 'complete' ? 'complete' : 'unknown',
    })
  }

  // `addListener` fires immediately with whatever is already cached, so the UI
  // paints from the local store without waiting for the server. Do NOT also
  // push `view.data` here — that emits every update twice, which in SwiftUI
  // means two view invalidations per change.
  const unlisten = view.addListener(push)
  views.set(cmd.id, {view, unlisten})
}

/**
 * Streams rows to the local store without building JS objects for them.
 *
 * The point is latency, not display: once these rows are local, a subsequent
 * query over the same data is answered from the client cache in a frame rather
 * than waiting on a server round trip.
 */
function preload(cmd: Extract<Command, {type: 'preload'}>): void {
  const queryFactory = resolve(queries, cmd.query)
  if (typeof queryFactory !== 'function') {
    throw new Error(`not a query: ${cmd.query}`)
  }
  // Replacing an existing preload cancels the previous one.
  preloads.get(cmd.id)?.cleanup()
  preloads.set(cmd.id, zero.preload(queryFactory(cmd.args ?? {})))
}

function unsubscribe(id: string): void {
  const existing = views.get(id)
  if (!existing) return
  existing.unlisten()
  existing.view.destroy()
  views.delete(id)
}

async function mutate(cmd: Extract<Command, {type: 'mutate'}>): Promise<void> {
  const mutatorFactory = resolve(mutators, cmd.mutator)
  if (typeof mutatorFactory !== 'function') {
    throw new Error(`not a mutator: ${cmd.mutator}`)
  }

  const write = zero.mutate(mutatorFactory(cmd.args ?? {})) as unknown as {
    client: Promise<{type: string; error?: unknown}>
    server: Promise<{type: string; error?: unknown}>
  }

  // Report as soon as the LOCAL write lands — that is what the UI is waiting
  // on, and it happens within a frame. Awaiting `.server` here would defeat
  // the entire point of optimistic mutation.
  const clientRes = await write.client
  if (clientRes.type === 'error') {
    emit({type: 'mutateResult', id: cmd.id, ok: false, error: String(clientRes.error)})
    return
  }
  emit({type: 'mutateResult', id: cmd.id, ok: true})

  // The server result still matters — it is how a rejected write surfaces —
  // but it is reported out-of-band rather than blocking the UI.
  void write.server.then(serverRes => {
    if (serverRes.type === 'error') {
      emit({
        type: 'error',
        id: cmd.id,
        message: `server rejected ${cmd.mutator}: ${String(serverRes.error)}`,
      })
    }
  })
}

/** Single entry point Swift calls. Never throws across the bridge boundary. */
function receive(json: string): void {
  let cmd: Command
  try {
    cmd = JSON.parse(json) as Command
  } catch (err) {
    emit({type: 'error', message: `malformed command: ${String(err)}`})
    return
  }

  try {
    switch (cmd.type) {
      case 'subscribe':
        subscribe(cmd)
        break
      case 'preload':
        preload(cmd)
        break
      case 'unsubscribe':
        unsubscribe(cmd.id)
        preloads.get(cmd.id)?.cleanup()
        preloads.delete(cmd.id)
        break
      case 'mutate':
        void mutate(cmd).catch(err => {
          emit({type: 'mutateResult', id: cmd.id, ok: false, error: String(err)})
        })
        break
      default:
        emit({type: 'error', message: `unknown command type`})
    }
  } catch (err) {
    emit({
      type: 'error',
      id: 'id' in cmd ? cmd.id : undefined,
      message: String(err instanceof Error ? err.message : err),
    })
  }
}

window[GLOBAL_NAME] = {receive}
emit({type: 'ready'})
