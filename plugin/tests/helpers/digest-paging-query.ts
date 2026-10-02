/**
 * Helper: print the digest paging SQL for a given agent name.
 *
 * Used by BATS PG-layer tests so they exercise the exact query string the
 * digest embeds, not a hand-maintained copy.
 */

import { buildPagingQuery } from "../../src/digest.js";

const agentName = process.argv[2];
if (!agentName) {
  console.error("Usage: tsx digest-paging-query.ts <agentName>");
  process.exit(1);
}
console.log(buildPagingQuery(agentName));
