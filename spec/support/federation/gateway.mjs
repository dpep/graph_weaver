// A real Apollo gateway/router over the Ruby subgraphs — composes the
// supergraph by introspecting them, then serves the routed API.
// Env: USERS_URL, PETS_URL. Prints {"url": ...} once ready.
import { ApolloGateway, IntrospectAndCompose } from "@apollo/gateway";
import { ApolloServer } from "@apollo/server";
import { startStandaloneServer } from "@apollo/server/standalone";

const gateway = new ApolloGateway({
  supergraphSdl: new IntrospectAndCompose({
    subgraphs: [
      { name: "users", url: process.env.USERS_URL },
      { name: "pets", url: process.env.PETS_URL },
    ],
  }),
});

const server = new ApolloServer({ gateway });
const { url } = await startStandaloneServer(server, { listen: { port: 0 } });
console.log(JSON.stringify({ url }));
