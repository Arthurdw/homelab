#!/usr/bin/env bash
# Shared helpers for the lab's in-cluster Git server. Sourced by lab-up.sh, lab-sync.sh and
# virt/flux-up.sh.
#
# bake_lab_git_repo <ctx> <branch> <repo_root>
#   Writes <ctx>/homelab.git: a bare repo holding every ref of the checkout plus one extra commit on
#   <branch> with the CURRENT WORKING TREE (tracked, modified and untracked-but-not-ignored files),
#   so Flux reconciles what you are about to commit.
#
#   Only files git considers part of the project (`ls-files --cached --others --exclude-standard`)
#   are copied, so gitignored material (talos/out, *.agekey, .env, docs/private, ...) never
#   leaves the working tree and cannot end up in the repo.
#
# bake_lab_git_image <ctx> <branch> <repo_root>
#   bake_lab_git_repo, then builds the `homelab-git:lab` image with it at /git/homelab.git (kind lab).
#   The caller must still `kind load docker-image homelab-git:lab`.

bake_lab_git_repo() {
  local ctx="$1" branch="$2" repo_root="$3"
  local work="$ctx/work"

  command -v rsync >/dev/null 2>&1 || { echo "missing tool: rsync" >&2; return 1; }

  git clone --quiet --mirror "$repo_root" "$ctx/homelab.git"

  mkdir -p "$work"
  # Skip tracked files deleted in the working tree (ls-files still lists them).
  git -C "$repo_root" ls-files -z --cached --others --exclude-standard \
    | (cd "$repo_root" && while IFS= read -r -d '' f; do
         if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi
       done) \
    | rsync -a --from0 --files-from=- "$repo_root"/ "$work"/

  git -C "$work" init --quiet -b "$branch"
  git -C "$work" add -A
  git -C "$work" -c user.name=lab -c user.email=lab@example.invalid \
    commit --quiet --allow-empty -m "lab snapshot: working tree"
  git -C "$work" push --quiet --force "$ctx/homelab.git" "HEAD:refs/heads/$branch"
  git -C "$ctx/homelab.git" symbolic-ref HEAD "refs/heads/$branch"
}

bake_lab_git_image() {
  local ctx="$1" branch="$2" repo_root="$3"

  bake_lab_git_repo "$ctx" "$branch" "$repo_root"
  cp "$repo_root/scripts/lab/gitserver/Dockerfile" \
     "$repo_root/scripts/lab/gitserver/nginx.conf" \
     "$repo_root/scripts/lab/gitserver/entrypoint.sh" "$ctx/"
  docker build -q -t homelab-git:lab "$ctx" >/dev/null
}
