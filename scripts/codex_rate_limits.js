#!/usr/bin/env node
"use strict";

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");

const CLIENT_NAME = "codex-rate-limits-bar";
const CLIENT_TITLE = "Codex Rate Limits Bar";
const CLIENT_VERSION = "0.1.0";
const RESET_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
const BEIJING_TIME_ZONE = "Asia/Shanghai";

function executableFrom(candidates) {
  for (const candidate of candidates) {
    if (!candidate) continue;
    if (!candidate.includes("/")) return candidate;
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      // Try the next candidate.
    }
  }
  return candidates[candidates.length - 1];
}

function codexCommand() {
  return executableFrom([
    process.env.CODEX_BIN,
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    "codex",
  ]);
}

function epochToIso(seconds) {
  if (typeof seconds !== "number") return null;
  return new Date(seconds * 1000).toISOString();
}

function isoString(value) {
  if (!value) return null;
  if (typeof value === "number") {
    const millis = value > 10_000_000_000 ? value : value * 1000;
    return new Date(millis).toISOString();
  }
  const date = new Date(String(value).replace("Z", "+00:00"));
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString();
}

function beijingDateParts(iso) {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const formatter = new Intl.DateTimeFormat("zh-CN", {
    timeZone: BEIJING_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
  return Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
}

function formatBeijingDateTime(iso) {
  const parts = beijingDateParts(iso);
  if (!parts) return "未设置";
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second} 北京时间`;
}

function formatShortBeijingDateTime(iso) {
  const parts = beijingDateParts(iso);
  if (!parts) return "未设置";
  return `${Number(parts.month)}月${Number(parts.day)}日 ${parts.hour}:${parts.minute}`;
}

function resetCreditTypeLabel(value) {
  const labels = {
    codex_rate_limits: "Codex 速率限制重置",
  };
  return labels[value] || value || "未知分类";
}

function resetCreditStatusLabel(value) {
  const labels = {
    available: "可用",
    redeemed: "已兑换",
    expired: "已过期",
    used: "已使用",
  };
  return labels[value] || value || "未知";
}

function normalizeWindow(window) {
  if (!window) return null;
  const usedPercent = Number(window.usedPercent ?? 0);
  return {
    usedPercent,
    remainingPercent: Math.max(0, 100 - usedPercent),
    windowDurationMins: window.windowDurationMins ?? null,
    resetsAt: window.resetsAt ?? null,
    resetsAtIso: epochToIso(window.resetsAt),
  };
}

function normalizeSnapshot(snapshot) {
  if (!snapshot) return null;
  return {
    limitId: snapshot.limitId ?? null,
    limitName: snapshot.limitName ?? null,
    planType: snapshot.planType ?? null,
    rateLimitReachedType: snapshot.rateLimitReachedType ?? null,
    primary: normalizeWindow(snapshot.primary),
    secondary: normalizeWindow(snapshot.secondary),
    credits: snapshot.credits ?? null,
    individualLimit: snapshot.individualLimit ?? null,
  };
}

function normalizeRateLimitResponse(response) {
  const rateLimits = normalizeSnapshot(response.rateLimits);
  const byLimitId = {};
  for (const [limitId, snapshot] of Object.entries(response.rateLimitsByLimitId ?? {})) {
    byLimitId[limitId] = normalizeSnapshot(snapshot);
  }
  return {
    fetchedAtIso: new Date().toISOString(),
    rateLimits,
    rateLimitsByLimitId: Object.keys(byLimitId).length ? byLimitId : null,
    display: {
      primaryLabel: rateLimits?.primary ? `5h ${rateLimits.primary.remainingPercent}%` : "5h --",
      secondaryLabel: rateLimits?.secondary ? `W ${rateLimits.secondary.remainingPercent}%` : "W --",
      primaryRemainingPercent: rateLimits?.primary?.remainingPercent ?? null,
      secondaryRemainingPercent: rateLimits?.secondary?.remainingPercent ?? null,
    },
  };
}

function authPath() {
  return process.env.CODEX_AUTH_FILE || path.join(os.homedir(), ".codex", "auth.json");
}

function readCodexAuthTokens() {
  let auth;
  try {
    auth = JSON.parse(fs.readFileSync(authPath(), "utf8"));
  } catch (error) {
    throw new Error(`Unable to read Codex auth file at ${authPath()}: ${error.message}`);
  }
  const tokens = auth.tokens || {};
  if (!tokens.access_token) {
    throw new Error("Codex auth file is missing tokens.access_token. Run codex login again.");
  }
  return tokens;
}

function tlsOptions() {
  const certificatePath = process.env.CODEX_CA_CERTIFICATE || process.env.SSL_CERT_FILE;
  if (!certificatePath) return {};
  try {
    return { ca: fs.readFileSync(certificatePath) };
  } catch {
    return {};
  }
}

function fetchJson(url, headers, timeoutMs = 12000) {
  return new Promise((resolve, reject) => {
    const request = https.request(url, {
      method: "GET",
      headers,
      timeout: timeoutMs,
      ...tlsOptions(),
    }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error(`ChatGPT backend returned HTTP ${response.statusCode}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (error) {
          reject(new Error(`ChatGPT backend returned invalid JSON: ${error.message}`));
        }
      });
    });
    request.on("timeout", () => {
      request.destroy(new Error("Timed out waiting for ChatGPT reset credit response"));
    });
    request.on("error", reject);
    request.end();
  });
}

function normalizeResetCredit(credit) {
  const resetType = credit?.reset_type || credit?.type || "unknown";
  const status = credit?.status || null;
  const createdAtIso = isoString(credit?.created_at || credit?.granted_at);
  const expiresAtIso = isoString(credit?.expires_at);
  return {
    id: credit?.id || null,
    resetType,
    typeLabel: resetCreditTypeLabel(resetType),
    status,
    statusLabel: resetCreditStatusLabel(status),
    createdAtIso,
    expiresAtIso,
    createdAtLabel: formatBeijingDateTime(createdAtIso),
    expiresAtLabel: formatBeijingDateTime(expiresAtIso),
    createdAtShortLabel: formatShortBeijingDateTime(createdAtIso),
    expiresAtShortLabel: formatShortBeijingDateTime(expiresAtIso),
  };
}

function resetCreditSortKey(credit) {
  if (credit.status === "available") return `0-${credit.expiresAtIso || ""}-${credit.createdAtIso || ""}`;
  return `1-${credit.expiresAtIso || ""}-${credit.createdAtIso || ""}`;
}

function normalizeResetCreditsResponse(response) {
  const credits = (Array.isArray(response?.credits) ? response.credits : [])
    .map(normalizeResetCredit)
    .sort((a, b) => resetCreditSortKey(a).localeCompare(resetCreditSortKey(b)));
  const fallbackAvailableCount = credits.filter((credit) => credit.status === "available").length;
  const availableCount = Number.isFinite(Number(response?.available_count))
    ? Number(response.available_count)
    : fallbackAvailableCount;
  const firstTypeLabel = credits[0]?.typeLabel || "Codex 速率限制重置";
  const visibleCredits = (credits.some((credit) => credit.status === "available")
    ? credits.filter((credit) => credit.status === "available")
    : credits).slice(0, 3);
  const detailLabels = visibleCredits.map((credit, index) => (
    `${index + 1}. ${credit.statusLabel} · ${credit.createdAtShortLabel} -> ${credit.expiresAtShortLabel}`
  ));
  if (credits.length > visibleCredits.length) {
    detailLabels.push(`另有 ${credits.length - visibleCredits.length} 个未显示`);
  }
  return {
    fetchedAtIso: new Date().toISOString(),
    availableCount,
    credits,
    display: {
      summaryLabel: `可用次数：${availableCount}`,
      categoryLabel: `${firstTypeLabel} · ${credits.length} 个`,
      detailLabels,
    },
  };
}

function startOfLocalDay(date = new Date()) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function localDateString(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function localTimezoneName() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
}

function tokenCounter() {
  return {
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_output_tokens: 0,
    total_tokens: 0,
  };
}

function addTokenUsage(target, usage) {
  for (const key of Object.keys(target)) {
    target[key] += Number(usage?.[key] ?? 0);
  }
}

function usageRegressed(previous, current) {
  return previous != null && Number(current?.total_tokens ?? 0) < Number(previous?.total_tokens ?? 0);
}

function maxTokenUsage(previous, current) {
  if (previous == null) return { ...current };
  const result = tokenCounter();
  for (const key of Object.keys(result)) {
    result[key] = Math.max(Number(previous?.[key] ?? 0), Number(current?.[key] ?? 0));
  }
  return result;
}

function positiveDelta(previous, current, sameSession) {
  if (previous != null && sameSession && usageRegressed(previous, current)) {
    return null;
  }

  const delta = tokenCounter();
  let hasPositiveDelta = false;
  for (const key of Object.keys(delta)) {
    const currentValue = Number(current?.[key] ?? 0);
    const previousValue = previous == null ? 0 : Number(previous?.[key] ?? 0);
    const value = currentValue >= previousValue ? currentValue - previousValue : (sameSession ? 0 : currentValue);
    delta[key] = value;
    if (value > 0) hasPositiveDelta = true;
  }
  return hasPositiveDelta ? delta : null;
}

function sessionIdFromMeta(event) {
  if (event?.type !== "session_meta") return null;
  return event.payload?.id || event.payload?.session_id || null;
}

function walkJsonlFiles(root, dayStartMs, files = []) {
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return files;
  }

  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      walkJsonlFiles(fullPath, dayStartMs, files);
      continue;
    }
    if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
    try {
      const stat = fs.statSync(fullPath);
      if (stat.mtimeMs >= dayStartMs) files.push(fullPath);
    } catch {
      // Ignore files that disappear while scanning.
    }
  }
  return files;
}

function formatScaledTokenAmount(tokens) {
  const value = Number(tokens ?? 0);
  const formatter = new Intl.NumberFormat("zh-CN", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  });
  if (value >= 10_000_000) return `${formatter.format(value / 100_000_000)}亿`;
  if (value >= 10_000) return `${formatter.format(value / 10_000)}万`;
  return formatter.format(value);
}

function formatCacheHitPercent(percent) {
  if (typeof percent !== "number" || !Number.isFinite(percent)) return "--";
  return `${percent.toFixed(1)}%`;
}

function readLocalTokenUsage() {
  const now = new Date();
  const dayStart = startOfLocalDay(now);
  const dayEnd = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  const sessionsRoot = process.env.CODEX_SESSIONS_DIR || path.join(os.homedir(), ".codex", "sessions");
  const totals = tokenCounter();
  const files = walkJsonlFiles(sessionsRoot, dayStart.getTime());
  const topFiles = [];
  let eventCount = 0;
  let duplicateEventCount = 0;
  let importedEventCount = 0;
  let regressionEventCount = 0;
  let filesWithEvents = 0;
  let parseErrorCount = 0;

  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }

    let previousTotalUsage = null;
    let previousUsageSessionId = null;
    let primarySessionId = null;
    let activeSessionId = null;
    let fileEventCount = 0;
    let fileDuplicateEventCount = 0;
    let fileImportedEventCount = 0;
    let fileRegressionEventCount = 0;
    const fileTotals = tokenCounter();
    let lastEventAtIso = null;

    for (const line of text.split("\n")) {
      if (!line) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        parseErrorCount += 1;
        continue;
      }
      const sessionId = sessionIdFromMeta(event);
      if (sessionId) {
        if (!primarySessionId) primarySessionId = sessionId;
        activeSessionId = sessionId;
        continue;
      }
      if (event.type !== "event_msg" || event.payload?.type !== "token_count") continue;

      const currentTotalUsage = event.payload.info?.total_token_usage;
      if (!currentTotalUsage) continue;

      const timestampMs = Date.parse(event.timestamp ?? "");
      const isToday = Number.isFinite(timestampMs) && timestampMs >= dayStart.getTime() && timestampMs < dayEnd.getTime();
      if (isToday) {
        const isImportedForkEvent = primarySessionId && activeSessionId && activeSessionId !== primarySessionId;
        if (isImportedForkEvent) {
          importedEventCount += 1;
          fileImportedEventCount += 1;
        } else {
          const sameSession = previousUsageSessionId === activeSessionId;
          const regressed = sameSession && usageRegressed(previousTotalUsage, currentTotalUsage);
          const delta = positiveDelta(previousTotalUsage, currentTotalUsage, sameSession);
          if (delta) {
            addTokenUsage(totals, delta);
            addTokenUsage(fileTotals, delta);
          } else {
            duplicateEventCount += 1;
            fileDuplicateEventCount += 1;
            if (regressed) {
              regressionEventCount += 1;
              fileRegressionEventCount += 1;
            }
          }
          eventCount += 1;
          fileEventCount += 1;
          lastEventAtIso = event.timestamp ?? null;
        }
      }
      const sameSession = previousUsageSessionId === activeSessionId;
      if (sameSession || !usageRegressed(previousTotalUsage, currentTotalUsage)) {
        previousTotalUsage = maxTokenUsage(previousTotalUsage, currentTotalUsage);
      } else {
        previousTotalUsage = currentTotalUsage;
      }
      previousUsageSessionId = activeSessionId;
    }

    if (fileEventCount > 0) {
      filesWithEvents += 1;
      topFiles.push({
        file,
        eventCount: fileEventCount,
        duplicateEventCount: fileDuplicateEventCount,
        importedEventCount: fileImportedEventCount,
        regressionEventCount: fileRegressionEventCount,
        primarySessionId,
        totalTokens: fileTotals.total_tokens,
        lastEventAtIso,
      });
    }
  }

  const cacheHitPercent = totals.input_tokens > 0
    ? Math.max(0, Math.min(100, (totals.cached_input_tokens / totals.input_tokens) * 100))
    : null;

  topFiles.sort((a, b) => b.totalTokens - a.totalTokens);

  return {
    fetchedAtIso: now.toISOString(),
    source: sessionsRoot,
    timezone: localTimezoneName(),
    localDate: localDateString(now),
    inputTokens: totals.input_tokens,
    cachedInputTokens: totals.cached_input_tokens,
    outputTokens: totals.output_tokens,
    reasoningOutputTokens: totals.reasoning_output_tokens,
    totalTokens: totals.total_tokens,
    cacheHitPercent,
    eventCount,
    duplicateEventCount,
    importedEventCount,
    regressionEventCount,
    filesScanned: files.length,
    filesWithEvents,
    parseErrorCount,
    topFiles: topFiles.slice(0, 8),
    display: {
      consumptionLabel: `消耗 ${formatScaledTokenAmount(totals.total_tokens)}`,
      cacheHitLabel: `命中 ${formatCacheHitPercent(cacheHitPercent)}`,
    },
  };
}

function callCodexAppServer(methods, timeoutMs = 12000) {
  return new Promise((resolve, reject) => {
    const child = spawn(codexCommand(), ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        NO_COLOR: "1",
        PATH: [
          "/opt/homebrew/bin",
          "/usr/local/bin",
          "/usr/bin",
          "/bin",
          process.env.PATH || "",
        ].join(":"),
      },
    });

    let nextId = 1;
    const pending = new Map();
    const results = {};
    const stderr = [];
    let stdoutBuffer = "";
    let stderrBuffer = "";
    let settled = false;

    function cleanup() {
      clearTimeout(timer);
      if (!child.killed) child.kill("SIGTERM");
    }

    function finishIfReady() {
      if (settled || pending.size > 0) return;
      settled = true;
      cleanup();
      resolve(results);
    }

    function fail(error) {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    }

    function send(label, method, params) {
      const id = nextId++;
      pending.set(id, label);
      const request = { jsonrpc: "2.0", id, method };
      if (params !== undefined) request.params = params;
      child.stdin.write(JSON.stringify(request) + "\n");
    }

    const timer = setTimeout(() => {
      fail(new Error(`Timed out waiting for codex app-server response. stderr=${stderr.join("\n").slice(-2000)}`));
    }, timeoutMs);

    child.on("error", fail);
    child.on("exit", (code, signal) => {
      if (!settled && pending.size > 0) {
        fail(new Error(`codex app-server exited early code=${code} signal=${signal}. stderr=${stderr.join("\n").slice(-2000)}`));
      }
    });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderrBuffer += chunk;
      let index;
      while ((index = stderrBuffer.indexOf("\n")) >= 0) {
        const line = stderrBuffer.slice(0, index);
        stderrBuffer = stderrBuffer.slice(index + 1);
        stderr.push(line);
        if (stderr.length > 50) stderr.shift();
      }
    });

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdoutBuffer += chunk;
      let index;
      while ((index = stdoutBuffer.indexOf("\n")) >= 0) {
        const line = stdoutBuffer.slice(0, index);
        stdoutBuffer = stdoutBuffer.slice(index + 1);
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }
        if (!Object.prototype.hasOwnProperty.call(message, "id")) continue;
        const label = pending.get(message.id);
        if (!label) continue;
        pending.delete(message.id);
        if (message.error) {
          fail(new Error(`${label} failed: ${JSON.stringify(message.error)}`));
          return;
        }
        results[label] = message.result;
        finishIfReady();
      }
    });

    send("initialize", "initialize", {
      clientInfo: {
        name: CLIENT_NAME,
        title: CLIENT_TITLE,
        version: CLIENT_VERSION,
      },
      capabilities: {},
    });

    for (const method of methods) {
      send(method, method);
    }
  });
}

async function readRateLimits() {
  const results = await callCodexAppServer(["account/rateLimits/read"]);
  return normalizeRateLimitResponse(results["account/rateLimits/read"]);
}

async function readTokenUsage() {
  const results = await callCodexAppServer(["account/usage/read"]);
  return {
    fetchedAtIso: new Date().toISOString(),
    usage: results["account/usage/read"],
  };
}

async function readResetCredits({ soft = false } = {}) {
  try {
    const tokens = readCodexAuthTokens();
    const headers = {
      Authorization: `Bearer ${tokens.access_token}`,
      "OpenAI-Beta": "codex-1",
      originator: "Codex Desktop",
    };
    if (tokens.account_id) {
      headers["ChatGPT-Account-ID"] = tokens.account_id;
    }
    return normalizeResetCreditsResponse(await fetchJson(RESET_CREDITS_URL, headers));
  } catch (error) {
    if (!soft) throw error;
    return {
      fetchedAtIso: new Date().toISOString(),
      availableCount: null,
      credits: [],
      error: error?.message || String(error),
      display: {
        summaryLabel: "可用次数：--",
        categoryLabel: "Codex 速率限制重置",
        detailLabels: ["暂时无法读取重置券"],
      },
    };
  }
}

async function readCombined() {
  const results = await callCodexAppServer(["account/rateLimits/read", "account/usage/read"]);
  return {
    ...normalizeRateLimitResponse(results["account/rateLimits/read"]),
    usage: results["account/usage/read"],
  };
}

async function readStatus() {
  const [results, resetCredits] = await Promise.all([
    callCodexAppServer(["account/rateLimits/read"]),
    readResetCredits({ soft: true }),
  ]);
  return {
    ...normalizeRateLimitResponse(results["account/rateLimits/read"]),
    resetCredits,
    localUsage: readLocalTokenUsage(),
  };
}

async function main() {
  const command = process.argv[2] || "rate-limits";
  let payload;
  if (command === "rate-limits" || command === "--json") {
    payload = await readRateLimits();
  } else if (command === "usage") {
    payload = await readTokenUsage();
  } else if (command === "reset-credits") {
    payload = await readResetCredits();
  } else if (command === "combined") {
    payload = await readCombined();
  } else if (command === "local-usage") {
    payload = readLocalTokenUsage();
  } else if (command === "status") {
    payload = await readStatus();
  } else {
    throw new Error(`Unknown command: ${command}`);
  }
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${error?.stack || error}\n`);
    process.exit(1);
  });
}

module.exports = {
  readRateLimits,
  readTokenUsage,
  readResetCredits,
  readCombined,
  readLocalTokenUsage,
  readStatus,
  normalizeRateLimitResponse,
  normalizeResetCreditsResponse,
};
