#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

const args = process.argv.slice(2);
const DRY_RUN = args.includes("--dry-run");
const KIND = args.find((a) => !a.startsWith("--"));
if (!["patch", "minor", "major"].includes(KIND)) {
  console.error("Usage: release.mjs <patch|minor|major> [--dry-run]");
  process.exit(1);
}

// One version drives everything. These package.json files carry the shared semver.
const TARGETS = [
  resolve(ROOT, "package.json"),          // monorepo root
  resolve(ROOT, "landing/package.json"),  // the Astro landing site
];

// The native macOS app's version lives in app/project.yml (XcodeGen's single source of truth —
// release.sh reads MARKETING_VERSION from it, and Info.plist holds the literal $(MARKETING_VERSION)).
// Keep it in lockstep with the web version, and bump the integer build number so every release is
// strictly newer than the last (Sparkle compares CFBundleVersion when deciding whether to update).
const PROJECT_YML = resolve(ROOT, "app/project.yml");

const CHANGELOG = resolve(ROOT, "CHANGELOG.md");

const TYPE_MAP = {
  feat: { label: "Added", order: 1 },
  feature: { label: "Added", order: 1 },
  fix: { label: "Fixed", order: 2 },
  bugfix: { label: "Fixed", order: 2 },
  improvement: { label: "Improved", order: 3 },
  improve: { label: "Improved", order: 3 },
  perf: { label: "Improved", order: 3 },
  refactor: { label: "Improved", order: 3 },
};

const HIDDEN_TYPES = new Set(["chore", "docs", "ci", "test", "build", "style", "revert"]);

function sh(cmd) {
  return execSync(cmd, { cwd: ROOT, encoding: "utf8" }).trim();
}

function bump(version, kind) {
  const parts = version.split("-")[0].split(".").map(Number);
  let [maj, min, pat] = parts;
  if (kind === "major") { maj += 1; min = 0; pat = 0; }
  else if (kind === "minor") { min += 1; pat = 0; }
  else { pat += 1; }
  return `${maj}.${min}.${pat}`;
}

function lastTag() {
  try { return sh("git describe --tags --abbrev=0"); }
  catch { return null; }
}

function getCommits(since) {
  const range = since ? `${since}..HEAD` : "HEAD";
  const raw = sh(`git log ${range} --pretty=format:%H%x1f%s%x1e`);
  if (!raw) return [];
  return raw
    .split("\x1e")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((line) => {
      const [hash, subject] = line.split("\x1f");
      return { hash: hash?.slice(0, 7), subject: subject ?? "" };
    });
}

function parseCommit(subject) {
  const match = subject.match(/^([a-zA-Z]+)(?:\(([^)]+)\))?(!)?:\s*(.+)$/);
  if (!match) return null;
  const [, rawType, scope, breaking, description] = match;
  const type = rawType.toLowerCase();
  return { type, scope, breaking: Boolean(breaking), description: description.trim() };
}

function groupCommits(commits) {
  const groups = new Map();
  for (const c of commits) {
    const parsed = parseCommit(c.subject);
    if (!parsed) continue;
    if (HIDDEN_TYPES.has(parsed.type)) continue;
    const meta = TYPE_MAP[parsed.type];
    if (!meta) continue;
    if (!groups.has(meta.label)) groups.set(meta.label, { order: meta.order, items: [] });
    groups.get(meta.label).items.push({ ...parsed, hash: c.hash });
  }
  return [...groups.entries()]
    .sort((a, b) => a[1].order - b[1].order)
    .map(([label, { items }]) => ({ label, items }));
}

function renderSection(version, groups) {
  const date = new Date().toISOString().slice(0, 10);
  const lines = [`## ${version} (${date})`, ""];
  if (groups.length === 0) {
    lines.push("_Maintenance release — no user-facing changes._", "");
    return lines.join("\n");
  }
  for (const { label, items } of groups) {
    lines.push(`### ${label}`, "");
    for (const item of items) {
      const scope = item.scope ? `**${item.scope}**: ` : "";
      const breaking = item.breaking ? " ⚠️ BREAKING" : "";
      lines.push(`- ${scope}${item.description}${breaking} (${item.hash})`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

function prependSection(section) {
  let existing = "";
  if (existsSync(CHANGELOG)) existing = readFileSync(CHANGELOG, "utf8");
  const headerMatch = existing.match(/^([\s\S]*?\n)(##\s)/);
  if (headerMatch) {
    const [, header] = headerMatch;
    const rest = existing.slice(header.length);
    writeFileSync(CHANGELOG, `${header}${section}\n${rest}`);
  } else if (existing.trim()) {
    writeFileSync(CHANGELOG, `${existing.replace(/\n*$/, "\n")}\n${section}\n`);
  } else {
    writeFileSync(CHANGELOG, `# Changelog\n\nAll notable changes to Sidewire.\n\n${section}\n`);
  }
}

// --- app/project.yml: MARKETING_VERSION (semver) + CURRENT_PROJECT_VERSION (integer build no.) ---
function readProjectVersions() {
  if (!existsSync(PROJECT_YML)) return null;
  const raw = readFileSync(PROJECT_YML, "utf8");
  const mv = raw.match(/^(\s*MARKETING_VERSION:\s*)"?([^"\n]+)"?\s*$/m);
  const cpv = raw.match(/^(\s*CURRENT_PROJECT_VERSION:\s*)"?([^"\n]+)"?\s*$/m);
  return {
    raw,
    marketing: mv ? mv[2].trim() : null,
    build: cpv ? cpv[2].trim() : null,
  };
}

function writeProjectVersions(newVersion) {
  const info = readProjectVersions();
  if (!info) return null;
  let out = info.raw;
  const prevBuild = info.build != null ? parseInt(info.build, 10) : NaN;
  const nextBuild = Number.isFinite(prevBuild) ? String(prevBuild + 1) : info.build;
  out = out.replace(/^(\s*MARKETING_VERSION:\s*)"?[^"\n]+"?\s*$/m, `$1"${newVersion}"`);
  if (info.build != null) {
    out = out.replace(/^(\s*CURRENT_PROJECT_VERSION:\s*)"?[^"\n]+"?\s*$/m, `$1"${nextBuild}"`);
  }
  if (!DRY_RUN) writeFileSync(PROJECT_YML, out);
  return { prevMarketing: info.marketing, prevBuild: info.build, nextBuild };
}

function assertCleanTree() {
  if (DRY_RUN) return;
  try {
    const status = sh("git status --porcelain");
    if (status) {
      console.error("❌ Working tree is not clean. Commit your changes first:\n" + status);
      process.exit(1);
    }
    const branch = sh("git rev-parse --abbrev-ref HEAD");
    if (branch !== "main" && branch !== "master") {
      console.error(`❌ Releases can only be cut from main (current branch: ${branch}).`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`❌ git check failed: ${err.message}`);
    process.exit(1);
  }
}

function main() {
  assertCleanTree();

  const rootPkgRaw = readFileSync(TARGETS[0], "utf8");
  const rootPkg = JSON.parse(rootPkgRaw);
  const newVersion = bump(rootPkg.version, KIND);

  const since = lastTag();
  console.log(`Commits since ${since ?? "beginning"}:`);
  const commits = getCommits(since);
  const groups = groupCommits(commits);
  for (const g of groups) console.log(`  [${g.label}] ${g.items.length}`);
  if (groups.length === 0) {
    console.warn(`\n⚠️  No user-facing commits (feat/fix/improvement/perf/refactor) since the last tag.`);
    console.warn(`   The CHANGELOG section will be empty.`);
    if (!DRY_RUN) { console.warn(`   Re-run with --dry-run to preview, or press Ctrl+C now to abort.`); }
  }

  const section = renderSection(newVersion, groups);

  if (DRY_RUN) {
    console.log(`\n--- DRY RUN: new CHANGELOG.md section (v${newVersion}) ---\n`);
    console.log(section);
    console.log(`--- files that would be updated ---`);
    for (const file of TARGETS) {
      if (existsSync(file)) console.log(`  ${file.replace(ROOT + "/", "")}: ${JSON.parse(readFileSync(file, "utf8")).version} -> ${newVersion}`);
    }
    const info = readProjectVersions();
    if (info) {
      const nextBuild = Number.isFinite(parseInt(info.build, 10)) ? String(parseInt(info.build, 10) + 1) : info.build;
      console.log(`  app/project.yml (MARKETING_VERSION): ${info.marketing} -> ${newVersion}`);
      if (info.build != null) console.log(`  app/project.yml (CURRENT_PROJECT_VERSION): ${info.build} -> ${nextBuild}`);
    }
    console.log(`\nRe-run without --dry-run to apply.`);
    return;
  }

  for (const file of TARGETS) {
    if (!existsSync(file)) continue;
    const raw = readFileSync(file, "utf8");
    const pkg = JSON.parse(raw);
    if (!pkg.version) continue;
    const prev = pkg.version;
    pkg.version = newVersion;
    const trailing = raw.endsWith("\n") ? "\n" : "";
    writeFileSync(file, JSON.stringify(pkg, null, 2) + trailing);
    console.log(`${file.replace(ROOT + "/", "")}: ${prev} -> ${newVersion}`);
  }

  const proj = writeProjectVersions(newVersion);
  if (proj) {
    console.log(`app/project.yml (MARKETING_VERSION): ${proj.prevMarketing} -> ${newVersion}`);
    if (proj.prevBuild != null) console.log(`app/project.yml (CURRENT_PROJECT_VERSION): ${proj.prevBuild} -> ${proj.nextBuild}`);
  }

  prependSection(section);
  console.log(`\nCHANGELOG.md updated with v${newVersion}`);

  try {
    const files = [...TARGETS, PROJECT_YML, CHANGELOG].filter(existsSync).map((t) => `"${t}"`).join(" ");
    execSync(`git add ${files}`, { cwd: ROOT, stdio: "inherit" });
    execSync(`git commit -m "chore: release v${newVersion}"`, { cwd: ROOT, stdio: "inherit" });
    // Must be ANNOTATED: `git push --follow-tags` only pushes annotated tags, so a lightweight
    // tag would never reach the remote and no tag-triggered pipeline would ever fire.
    execSync(`git tag -a "v${newVersion}" -m "Sidewire v${newVersion}"`, { cwd: ROOT, stdio: "inherit" });
    console.log(`\n✅ Created commit + tag v${newVersion} (locally)`);
    console.log(`   Push it: git push --follow-tags`);
    console.log(`   If something went wrong BEFORE pushing: pnpm release:undo`);
  } catch (err) {
    console.warn(`\nGit step skipped: ${err.message}`);
  }
}

main();
