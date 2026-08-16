/**
 * Postgres connection for the mutate endpoint.
 *
 * This is the *only* component that writes to Postgres on behalf of the client.
 * zero-cache never writes — it holds a read-only replica fed by logical
 * replication. Client mutations arrive here, run inside a real Postgres
 * transaction, and then flow back out to every client via replication.
 */

import {zeroNodePg} from '@rocicorp/zero/server/adapters/pg'
import pg from 'pg'
import {schema} from '@mailapp/shared/schema'

const connectionString = process.env.ZERO_UPSTREAM_DB
if (!connectionString) {
  throw new Error('ZERO_UPSTREAM_DB is not set — did you source .env?')
}

/**
 * In the local-sidecar topology this pool only ever serves one user on one
 * machine, so it stays small. A cloud deployment would size this against
 * `ZERO_UPSTREAM_MAX_CONNS` and put a pooler in front.
 */
export const pool = new pg.Pool({
  connectionString,
  max: 10,
})

export const dbProvider = zeroNodePg(schema, pool)

// Registering the provider globally lets mutators infer their `tx` type
// without an explicit type parameter at every definition.
declare module '@rocicorp/zero' {
  interface DefaultTypes {
    dbProvider: typeof dbProvider
  }
}
