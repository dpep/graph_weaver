// Apollo's own composition, as the oracle for weaver's API-schema
// derivation. Reads [{name, sdl}, ...] on stdin, composes the supergraph
// with @apollo/composition, and prints {supergraph, apiSchema} — the raw
// supergraph SDL to feed weaver, and Apollo's own toAPISchema() to diff
// weaver's derivation against.
import { readFileSync } from "node:fs";
import { composeServices } from "@apollo/composition";
import { Supergraph, printSchema } from "@apollo/federation-internals";

const subgraphs = JSON.parse(readFileSync(0, "utf8")).map(({ name, sdl }) => ({
  name,
  typeDefs: sdl,
  url: `http://localhost/${name}`,
}));

const result = composeServices(subgraphs);
if (result.errors?.length) {
  console.error(result.errors.map((e) => e.message).join("\n"));
  process.exit(1);
}

const supergraph = result.supergraphSdl;
const apiSchema = printSchema(Supergraph.build(supergraph).apiSchema());
console.log(JSON.stringify({ supergraph, apiSchema }));
