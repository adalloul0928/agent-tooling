import {
  Action,
  ActionPanel,
  Icon,
  List,
  openExtensionPreferences,
} from "@raycast/api";
import { useEffect, useMemo, useState } from "react";
import {
  openAgentToolingRoute,
  searchAgentTooling,
  userMessageForError,
} from "./lib/agent-tooling";
import { ComponentKind, SearchResult } from "./lib/contracts";

type KindFilter = "all" | ComponentKind;

interface SearchState {
  isLoading: boolean;
  results: SearchResult[];
  totalResults: number;
  truncated: boolean;
  error?: string;
}

export default function SearchAgentToolingCommand() {
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<KindFilter>("all");
  const [reloadToken, setReloadToken] = useState(0);
  const [state, setState] = useState<SearchState>({
    isLoading: true,
    results: [],
    totalResults: 0,
    truncated: false,
  });

  useEffect(() => {
    const controller = new AbortController();
    const timer = setTimeout(() => {
      setState((current) => ({
        ...current,
        isLoading: true,
        error: undefined,
      }));
      void searchAgentTooling(query.trim(), controller.signal)
        .then((response) =>
          setState({
            isLoading: false,
            results: response.results,
            totalResults: response.totalResults,
            truncated: response.truncated,
          }),
        )
        .catch((error: unknown) => {
          if (controller.signal.aborted) return;
          setState({
            isLoading: false,
            results: [],
            totalResults: 0,
            truncated: false,
            error: userMessageForError(error),
          });
        });
    }, 220);

    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [query, reloadToken]);

  const visibleResults = useMemo(
    () =>
      kind === "all"
        ? state.results
        : state.results.filter((result) => result.kind === kind),
    [kind, state.results],
  );

  return (
    <List
      isLoading={state.isLoading}
      onSearchTextChange={setQuery}
      searchBarPlaceholder="Search skills, MCP servers, and plugins"
      throttle
      searchBarAccessory={
        <List.Dropdown
          tooltip="Component Type"
          value={kind}
          onChange={(value) => setKind(value as KindFilter)}
        >
          <List.Dropdown.Item title="All Components" value="all" />
          <List.Dropdown.Item title="Skills" value="skill" />
          <List.Dropdown.Item title="MCP Servers" value="mcp-server" />
          <List.Dropdown.Item title="Plugins" value="plugin" />
        </List.Dropdown>
      }
    >
      {state.error ? (
        <List.EmptyView
          icon={Icon.ExclamationMark}
          title="Agent Tooling Is Unavailable"
          description={state.error}
          actions={
            <ActionPanel>
              <Action
                title="Try Again"
                icon={Icon.ArrowClockwise}
                onAction={() => setReloadToken((value) => value + 1)}
              />
              <Action
                title="Open Extension Settings"
                icon={Icon.Gear}
                onAction={openExtensionPreferences}
              />
            </ActionPanel>
          }
        />
      ) : visibleResults.length === 0 && !state.isLoading ? (
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title={query ? "No Matching Components" : "No Components Found"}
          description={
            query
              ? "Try a different name or component type."
              : "Open Agent Tooling to add a source or package."
          }
        />
      ) : (
        <List.Section
          title={
            state.truncated
              ? `Showing ${visibleResults.length} of ${state.totalResults} — type to narrow`
              : undefined
          }
        >
          {visibleResults.map((result) => (
            <ResultItem key={`${result.kind}:${result.id}`} result={result} />
          ))}
        </List.Section>
      )}
    </List>
  );
}

function ResultItem({ result }: { result: SearchResult }) {
  const accessories: List.Item.Accessory[] = [];
  if (result.scope) accessories.push({ text: result.scope, tooltip: "Scope" });
  if (result.status)
    accessories.push({ text: result.status, tooltip: "Status" });

  return (
    <List.Item
      icon={iconForKind(result.kind)}
      title={result.name}
      subtitle={result.description}
      keywords={[result.id, result.source ?? "", ...result.targets]}
      accessories={accessories}
      actions={
        <ActionPanel>
          <Action
            title="Open in Agent Tooling"
            icon={Icon.AppWindow}
            onAction={() =>
              openAgentToolingRoute({
                kind: "component",
                componentKind: result.kind,
                id: result.id,
              })
            }
          />
          <Action.CopyToClipboard title="Copy Name" content={result.name} />
          <Action.CopyToClipboard title="Copy Identifier" content={result.id} />
        </ActionPanel>
      }
    />
  );
}

function iconForKind(kind: ComponentKind): Icon {
  switch (kind) {
    case "skill":
      return Icon.BlankDocument;
    case "mcp-server":
      return Icon.Globe;
    case "plugin":
      return Icon.Box;
  }
}
