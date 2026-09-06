// A real Apollo gateway over a STATIC supergraph SDL — the same routing
// table the local Ruby router reads, so any difference between the two is
// planning, not composition.
// Env: SUPERGRAPH (path to the SDL). Prints {"url": ...} once ready.
import { readFileSync } from "node:fs";
import { ApolloGateway } from "@apollo/gateway";
import { ApolloServer } from "@apollo/server";
import { startStandaloneServer } from "@apollo/server/standalone";

const gateway = new ApolloGateway({ supergraphSdl: readFileSync(process.env.SUPERGRAPH, "utf8") });
const server = new ApolloServer({ gateway });
const { url } = await startStandaloneServer(server, { listen: { port: 0 } });
console.log(JSON.stringify({ url }));
