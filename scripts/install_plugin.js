#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const PLUGIN_NAME = "codex-usage-monitor";
const MARKETPLACE_NAME = "personal";
const root = path.resolve(__dirname, "..");
const pluginSource = path.join(root, "plugins", PLUGIN_NAME);
const marketplaceRoot = path.join(os.homedir(), ".agents", "plugins");
const installedPluginParent = path.join(os.homedir(), "plugins");
const installedPluginPath = path.join(installedPluginParent, PLUGIN_NAME);
const marketplacePath = path.join(marketplaceRoot, "marketplace.json");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: options.stdio ?? "pipe",
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
  if (result.status !== 0 && options.allowFailure !== true) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(`${command} ${args.join(" ")} failed${detail ? `:\n${detail}` : ""}`);
  }
  return result;
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if (error && error.code === "ENOENT") return fallback;
    throw error;
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function installPluginFiles() {
  if (!fs.existsSync(path.join(pluginSource, ".codex-plugin", "plugin.json"))) {
    throw new Error(`Plugin source is missing: ${pluginSource}`);
  }
  fs.mkdirSync(installedPluginParent, { recursive: true });
  fs.rmSync(installedPluginPath, { recursive: true, force: true });
  fs.cpSync(pluginSource, installedPluginPath, { recursive: true });
  stampInstalledPluginVersion();
}

function stampInstalledPluginVersion() {
  const manifestPath = path.join(installedPluginPath, ".codex-plugin", "plugin.json");
  const manifest = readJson(manifestPath, null);
  if (!manifest) return;
  const baseVersion = String(manifest.version || "0.1.0").replace(/\+codex\.\d+$/, "");
  const timestamp = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 14);
  manifest.version = `${baseVersion}+codex.${timestamp}`;
  writeJson(manifestPath, manifest);
}

function ensureMarketplace() {
  const marketplace = readJson(marketplacePath, {
    name: MARKETPLACE_NAME,
    interface: { displayName: "Personal" },
    plugins: [],
  });
  marketplace.name = marketplace.name || MARKETPLACE_NAME;
  marketplace.interface = marketplace.interface || { displayName: "Personal" };
  marketplace.plugins = Array.isArray(marketplace.plugins) ? marketplace.plugins : [];

  const entry = {
    name: PLUGIN_NAME,
    source: {
      source: "local",
      path: `./plugins/${PLUGIN_NAME}`,
    },
    policy: {
      installation: "AVAILABLE",
      authentication: "ON_INSTALL",
    },
    category: "Productivity",
  };

  const index = marketplace.plugins.findIndex((plugin) => plugin && plugin.name === PLUGIN_NAME);
  if (index >= 0) {
    marketplace.plugins[index] = entry;
  } else {
    marketplace.plugins.push(entry);
  }
  writeJson(marketplacePath, marketplace);
}

function isInstalled() {
  const result = run("codex", ["plugin", "list", "--json", "--available"], { allowFailure: true });
  if (result.status !== 0) return false;
  try {
    const payload = JSON.parse(result.stdout);
    return Array.isArray(payload.installed)
      && payload.installed.some((plugin) => plugin.pluginId === `${PLUGIN_NAME}@${MARKETPLACE_NAME}`);
  } catch {
    return false;
  }
}

function refreshCodexPlugin() {
  if (isInstalled()) {
    run("codex", ["plugin", "remove", `${PLUGIN_NAME}@${MARKETPLACE_NAME}`, "--json"], { stdio: "inherit", allowFailure: true });
  }
  run("codex", ["plugin", "add", `${PLUGIN_NAME}@${MARKETPLACE_NAME}`, "--json"], { stdio: "inherit" });
}

installPluginFiles();
ensureMarketplace();
refreshCodexPlugin();

console.log(`Installed ${PLUGIN_NAME}@${MARKETPLACE_NAME}`);
console.log(`Marketplace: ${marketplacePath}`);
console.log(`Plugin files: ${installedPluginPath}`);
