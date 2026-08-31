import type { SearchResult } from "./contracts";

export type AgentToolingRoute =
  | { kind: "overview" }
  | { kind: "insights" }
  | { kind: "sync" }
  | { kind: "request"; id: string }
  | { kind: "component"; componentKind: SearchResult["kind"]; id: string };

export function routeURL(route: AgentToolingRoute): string {
  switch (route.kind) {
    case "overview":
      return "agent-tooling://overview";
    case "insights":
      return "agent-tooling://insights";
    case "sync":
      return "agent-tooling://sync";
    case "request":
      return `agent-tooling://requests/${encodeURIComponent(route.id)}`;
    case "component": {
      if (route.componentKind === "skill") {
        return `agent-tooling://skills/${encodeURIComponent(route.id)}`;
      }
      return route.componentKind === "mcp-server"
        ? "agent-tooling://mcp-servers"
        : "agent-tooling://plugins";
    }
  }
}
