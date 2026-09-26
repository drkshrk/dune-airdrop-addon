#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const manifestPath = path.join(repoRoot, "addon.json");
const allowedPermissions = new Set([
  "players:read",
  "database:read",
  "database:write",
  "server:status",
  "server:restart",
  "files:addon-data",
  "broadcast:send",
  "admin:grant-items",
  "rewards:grant"
]);

function fail(message) {
  console.error(`Validation failed: ${message}`);
  process.exit(1);
}

function readManifest() {
  if (!fs.existsSync(manifestPath)) {
    fail("addon.json is missing.");
  }

  try {
    return JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (error) {
    fail(`addon.json is not valid JSON. ${error.message}`);
  }
}

function requireString(manifest, field) {
  if (typeof manifest[field] !== "string" || manifest[field].trim() === "") {
    fail(`${field} must be a non-empty string.`);
  }
}

function validateEntry(manifest) {
  if (!manifest.entry || typeof manifest.entry !== "object") {
    fail("entry must be an object.");
  }

  if (typeof manifest.entry.navigation !== "string" || !manifest.entry.navigation.trim()) {
    fail("entry.navigation must be a non-empty string.");
  }

  if (typeof manifest.entry.path !== "string" || !manifest.entry.path.trim()) {
    fail("entry.path must be a non-empty string.");
  }

  const entryPath = manifest.entry.path;
  if (entryPath.startsWith("/") || entryPath.includes("..")) {
    fail("entry.path must be a relative path inside the addon package.");
  }

  const resolvedEntryPath = path.resolve(repoRoot, entryPath);
  if (!resolvedEntryPath.startsWith(repoRoot + path.sep)) {
    fail("entry.path must stay inside the addon package.");
  }

  if (!fs.existsSync(resolvedEntryPath)) {
    fail(`entry.path does not exist: ${entryPath}`);
  }
}

function normalizePermissions(value) {
  if (!value) return [];

  if (Array.isArray(value)) {
    return value;
  }

  if (typeof value !== "object") {
    fail("permissions must be an object or array.");
  }

  const normalized = [];
  for (const [scope, actions] of Object.entries(value)) {
    if (!Array.isArray(actions)) {
      fail(`permissions.${scope} must be an array.`);
    }

    for (const action of actions) {
      normalized.push(`${scope}:${action}`);
    }
  }

  return normalized;
}

function validatePermissions(manifest) {
  const permissions = normalizePermissions(manifest.permissions);

  for (const permission of permissions) {
    if (!allowedPermissions.has(permission)) {
      fail(`unsupported permission: ${permission}`);
    }
  }
}

function validateRuntimeFiles() {
  const requiredFiles = [
    "setup_playtime_airdrops.sql",
    "uninstall_playtime_airdrops.sql",
    "scripts/create_zip.py"
  ];
  for (const relativePath of requiredFiles) {
    if (!fs.existsSync(path.join(repoRoot, relativePath))) {
      fail(`required runtime file is missing: ${relativePath}`);
    }
  }
}

function main() {
  const manifest = readManifest();

  if (manifest.schemaVersion !== 1) {
    fail("schemaVersion must be 1.");
  }

  requireString(manifest, "id");
  requireString(manifest, "name");
  requireString(manifest, "description");
  requireString(manifest, "author");
  requireString(manifest, "version");

  if (!/^[a-z0-9][a-z0-9-]{2,63}$/.test(manifest.id)) {
    fail("id must be lowercase, URL-safe, and 3-64 characters.");
  }

  if (manifest.type !== "ui") {
    fail("type must be ui.");
  }

  validateEntry(manifest);
  validatePermissions(manifest);
  validateRuntimeFiles();

  console.log(`Addon manifest is valid: ${manifest.id} ${manifest.version}`);

  console.log("Running automated tests...");
  const { execSync } = require("child_process");
  try {
    execSync("npm test", { stdio: "inherit", cwd: repoRoot });
    console.log("Tests passed.");
  } catch (err) {
    fail("Tests failed.");
  }
}

main();
