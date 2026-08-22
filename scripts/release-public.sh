#!/usr/bin/env bash

# Release guard for the dsh-internal-urls monorepo: validates all three
# packages (build, clean tree, pack), then --publish pushes them to npm in
# dependency order (internal-urls first, then tool-fs-internal-urls, then
# tool-fs-search-internal-urls) after a confirmation prompt.

set -euo pipefail

mode="${1:---check}"
registry="https://registry.npmjs.org/"

if [[ "$mode" != "--check" && "$mode" != "--publish" ]]; then
  echo "usage: $0 [--check|--publish]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "release refused: git worktree is not clean" >&2
  exit 1
fi

packages=(
  "packages/internal-urls"
  "packages/tool-fs-internal-urls"
  "packages/tool-fs-search-internal-urls"
)

for dir in "${packages[@]}"; do
  if [[ ! -f "$dir/package.json" || ! -f "$dir/LICENSE" ]]; then
    echo "release refused: $dir/package.json and LICENSE are required" >&2
    exit 1
  fi
  package_name="$(node -p "require('./$dir/package.json').name")"
  if [[ "$package_name" != @hy-sde-org/* ]]; then
    echo "release refused: unexpected package name $package_name (expected @hy-sde-org/*)" >&2
    exit 1
  fi
done

echo "Validating from commit $(git rev-parse HEAD)"

pnpm install
pnpm -r build
pnpm -r check
pnpm -r test

for dir in "${packages[@]}"; do
  package_ref="$(node -p "require('./$dir/package.json').name + '@' + require('./$dir/package.json').version")"
  (cd "$dir" && pnpm pack --pack-destination "$repo_root")
  echo "packed $package_ref"
done

if [[ "$mode" == "--check" ]]; then
  echo "all three packages are ready for a public npm publish"
  exit 0
fi

if ! npm whoami --registry "$registry" >/dev/null 2>&1; then
  echo "release refused: run npm login for $registry first" >&2
  exit 1
fi
if ! npm org ls hy-sde-org --json --registry "$registry" >/dev/null 2>&1; then
  echo "release refused: the npm user is not a member of the hy-sde organization" >&2
  exit 1
fi

for dir in "${packages[@]}"; do
  package_ref="$(node -p "require('./$dir/package.json').name + '@' + require('./$dir/package.json').version")"
  set +e
  view_output="$(npm view "$package_ref" version --json --registry "$registry" 2>&1)"
  view_status=$?
  set -e
  if [[ "$view_status" -eq 0 ]]; then
    echo "release refused: $package_ref already exists on npm" >&2
    exit 1
  fi
  if [[ "$view_output" != *"E404"* ]]; then
    echo "release refused: could not prove $package_ref is absent from npm" >&2
    echo "$view_output" >&2
    exit 1
  fi
done

printf 'Publish internal-urls + tool-fs-internal-urls + tool-fs-search-internal-urls at %s to %s? [y/N] ' "$(node -p "require('./packages/internal-urls/package.json').version")" "$registry"
read -r answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
  echo "publish cancelled"
  exit 1
fi

# publish via pnpm, NOT npm: pnpm rewrites workspace:* dependency specs to
# their published ranges; raw `npm publish` leaks `workspace:^` into the
# tarball. Dependency order: service first, then the tool shadows.
(cd packages/internal-urls && pnpm publish --access public --registry "$registry" --no-git-checks)
(cd packages/tool-fs-internal-urls && pnpm publish --access public --registry "$registry" --no-git-checks)
(cd packages/tool-fs-search-internal-urls && pnpm publish --access public --registry "$registry" --no-git-checks)
echo "published all three @hy-sde-org packages"
