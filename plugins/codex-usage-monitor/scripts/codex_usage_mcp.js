#!/usr/bin/env node
"use strict";

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const SERVER_NAME = "codex-usage-monitor";
const SERVER_VERSION = "0.3.0";

function helperCandidates() {
  return [
    process.env.CODEX_RATE_LIMITS_HELPER,
    path.resolve(__dirname, "../../../scripts/codex_rate_limits.js"),
    path.join(os.homedir(), "Applications", "Codex Rate Limits Bar.app", "Contents", "Resources", "Scripts", "codex_rate_limits.js"),
    "/Applications/Codex Rate Limits Bar.app/Contents/Resources/Scripts/codex_rate_limits.js",
  ].filter(Boolean);
}

function helperPath() {
  return helperCandidates().find((candidate) => fs.existsSync(candidate)) ?? null;
}

function respond(id, result) {
  if (id === undefined || id === null) return;
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function respondError(id, code, message, data) {
  if (id === undefined || id === null) return;
  const error = { code, message };
  if (data !== undefined) error.data = data;
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error })}\n`);
}

function toolText(payload) {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(payload, null, 2),
      },
    ],
  };
}

function runNodeHelper(command) {
  const helper = helperPath();
  if (!helper) {
    throw new Error("codex_rate_limits.js not found. Install Codex Rate Limits Bar or set CODEX_RATE_LIMITS_HELPER.");
  }
  return new Promise((resolve, reject) => {
    const child = spawn("node", [helper, command], {
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PATH: [
          "/opt/homebrew/bin",
          "/usr/local/bin",
          "/usr/bin",
          "/bin",
          process.env.PATH || "",
        ].join(":"),
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`helper failed with code ${code}: ${stderr.slice(-2000)}`));
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch (error) {
        reject(error);
      }
    });
  });
}

const tools = [
  {
    name: "get_codex_status",
    description: "Read the combined Codex rate-limit snapshot and machine-local token usage from Codex Rate Limits Bar.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "get_codex_rate_limits",
    description: "Read the current Codex 5-hour and weekly rate-limit snapshot.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "get_codex_local_usage",
    description: "Read today's machine-local Codex token usage from ~/.codex/sessions JSONL files.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "get_codex_account_usage",
    description: "Read Codex account token usage summary and daily usage buckets from the local Codex app-server.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "get_codex_reset_credits",
    description: "Read available Codex rate-limit reset credits and their expiration times from the local Codex auth session.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
];

async function handleRequest(message) {
  const { id, method, params } = message;
  if (method === "initialize") {
    respond(id, {
      protocolVersion: params?.protocolVersion ?? "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
    return;
  }
  if (method === "tools/list") {
    respond(id, { tools });
    return;
  }
  if (method === "tools/call") {
    try {
      if (params?.name === "get_codex_status") {
        respond(id, toolText(await runNodeHelper("status")));
        return;
      }
      if (params?.name === "get_codex_rate_limits") {
        respond(id, toolText(await runNodeHelper("rate-limits")));
        return;
      }
      if (params?.name === "get_codex_local_usage") {
        respond(id, toolText(await runNodeHelper("local-usage")));
        return;
      }
      if (params?.name === "get_codex_account_usage") {
        respond(id, toolText(await runNodeHelper("usage")));
        return;
      }
      if (params?.name === "get_codex_reset_credits") {
        respond(id, toolText(await runNodeHelper("reset-credits")));
        return;
      }
      respondError(id, -32602, `Unknown tool: ${params?.name ?? ""}`);
    } catch (error) {
      respondError(id, -32000, error?.message ?? String(error));
    }
    return;
  }
  if (method === "ping") {
    respond(id, {});
    return;
  }
  respondError(id, -32601, `Method not found: ${method}`);
}

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (!Object.prototype.hasOwnProperty.call(message, "id")) return;
  handleRequest(message);
});
