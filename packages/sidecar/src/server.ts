/**
 * The sidecar API server.
 *
 * zero-cache does not trust clients to send raw ZQL. Instead, a client sends a
 * query *name* plus arguments, and zero-cache calls back here to ask what that
 * name actually means. Two endpoints implement that contract:
 *
 *   POST /api/query   — resolve a query name to authoritative ZQL
 *   POST /api/mutate  — execute a named mutator inside a Postgres transaction
 *
 * This indirection is the basis of Zero's permission model: because the server
 * decides what a query name expands to, it can add filters the client cannot
 * remove. Right now every query is public (`userID: null`) because the app is
 * single-user and local. When accounts arrive, this is where auth is enforced.
 */

import {serve} from '@hono/node-server'
import {mustGetMutator, mustGetQuery} from '@rocicorp/zero'
import {handleMutateRequest, handleQueryRequest} from '@rocicorp/zero/server'
import {Hono} from 'hono'
import {mutators} from '@mailapp/shared/mutators'
import {queries} from '@mailapp/shared/queries'
import {schema} from '@mailapp/shared/schema'
import {dbProvider, pool} from './db-provider.ts'

const PORT = Number(process.env.SIDECAR_PORT ?? 3000)

const app = new Hono()

/** Liveness probe, used by scripts/dev.sh to sequence startup. */
app.get('/health', c => c.json({ok: true}))

/**
 * Query resolution.
 *
 * `mustGetQuery` throws on an unknown name rather than returning undefined,
 * so a client cannot probe for queries that do not exist.
 */
app.post('/api/query', async c => {
  const result = await handleQueryRequest({
    handler: (name, args) => {
      const query = mustGetQuery(queries, name)
      return query.fn({args})
    },
    schema,
    request: c.req.raw,
    userID: null,
  })
  return c.json(result)
})

/**
 * Mutation execution.
 *
 * `transact` opens a Postgres transaction and hands us a `tx` bound to it.
 * Everything a mutator does — the label change AND its outbox row — commits or
 * rolls back together. That atomicity is what the outbox pattern depends on.
 */
app.post('/api/mutate', async c => {
  const result = await handleMutateRequest({
    dbProvider,
    handler: transact =>
      transact((tx, name, args) => {
        const mutator = mustGetMutator(mutators, name)
        return mutator.fn({args, tx})
      }),
    request: c.req.raw,
    userID: null,
  })
  return c.json(result)
})

const server = serve({fetch: app.fetch, port: PORT}, info => {
  console.log(`sidecar listening on http://localhost:${info.port}`)
})

// Drain the Postgres pool on shutdown so `npm run dev` restarts cleanly instead
// of leaking connections until Postgres refuses new ones.
const shutdown = async () => {
  server.close()
  await pool.end()
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
