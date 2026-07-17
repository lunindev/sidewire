#!/usr/bin/env node
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function sh(cmd) {
  return execSync(cmd, { cwd: ROOT, encoding: "utf8" }).trim();
}

function main() {
  const lastCommit = sh("git log -1 --pretty=%s");
  const match = lastCommit.match(/^chore:\s*release\s+v(\d+\.\d+\.\d+)$/);
  if (!match) {
    console.error(`❌ The last commit does not look like a release: "${lastCommit}"`);
    console.error(`   Nothing to undo. release:undo only works immediately after pnpm version:*.`);
    process.exit(1);
  }
  const version = match[1];
  const tag = `v${version}`;

  // Fail closed: only skip the remote check when there is genuinely no `origin` (nothing could
  // have been pushed). If `origin` exists but the check errors (offline, auth, etc.), refuse — we
  // must not hard-reset a release that might already be public.
  let hasOrigin = true;
  try { sh("git remote get-url origin"); } catch { hasOrigin = false; }

  if (hasOrigin) {
    let remoteTag;
    try {
      remoteTag = sh(`git ls-remote --tags origin refs/tags/${tag}`);
    } catch (err) {
      const msg = String(err.message || err).split("\n")[0];
      console.error(`❌ Could not check origin (${msg}).`);
      console.error(`   release:undo refuses to run until it can confirm that tag ${tag} was NOT pushed.`);
      console.error(`   Check your network/access to origin and retry, or roll back manually.`);
      process.exit(1);
    }
    if (remoteTag) {
      console.error(`❌ Tag ${tag} is already pushed to origin. release:undo only works before a push.`);
      console.error(`   To delete a pushed tag: git push --delete origin ${tag} && git tag -d ${tag}`);
      console.error(`   Then git reset --hard HEAD~1 if you also need to drop the commit (careful!).`);
      process.exit(1);
    }

    // The tag check alone is not enough: a plain `git push` sends the commit without the tag,
    // leaving "commit public, tag absent" — a state the check above happily accepts. Verify the
    // release commit itself is not reachable from origin before hard-resetting anything.
    let remoteHasCommit = "";
    try {
      // Refresh first — a stale remote-tracking ref would report "not on origin" for a commit
      // that is, in fact, already published.
      sh("git fetch origin --quiet");
      remoteHasCommit = sh(`git branch -r --contains HEAD --list "origin/*"`);
    } catch {
      console.error(`❌ Could not determine whether the release commit is already on origin.`);
      console.error(`   Refusing to reset. Roll back manually.`);
      process.exit(1);
    }
    if (remoteHasCommit) {
      console.error(`❌ The release commit is already on origin (${remoteHasCommit.trim().split("\n").join(", ")}).`);
      console.error(`   release:undo will not rewrite published history. Revert it instead:`);
      console.error(`     git revert HEAD`);
      process.exit(1);
    }
  }

  console.log(`Undoing local release ${tag}...`);
  execSync(`git tag -d ${tag}`, { cwd: ROOT, stdio: "inherit" });
  execSync(`git reset --hard HEAD~1`, { cwd: ROOT, stdio: "inherit" });
  console.log(`\n✅ Tag ${tag} deleted, release commit rolled back.`);
}

main();
