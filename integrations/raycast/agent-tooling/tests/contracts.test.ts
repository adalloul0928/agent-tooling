import { describe, expect, it } from "vitest";
import {
  AGENT_TOOLING_SCHEMA_VERSION,
  ContractError,
  decodeDoctorResponse,
  decodeRequestResponse,
  decodeSearchResponse,
  parseBoundedJSON,
} from "../src/lib/contracts";
import { routeURL } from "../src/lib/routes";

describe("Agent Tooling JSON contracts", () => {
  it("builds typed navigation routes without embedding insight data", () => {
    expect(routeURL({ kind: "overview" })).toBe("agent-tooling://overview");
    expect(routeURL({ kind: "insights" })).toBe("agent-tooling://insights");
    expect(routeURL({ kind: "sync" })).toBe("agent-tooling://sync");
    expect(
      routeURL({
        kind: "component",
        componentKind: "skill",
        id: "skill-forge",
      }),
    ).toBe("agent-tooling://skills/skill-forge");
  });

  it("decodes a versioned search response", () => {
    const response = decodeSearchResponse(
      JSON.stringify({
        schemaVersion: AGENT_TOOLING_SCHEMA_VERSION,
        results: [
          {
            id: "skill-forge",
            kind: "skill",
            name: "Skill Forge",
            description: "Creates portable skills",
            targets: ["codex", "claude-code"],
          },
          {
            id: "sentry",
            kind: "mcp-server",
            name: "Sentry",
            targets: ["codex"],
          },
        ],
        totalResults: 2,
        truncated: false,
      }),
    );

    expect(response.results).toHaveLength(2);
    expect(response.results[0]).toMatchObject({
      id: "skill-forge",
      kind: "skill",
    });
    expect(response.results[1]?.targets).toEqual(["codex"]);
    expect(response).toMatchObject({ totalResults: 2, truncated: false });
  });

  it("rejects incompatible schemas and component kinds", () => {
    expect(() =>
      decodeSearchResponse(
        JSON.stringify({
          schemaVersion: 2,
          results: [],
          totalResults: 0,
          truncated: false,
        }),
      ),
    ).toThrow(ContractError);
    expect(() =>
      decodeSearchResponse(
        JSON.stringify({
          schemaVersion: 1,
          results: [{ id: "bad", kind: "agent", name: "Bad", targets: [] }],
          totalResults: 1,
          truncated: false,
        }),
      ),
    ).toThrow("unsupported component kind");
  });

  it("validates bounded and internally consistent search result counts", () => {
    expect(() =>
      decodeSearchResponse(
        JSON.stringify({
          schemaVersion: 1,
          results: [],
          totalResults: 1,
          truncated: false,
        }),
      ),
    ).toThrow("inconsistent result counts");

    const response = decodeSearchResponse(
      JSON.stringify({
        schemaVersion: 1,
        results: [],
        totalResults: 12,
        truncated: true,
      }),
    );
    expect(response).toMatchObject({ totalResults: 12, truncated: true });
  });

  it("accepts current and versioned doctor responses", () => {
    expect(
      decodeDoctorResponse(
        JSON.stringify({
          isHealthy: false,
          unavailableTargets: ["gemini-cli"],
          observations: [{}],
        }),
      ),
    ).toMatchObject({ isHealthy: false, unavailableTargets: ["gemini-cli"] });

    expect(
      decodeDoctorResponse(
        JSON.stringify({
          schemaVersion: 1,
          isHealthy: true,
          unavailableTargets: [],
          observations: [],
        }),
      ).schemaVersion,
    ).toBe(1);
  });

  it("requires an opaque UUID for request deep links", () => {
    const response = decodeRequestResponse(
      JSON.stringify({
        schemaVersion: 1,
        request: {
          id: "a82c55d2-5454-4bde-8b91-32b934667871",
          state: "pending-review",
        },
      }),
    );
    expect(response.request.id).toBe("a82c55d2-5454-4bde-8b91-32b934667871");
    expect(() =>
      decodeRequestResponse(
        JSON.stringify({ schemaVersion: 1, request: { id: "../../unsafe" } }),
      ),
    ).toThrow("valid UUID");
  });

  it("rejects malformed and oversized JSON", () => {
    expect(() => parseBoundedJSON("not-json")).toThrow("malformed JSON");
    expect(() =>
      parseBoundedJSON(JSON.stringify({ value: "long" }), 5),
    ).toThrow("more data");
  });
});
