# ctree

Replicate any Docker-compose based git repo as a sibling git worktree,
with its own branch, docker volumes, and a tailored `.env`, so that
multiple branches can run side by side without interfering with
each other's state.

## Install

Clone this repository, then add a single line to your shell rc so the
`ctree` function is available in every terminal:

```bash
cd your_repositories_directory
git clone https://github.com/mytrak/ctree.git
```

`ctree shell-init` prints a shell function; you `eval` its output so the
function is defined in your current shell. Execute commands below to add
an entry for ctree to your **`~/.zshrc`** (zsh, the macOS default) or
**`~/.bashrc`** (bash). Don't add an entry to `~/.bash_profile` or
`~/.zprofile` as those run only for login shells, but the function needs
to be defined for every interactive shell.

```bash
cd ctree
echo "eval \"\$($(pwd)/bin/ctree shell-init)\"" >> ~/.zshrc
```

The function is regenerated on every shell startup, so it always matches
the installed binary — there is nothing to re-paste when ctree is upgraded.

Then reload the file (or just open a new terminal tab):

```bash
source ~/.zshrc
```

Verify:

```bash
type ctree            # should print: ctree is a shell function
ctree list            # sanity-check that the binary runs
```

With the shell function installed, `ctree switch <name>` changes the
directory of your current shell directly — no subshell involved. Every
other subcommand (`create`, `delete`, `list`, `update`, `config`, etc.)
falls through to the real binary unchanged. Without the shell function,
`ctree switch <name>` spawns a child shell at the target path instead —
`exit` returns you to where you invoked it from.

#### Troubleshooting

**`command not found: ctree` in a fresh terminal** — `.zshrc` either
isn't being read or it bailed early. Check `echo $0` (should be
`-zsh`), then confirm the `eval` line points at a path that actually
contains the `ctree` executable.

## Usage

Most commands run from the source repository.
`update`, `rebase`, `free`, `env`, and `compose-config` run from inside a worktree.

```bash
ctree create <worktree_name> <branch_name>
ctree delete <worktree_name>
ctree list   [all | free | used]
ctree switch <worktree_name>
ctree rebase
ctree update
ctree free
ctree env    [list | check | fix]
ctree version
ctree domain [list | [add | delete] <tld>]
ctree config [list | add | delete]
ctree compose-config [list | check | fix]
ctree help <command>
```

### create

Creates a sibling worktree at `../<worktree_name>`. The entire source
directory — tracked files AND gitignored runtime content (node_modules,
build artifacts, plugin lock files, etc.) — is cloned into the new
worktree in one operation. On macOS APFS this is near-instant CoW via
`clonefile(2)`; on Linux, `cp --reflink=auto` provides the same for
btrfs/xfs and falls back to a plain copy on ext4.

After the cloning, docker volumes are replicated under the new compose
prefix and a tailored `.env` is written with `COMPOSE_PROJECT_NAME`.
For each constant defined in the source `.env` you will be prompted
to either accept or update the value for the worktree. Values for
secret-looking keys are never printed — see [Secret values](#secret-values).

#### Free space preflight

Volume replication can move tens of gigabytes, so before writing anything
`create` measures the volumes it is about to copy and the space available
to receive them, and aborts if the copy would not leave 5GB free:

```
⚠️ copying 9.1GB of volumes needs 14.1GB free
⚠️ docker has 3.2GB available
⚠️ continuing would exhaust the disk and crash containers in every running stack
```

The available figure is read with `df` from inside a container, which
reports what an ordinary process can write. This matters: ext4 keeps a
root-only reserve (5% by default), so ctree's root-owned copy can run to
completion and report success while every non-root writer on the host —
postgres in particular — is already failing with `No space left on
device`. Without the preflight, one `create` can silently take down the
databases of every other stack on the machine.

### delete

Reverses `create`: lists everything that would be deleted, prompts for
explicit `yes` confirmation, then tears it all down — the worktree
directory, its `git worktree` registration, the per-project docker
volumes, and any running compose stack.

**Branches are always preserved**, including the auto-derived branch
that `ctree create <name>` creates when no explicit branch is passed.
This is deliberately safe: an auto-derived branch can still carry
commits you want to keep, push, or re-check-out in a fresh worktree
later, and ctree can't tell from the branch itself whether that's the
case.

### switch

Drops you into a new shell at the chosen worktree's directory. The name
must match the basename of an existing worktree (as shown by
`ctree list`). Exits with an error if no worktree matches.

Because `ctree` runs as a subprocess, it cannot `cd` your current shell
directly — `switch` spawns a child shell at the target path, and
`exit` returns you to where you invoked it from. To make `switch`
behave like a true `cd` in the parent shell, wrap the binary in a
shell function as described in Install above.

### list

Lists all worktrees for the current source repo. Each entry shows the
worktree path and its checked-out branch.

```bash
ctree list           # all worktrees
ctree list all       # same as above
ctree list free      # only worktrees on a free placeholder branch
ctree list used      # only worktrees on a non-free branch
```

Worktrees on a branch whose name starts with `free_branch_prefix`
(default `FREE-`, configurable in `.ctree/config.yml`) are annotated
with `(free)`. `ctree list free` limits output to those worktrees;
`ctree list used` shows the rest.

### rebase

Run **from inside a worktree** (no arguments). Does two things in order:

1. Rebases the worktree's current branch onto the source repo's `master`.
   Skips automatically if `master` is already an ancestor (i.e. the
   branch is already up to date). Aborts and reports conflicts if the
   rebase cannot complete cleanly.
2. Rebases each embedded git repo listed under `rebase` in
   `.ctree/config.yml` (e.g. `gems/plugins`) from its source
   counterpart.

All operations are local — no network calls are made. Update the source
repo first, then run `ctree rebase` from the worktree to catch it up.

### update

Run **from inside a worktree** (no arguments). ctree resolves the source repo
from git's common dir, then:

1. Re-tags the source's images to the worktree's project name, so the worktree
   picks up images the source rebuilt (e.g. after rebuilding source images).
2. Rsyncs allowlisted volumes (`update_volumes`) from source to worktree.
3. Copies or syncs any paths listed in `update` from source to worktree (see
   schema below).

Shared volumes (`share_volumes`, e.g. gems/node_modules) are mounted
from the source via the override file, so they are already live — update does not
copy them.

Before doing anything, ctree warns and asks for confirmation (default **no**) if
the source is on a non-default branch.

### free

Run **from inside a worktree** (no arguments). Resets the worktree to a free
placeholder branch so it can be reused. ctree:

1. Prompts for confirmation (default **yes**).
2. Lists all local branches whose names start with the configured
   `free_branch_prefix` (default `FREE-`).
3. Checks out the first available branch — one not currently checked out in
   any worktree — sorted alphabetically.
4. If all free branches are occupied, creates the next sequential one,
   filling gaps in the numeric sequence. For example, if `FREE-001` and
   `FREE-003` both exist and are checked out, it creates and checks out
   `FREE-002`. If no free branches exist at all, it creates `FREE-001`.
   Numbers are zero-padded to at least 3 digits (`FREE-001`, `FREE-002`, …).
5. Rebases the checked-out branch onto the source repo's `master` (skipped
   automatically if already up to date). Aborts and reports on conflict —
   resolve manually and re-run `ctree rebase` from the worktree.

### env

Run **from inside a worktree**. Manages the worktree's `.env` relative to the
source repo's `.env`.

```bash
ctree env list    # print current worktree .env
ctree env check   # report discrepancies
ctree env fix     # resolve discrepancies interactively
```

#### list

Prints all `KEY=VALUE` pairs from the worktree `.env`, with secret-looking
keys rendered as `KEY=(hidden)` (see [Secret values](#secret-values)). No
comparison with the source is performed. Read the file directly if you
need a secret's value.

#### check

Reports discrepancies between the source and worktree `.env` and exits 1
if any are found:

- `[missing] KEY` — key present in the source `.env` but absent from the
  worktree. All missing keys are reported, including those in
  `skip_env_keys`.
- `[extra] KEY` — key present in the worktree `.env` but absent from the
  source. ctree-managed keys (`COMPOSE_PROJECT_NAME`, `HOST_NAME`,
  `HOST_NAME_SUFFIX`, and `host_domain_env_key` when configured) and keys
  in `skip_env_keys` are never reported as extra.

Exits 0 if the envs are in sync.

#### fix

Resolves discrepancies interactively, acting only on actual gaps:

- **Missing keys** — prompts with the source value as the default; press
  enter to accept or type a new value.
- **Extra keys** — offers deletion (`[y/N]`); defaults to keeping the key.
- **Keys already present in both** — left untouched, no prompt shown.

ctree-managed keys and `skip_env_keys` are never offered for deletion.
Missing keys are always prompted regardless of `skip_env_keys`.

#### Secret values

A key whose name contains `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`,
`CREDENTIAL`, `API_KEY`, or `PRIVATE_KEY` is prompted without its value:

```
✓ ARTIFACTORY_TOKEN (hidden, 64 chars)
  review-1: same as source
  review-2: differs
?   (enter to copy from source, or type a new value):
```

This covers the terminal and any logfile an embedder installs behind the
UI backend, since both are fed from the same `Log` calls. Sibling
worktrees are compared against the source rather than listed, so a shared
token is still visible as shared without being printed.

The same rule applies everywhere ctree would otherwise render a value:
`env list` and the `env fix` delete prompt print `KEY=(hidden)`, and so
do `create`'s `--debug` lines and its end-of-run summary. No ctree code
path prints a secret's value; `.env` itself remains the only place to
read one.

### compose-config

Run **from inside a worktree**. Manages shared-volume external references
in the compose override file (configured via `compose_override_file` in
`.ctree/config.yml`).

```bash
ctree compose-config list    # show current state of the override file
ctree compose-config check   # report missing or incorrect external references
ctree compose-config fix     # write corrections automatically
```

`fix` rewrites the override file to add correct `external: true` and
`name: <source_project>_<suffix>` entries for any `share_volumes` that
are missing or incorrect.

### domain

**macOS only.** Configures local DNS resolution for a TLD so that all
`*.tld` names resolve to `127.0.0.1`.

```bash
ctree domain list             # show configured TLDs and resolver status
ctree domain add <tld>        # add wildcard DNS rule for <tld>
ctree domain delete <tld>     # remove wildcard DNS rule for <tld>
```

`add <tld>` writes a wildcard dnsmasq rule (`address=/.tld/127.0.0.1`)
and creates a macOS resolver file at `/etc/resolver/<tld>` (requires
`sudo`). `delete <tld>` removes both. `list` shows which TLDs are
configured in dnsmasq and whether their `/etc/resolver/<tld>` files are
present.

## Configuration

Which docker volumes ctree copies, syncs, or treats as source-shared caches
is controlled by config — not by hardcoded values in the executable. There
are two layers:

1. **Shipped defaults** in `lib/ctree/config.yml` (loaded automatically).
2. **Per-repo override** at `<source_repo>/.ctree/config.yml` (optional). Keys
   present here replace the shipped values; keys you omit fall through to
   the defaults.

### Schema

```yaml
# <source_repo>/.ctree/config.yml — all keys are optional

# Volumes to share between the source and every worktree.
# List the SUFFIX only — the part after the leading `<project>_`.
#
#   Full volume name          Suffix to list
#   ------------------------  ---------------
#   myapp_yarn-cache      →   yarn-cache
#   myapp_app-gems            app-gems
#
# ctree rewrites the worktree's override file to mount the source volume
# directly (external: true) rather than creating a new empty one.
# Example:
# share_volumes:
#   - yarn-cache
#   - app-gems

# Volumes that `ctree update` is allowed to rsync from source into the worktree.
# List the SUFFIX only — the part after the leading `<project>_`.
#
#   Full volume name   Suffix to list
#   -----------------  ---------------
#   myapp_code     →   code
#   myapp_bundle   →   bundle
#
# This is an allowlist — anything not listed is left untouched, so new
# stateful volumes fail closed rather than being silently overwritten.
# Example:
# update_volumes:
#   - code
#   - bundle

# Volume name suffixes created empty in the worktree during `ctree create`
# instead of being rsynced from source. Use for transient data that should
# always start fresh (logs, tmp files, reports). These volumes are also
# silently skipped by `ctree update`, regardless of update_volumes.
# Suffix = everything after the leading `<project>_`.
# Example:
# empty_volumes:
#   - log
#   - tmp

# Repo-relative files or directories copied/synced from source to worktree
# during `ctree create` and `ctree update`. Use for gitignored artifacts
# that must match the source after a volume sync (e.g. lock files for gem
# volumes). Files are copied directly; directories are synced
# recursively (additions, modifications, and deletions).
# Example:
# update:
#   - Gemfile.plugins.lock   # a gitignored lock file

# Top-level names (files or directories) to skip when cloning the source
# working tree during `ctree create`. Matched by basename.
# Example:
# exclude:
#   - node_modules

# Directories (relative to repo root) scanned for embedded git repos
# during `ctree rebase`. Subdirectories with a .git entry that are not
# submodules are rebased from their source counterpart.
# Example:
# rebase:
#   - gems/plugins

# The TLD appended to the worktree name to form HOST_NAME_SUFFIX
# in the worktree .env. Leave empty to disable.
# Example:
# host_name_suffix: docker

# The docker-compose override file ctree appends to the worktree's
# COMPOSE_FILE and rewrites shared-volume entries in.
# Example:
# compose_override_file: docker-compose.local.ctree.yml

# Branch name prefix used to identify free (placeholder) worktrees.
# `ctree list free/used` and `ctree free` use this to detect whether a
# worktree is available.
# Example:
# free_branch_prefix: "FREE-"

# Keys in the source .env that ctree never prompts to delete from the
# worktree — even if absent from the source. Use for per-worktree keys
# that are intentionally different from the source.
# Example:
# skip_env_keys:
#   - SOME_KEY
```

### How to configure

1. Scaffold an annotated starting file by running from inside
   your source repo:

   ```bash
   ctree config add
   ```

   This writes `<source_repo>/.ctree/config.yml` with the shipped defaults
   verbatim (comments included). It refuses to overwrite an existing file
   without confirmation, so it's safe to run if you're unsure. Run
   `ctree config delete` to delete the file and its `.ctree` directory.

2. Edit the keys you want to change, and **remove the keys you want to
   leave at the shipped defaults** — anything you delete falls through to
   `lib/ctree/config.yml`. Example: a project that shares gems and
   node_modules and also syncs a lock file:

   ```yaml
   share_volumes:
     - gems
     - node_modules
   update:
     - Gemfile.plugins.lock
   ```

3. Commit `.ctree/config.yml` so collaborators on the same repo share the
   configuration.

### Behavior on errors

- **No `.ctree/config.yml`** → silent; uses shipped defaults.
- **Malformed YAML** or **non-mapping top level** → ctree warns to stderr
  and falls back to shipped defaults. The command continues.
- **Wrong type for a known key** (e.g. a string where a list is expected)
  → ctree exits with an error pointing at the offending key. Fix the file
  and re-run.

## Traefik / reverse-proxy domain routing

ctree sets two `.env` variables to give each worktree a unique routable domain:

| Variable | Set by | Value |
|---|---|---|
| `HOST_NAME` | ctree (always) | worktree name, e.g. `my-feature` |
| `HOST_NAME_SUFFIX` | ctree (when `host_name_suffix` is configured) | TLD, e.g. `docker` |

Together they form `${HOST_NAME}.${HOST_NAME_SUFFIX}` — e.g. `my-feature.docker` — which
your compose files can use in Traefik `Host()` rules and domain env vars.

### Per-repo setup

In your repo's `.ctree/config.yml`:

```yaml
host_name_suffix: docker   # written to HOST_NAME_SUFFIX in every worktree .env
```

Create a local compose override file (e.g. `docker-compose.local.ctree.yml`) that
references these variables:

```yaml
services:
  web:
    labels:
      - "traefik.http.routers.web.rule=Host(`myapp.${HOST_NAME}.${HOST_NAME_SUFFIX}`)"
    environment:
      APP_DOMAIN: myapp.${HOST_NAME}.${HOST_NAME_SUFFIX}
```

### Wiring up the override

ctree automatically appends the configured override file to `COMPOSE_FILE` in the
worktree's `.env` when the file exists in the source repo. No manual step required.

The source repo's `.env` and domain are left untouched — the override is only active
in worktrees, never in the source.

### How it works

- **Source repo:** `HOST_NAME` and `HOST_NAME_SUFFIX` are unset; existing routing is unchanged.
- **Worktrees:** ctree writes `HOST_NAME=<name>` and `HOST_NAME_SUFFIX=<tld>`; the override
  file's `Host()` rules resolve to unique per-worktree domains.
- All worktrees and the source share the same Traefik network without conflicts because
  each `Host()` rule resolves to a distinct value.

## Embedding ctree as a library

ctree is designed to be embedded by another CLI (for example an
[inst-cli](https://gerrit.instructure.com) plugin exposing it as
`inst canvas tree`). The contract:

**Entry points.** `require "ctree"`, then call the command modules
directly — `Ctree::Create.run(name:, branch:)`, `Ctree::Delete.run(name:)`,
`Ctree::List.run(filter:)`, `Ctree::Update.run`, `Ctree::Rebase.run`,
`Ctree::Free.run`, `Ctree::EnvCmd.run(subcommand)`,
`Ctree::ComposeConfigCmd.run(subcommand)`, and the `Ctree::Config`
module functions. `Ctree::CLI.run(argv)` exists for the standalone
binary; embedders should call the modules and do their own argument
parsing. Most commands assume `Dir.pwd` is the relevant repo top-level
and validate it themselves.

**Exceptions, never exits.** Nothing under `lib/` calls `Kernel#exit`.
Failures with a message raise `Ctree::Error` (carrying `exit_code`);
silent non-zero status exits (check discrepancies, partial failures)
raise `Ctree::ExitStatus`; success returns normally. `bin/ctree` is the
sole process-exit site. User-declined confirmations vary by command:
`update`, `rebase`, and `delete` print a line and raise `ExitStatus`
with code 1, `create`'s stop-source-containers decline raises
`Ctree::Error` (a message-bearing failure), while `free` and the
config-reset/removal prompts treat a decline as a no-op and return
normally — embedders must not assume "declined" always surfaces as a
non-zero status.

**UI backend.** All presentation flows through a swappable backend:
install one with `Ctree.ui_backend = your_backend`. The default
`Ctree::UI::PlainBackend` reproduces ctree's plain terminal output. A
backend implements:

| Method | Contract |
|---|---|
| `info(message)` / `warn(message)` / `debug(message)` | one status line; the backend owns any prefix or glyph |
| `line(text = "")` | verbatim output line (tables, summaries, data) |
| `section(title) { ... }` | titled block around the yielded body |
| `spin(message) { ... }` | spinner around the block; MUST return the block's value and re-raise its exceptions |
| `progress(message) { \|report\| ... }` | progress display; yields a callable taking a percent integer; same value/exception rules as `spin` |
| `group(title) { \|register\| ... }` | concurrent task display; see below |
| `read_line(prompt, prefixed: true)` | free-form prompt; `prefixed: false` marks a continuation line that should not be re-badged |

`group` renders many tasks running at once under one heading. It yields a
`register` callable that takes a label and a block; ctree registers every
task first, then the backend runs them, each block receiving a
percent-reporting callable exactly like `progress`:

```ruby
Ctree::Spinner.with_group("copying volumes", concurrency: 4) do |register|
  volumes.each do |volume|
    register.call("copying #{volume}") { |report_progress| copy(volume, report_progress) }
  end
end
# => one value per registered task, in registration order
```

A `group` implementation MUST return the task blocks' values in
registration order regardless of the order they finished, and MUST let
every task finish before re-raising the first exception any of them
raised — a task that fails must not strand its siblings. The backend owns
threading and rendering; **ctree owns how many tasks may work at once**,
via the `concurrency:` argument to `Ctree::Spinner.with_group`, which
makes each task wait for a permit inside its own block. A backend
therefore never needs to know about limits, and may start every
registered task at once. `PlainBackend` prints the title, then one line
per task as it completes, with no cursor animation — multi-line
animation is a rich backend's business.

Rules embedders must honor, and ctree code must keep honoring:

- `spin`/`progress`/`group` blocks MAY run on another thread. Never read
  thread-local state (`$?`, `Thread.current`) across the block boundary;
  return what you need as the block's value.
- A block value shaped `[stdout, stderr, status]` (an `Open3.capture3`
  triple) or a bare object responding to `success?` tells the backend
  whether to render the operation as failed.
- A capturing backend may defer output emitted inside
  `spin`/`progress`/`group` blocks until the spinner finishes. Avoid
  `Log` calls inside those blocks where ordering matters.
- `read_line` returns the entered line and may return `""` (not `nil`)
  on EOF under some backends; treat empty and nil alike.

## Development

```bash
bundle install
bundle exec rspec               # default suite (no docker required)
bundle exec rspec --tag docker  # opt-in real-docker integration tests
```

## License

MIT — see [LICENSE](LICENSE).
