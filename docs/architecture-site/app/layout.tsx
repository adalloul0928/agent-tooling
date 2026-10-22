import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Agent Tooling — Skills, plugins, and MCP for macOS",
  description:
    "A native macOS app for managing skills, plugins, and MCP connections across Codex, Claude Code, Gemini CLI, and Kiro CLI.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
