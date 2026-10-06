# nix-config

Personal Home Manager configuration for macOS (Apple Silicon) and Linux (x86-64, ARM64).

## Included

- Shell and terminal: zsh, tmux, Neovim, Git, SSH, fzf, atuin
- Development: Node.js, Bun, Deno, Python, uv, Go, Rust, Cargo, GCC, Make
- CLI tools: gh, ripgrep, fd, bat, btop, lazygit, lazydocker, rclone, Wrangler, Cloudflared
- Apps: Pi, Claude Code, Lumen, Proton Pass CLI; Linux also gets Chromium and Google Chrome

## Install

One command, no arguments, no configuration:

```sh
curl -fsSL https://raw.githubusercontent.com/hattajr/nix-config/main/scripts/install.sh | sh
```

It shows what it is about to do, then asks before each step: installing Nix if
it is missing, cloning to `~/nix-config`, activating, configuring accounts,
and entering the managed shell. Declining any step leaves the machine unchanged.
The platform is detected from the machine and the destination is fixed, so there
is nothing to pass and nothing to set.

Installation needs a terminal. There is no unattended mode: every choice is a
prompt, and running without a terminal fails rather than guessing an answer.

### Everything else is one menu

```sh
bro
```

```text
  1) Apply        activate this checkout
  2) Sync         fast-forward from upstream, then apply
  3) Update       change pinned versions or update Pi extensions
  4) Accounts     configure logins and API keys
  5) Health       check shell, accounts, and PATH
  6) Clean up     quarantine binaries shadowing Nix
  7) Quit         leave the menu
```

`bro` takes no arguments and no flags. Choices that used to be flags, such as
pushing after a sync or showing a generated diff, are prompts inside the step
that needs them. A step that fails returns to the menu rather than ending the
session.

`Sync` makes a machine match the versions committed here. `Update` is the
intentional version-change workflow: it syncs first, asks what may change, shows
an old-to-new summary, then asks before applying, committing, and pushing. Other
machines receive the result with `Sync`.

`Update` offers Nixpkgs, Pi, Pi extensions, or everything. Nixpkgs and Pi are
pins in tracked files, so they go through that review-and-commit flow. Pi
extensions are the npm packages listed in `config/pi/agent/settings.json`, which
Pi installs into its own writable state; choosing them runs `pi update
--extensions` on this machine only and changes nothing in the repository, so
each machine updates them itself.

Pi updates also persist `home/modules/pi-package-lock.json`. If the npm tarball
ships no lockfile, the updater uses npm to resolve runtime dependencies with
install scripts disabled. This lockfile is reviewed, committed, or discarded
alongside the Pi version and Nix dependency hash.

### How ownership works

Home Manager is the sole owner of each configuration file it manages. Activation
replaces conflicting files at those managed leaves, including files previously
managed by Chezmoi, while preserving unrelated files in shared directories. A
colliding regular file or directory is moved under
`$XDG_STATE_HOME/home-manager/takeover/` before replacement; existing managed
symlinks are simply refreshed. The legacy `~/.gitconfig` is quarantined there
after `~/.config/git/config` is linked. Runtime state and secrets outside the
managed paths remain writable.

### Agent skills

| Source directory | Receives the skills |
| --- | --- |
| `config/agents/skills/` | Pi and Claude Code |
| `config/pi/agent/skills/` | Pi only |
| `config/claude/skills/` (create as needed) | Claude Code only |

**Create or share a skill:**
1. Ask Pi or Claude to create `config/agents/skills/<name>/SKILL.md` in this
   checkout, with `name` and `description` frontmatter. To share an existing
   local Pi skill, move its whole folder here from `~/.pi/agent/skills/`.
2. Run `git add config/agents/skills/<name>`, then `bro` → **Apply**.
3. Run `/reload` in Pi and restart Claude Code.

Home Manager links shared files into both `~/.pi/agent/skills/` and
`~/.claude/skills/`; no per-skill Nix edits are needed. Edit skills in this
checkout and Apply again—links are store-backed, not live checkout links.

Shared instructions must work in both agents; keep names unique and supporting
file paths relative. `grill-me` is shared; it uses each agent's question tool.
`design-md-import` and `web-browser` remain Pi-only. Unrelated local/synced
skills are preserved; colliding managed files are backed up as described above.

#### GitHub issue planning: triage and to-tickets

Three shared skills cover planning through implementation:

| Skill | Purpose |
| --- | --- |
| [`triage`](config/agents/skills/triage/SKILL.md) | Capture ideas, review the backlog, refine issues, and prepare approved briefs |
| [`to-tickets`](config/agents/skills/to-tickets/SKILL.md) | Split settled docs, conversations, or a large issue into approved vertical-slice tickets with blockers |
| [`implement-issues`](config/agents/skills/implement-issues/SKILL.md) | Implement an eligible issue or a safe ready batch and deliver a reviewed PR |

Pi uses `/skill:<name>`; Claude Code uses `/<name>`. Natural-language requests
also work. Both planning skills require authenticated `gh`, use GitHub-only
issue persistence, and ask for approval before publishing or changing briefs,
labels, dependencies, or parent tracking. No upstream setup skill is required.
If a repository lacks the necessary labels, the agent proposes minimal label
creation for your approval instead of silently configuring the repository.

**Planning commands:**

| Task | Pi | Claude Code |
| --- | --- | --- |
| Show issues needing attention | `/skill:triage` | `/triage` |
| Capture an idea only | `/skill:triage capture PDF export; don't refine it yet` | `/triage capture PDF export; don't refine it yet` |
| Refine an existing issue | `/skill:triage #42` | `/triage #42` |
| Review an unlabeled backlog | `/skill:triage review my backlog for readiness` | `/triage review my backlog for readiness` |
| List ready work and blockers | `/skill:triage what's ready?` | `/triage what's ready?` |
| Split a fresh app's design | `/skill:to-tickets docs/` | `/to-tickets docs/` |
| Split a large existing issue | `/skill:to-tickets #58` | `/to-tickets #58` |

**Workflow variants (skill sequence):**

| Situation | Sequence and result |
| --- | --- |
| Fresh app designed in `docs/` | Optional `grill-me` for design gaps → `to-tickets docs/` → approve breakdown/publication → `implement-issues` |
| Capture an idea for later | `triage capture …` → approve publication → `needs-triage`; stop here, no grilling or implementation |
| Refine that idea later | `triage #42` → `grill-me` only if decisions remain → approve the brief → `ready-for-agent` → `implement-issues #42` |
| Discuss a new, small feature | `grill-me` → confirm shared understanding → `triage create an issue from this discussion` → approve publication → `implement-issues #N` |
| Discuss a larger feature | `grill-me` → `to-tickets` using the settled conversation → approve slices/dependencies/publication → `implement-issues` |
| Clear bug report | `triage` with the report or existing issue → investigate/reproduce → approve regression criteria and brief → `implement-issues #N`; no mandatory grilling |
| Oversized existing issue | Optional `triage #58` for unresolved scope → `to-tickets #58` → approve child tickets and parent tracking → `implement-issues`, not `implement-issues #58` |
| Existing issues lack readiness labels | `triage review my backlog for readiness` → approve per-issue briefs/state changes → `implement-issues`; never bulk-label vague ideas ready |

During refinement, `triage` reads and follows `grill-me` when needed, then returns
to preparing the brief—you do not have to manually switch skills at every step.
If you stop halfway, ask it to save established decisions and remaining questions
on the issue; unfinished grilling does not earn `grilled`. If a request is too
large, it recommends `to-tickets` rather than making an umbrella executable.
Neither planning skill automatically starts implementation.

**Labels:** `needs-triage` means evaluation is unfinished; `needs-info` means
specific answers are awaited; `ready-for-agent` means the implementation brief
is approved and complete. `grilled` is an optional completed-discussion marker,
not the implementation gate. Approved doc-derived tickets and clear bugs can be
ready without it. A ready ticket can still be blocked: `implement-issues` checks
prerequisite completion, claims, and concurrency against current code.

The approved issue body is the durable brief: current/desired behavior,
constraints, acceptance criteria, validation, non-goals, blockers, and design
references. Comments preserve investigation and progress, not a competing spec.
`to-tickets` prefers complete vertical slices over database/backend/UI phases,
links real GitHub blockers, and keeps split parents out of the execution queue
only with your approval. It never automatically closes a parent.

#### Implement GitHub issues

The shared [`implement-issues`](config/agents/skills/implement-issues/SKILL.md)
skill turns approved GitHub issues into a reviewed PR. It requires a matching
Git checkout and an authenticated `gh` CLI. Activate it with `bro` → **Apply**,
then `/reload` in Pi or restart Claude Code.

| Task | Pi | Claude Code |
| --- | --- | --- |
| Select a ready batch | `/skill:implement-issues` | `/implement-issues` |
| Implement only #42 | `/skill:implement-issues #42` | `/implement-issues #42` |

Full issue URLs and `owner/repo#42` references are also accepted, provided the
checkout matches that repository. Natural language works too: “Implement ready
GitHub issues in parallel.”

**Prepare an issue:** settle its goal, desired behavior, acceptance criteria,
constraints, non-goals, and blockers in an approved issue brief, then apply
`ready-for-agent`. Use `grill-me` first when decisions need discussion.
`grilled` records completed discussion; it neither replaces readiness nor is
required for a clearly specified bug. Idea dumps without an approved brief
remain outside the implementation queue.

**What a run does:**
1. Read issue bodies, comments, referenced design docs, and current code.
2. Without a target, select one safe batch of up to three open, unclaimed
   `ready-for-agent` issues, oldest eligible first. With a target, select only
   that issue—never automatically implement its blockers, children, or parent.
3. Check that blockers are actually satisfied in the PR base branch and that
   selected issues can coexist without conflicting contracts or edits.
4. Claim the issues on GitHub, then implement with one writer per isolated
   worktree. Run fewer workers when necessary, or execute serially when safe
   delegation is unavailable.
5. Integrate successful work, run behavior-focused validation, and independently
   review the combined diff. Resolve material findings within approved scope.
6. Push a new integration branch, open one PR for the successful batch, and post
   validation/review evidence and the PR link on its issues.

**Boundaries:** GitHub owns tickets, claims, decisions, and progress; `docs/`
holds durable design documentation. There is no local `PLANS/`, issue mirror,
status table, or dependency on the old `/build`. Temporary worktrees and runtime
logs are execution resources, not another backlog. The skill is adapted from
Matt Pocock's `implement-spec` approach; his entire skill collection is not
required. The shared `triage` and `to-tickets` skills above prepare the backlog
for this implementation step.

Missing decisions or unsatisfied dependencies stop the affected issue rather
than triggering guesses or scope expansion. Missing required validation or
independent review means a draft PR, not a ready-for-review success. Issues
remain open and claimed while awaiting merge; the skill never merges PRs,
enables auto-merge, deploys, or closes issues early. Each invocation stops after
its selected batch rather than draining the backlog. Partial work is preserved
with recovery pointers when delivery fails.

### Manual macOS ownership

Browsers on macOS are intentionally installed and updated manually. Home Manager does not install Chrome or take ownership of browser profiles. Tailscale and Proton split DNS are external host state on every platform: install Tailscale through its signed system package repository, then enable and maintain it through the host tools. The managed `devtunnel` command defaults to the `mbp` SSH hostname and only uses ordinary SSH forwarding. The managed SSH client is the GSSAPI build, because hosts such as Ubuntu set `GSSAPIAuthentication` in `/etc/ssh/ssh_config` and a client built without that keyword warns on every connection.

### Identity

Home Manager uses the active user's `$USER` and `$HOME`, so it works for arbitrary local account names. Identity is read from the account itself and cannot be set by hand.

The flake itself stays pure: it never reads the environment during evaluation. The menu and the installer resolve the identity in the shell and pass it to the `lib.mkHome` builder as an explicit argument, so any account can be activated without committing it. The owner's own configurations are also committed, keyed by system (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`) rather than by `user@host`, which keeps `nix flake check` and evaluation caching working and survives a host being renamed or replaced.

For direct Nix use outside the menu, the attribute is a system rather than `$USER@$(hostname)`, so it must be named explicitly:

```sh
home-manager switch --flake ~/nix-config#x86_64-linux
nix build ~/nix-config#homeConfigurations."x86_64-linux".activationPackage

# any other account, without editing the flake
nix build --impure --expr '
let
  source = builtins.path {
    path = "'"$PWD"'";
    name = "nix-config-source";
    filter = path: type: builtins.baseNameOf path != ".git";
  };
  flake = builtins.getFlake
    (builtins.unsafeDiscardStringContext "path:${source}");
in
(flake.lib.mkHome {
  system = "x86_64-linux"; username = "alice"; homeDirectory = "/home/alice";
}).activationPackage'
```

## Shadowed binaries

`~/.local/bin` deliberately outranks `~/.nix-profile/bin` on PATH so that the
wrappers this repository installs there, such as `pi` and `vim`, take
precedence over the packages they wrap. A tool installed by hand into the same
directory inherits that precedence and silently shadows its Nix-managed
counterpart, which is how a stale `uv` keeps running after Nix ships a newer one.

Every activation reports such files and never blocks on them:

```
warning: 2 unmanaged binaries are shadowing the Nix profile (rclone uv).
         Run bro and choose Clean up to review them.
```

`Health` reports the same finding as `PATH WARN` and offers to review it there
and then, and `Clean up` goes straight to the review. It stays a warning rather
than a failure: a hand-installed tool in `~/.local/bin` is common enough that
failing on one would break a first install.

Reviewing walks each finding one at a time. Files move under
`$XDG_STATE_HOME/home-manager/shadowed/` and are never deleted, so a tool kept
on purpose can be restored from there.

Symlinks into the Nix store are this repository's own wrappers and are never
reported. Tools that update themselves into the user profile, currently
`claude`, are expected to outrank the Nix copy and are listed in
`allowedShadows` in `home/modules/shadowed-binaries.nix`.

## Multipass validation

Install Multipass, then run the full integration suite in a disposable Ubuntu VM:

```sh
make multipass-validation
```

The suite launches Ubuntu 24.04, copies only tracked and non-ignored project files into the VM, and runs the public curl installer against that local fixture. It then validates the generated Home Manager activation, idempotence, managed tools, shell startup, Neovim, and credential-free bootstrap tests. The VM is deleted on exit.

Set `MULTIPASS_VALIDATION_IMAGE` to select another Ubuntu image.

### Interactive Multipass testing

To manually test the current working tree without pushing it, run:

```sh
make test-interactive
```

To discard the persistent guest and launch a brand-new Ubuntu VM, use:

```sh
make test-interactive-new
```

`test-interactive` launches (or reuses) a persistent Ubuntu 24.04 VM, mounts the working tree, converts its tracked and non-ignored files—including uncommitted changes—into a local Git fixture, installs the prerequisites, and opens a shell. Run it from a regular host terminal rather than an embedded command pane; the launcher clears any outer `TMUX` value so tmux can start normally in the guest. Follow the displayed local-source installer command. After host edits, run `make test-interactive` again and rerun that installer command to refresh the fixture and activation. The VM remains available until you delete it:

```sh
multipass delete --purge nix-config-interactive-$USER
```

Set `MULTIPASS_INTERACTIVE_IMAGE` or `MULTIPASS_INTERACTIVE_INSTANCE` to override the image or VM name.
