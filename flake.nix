{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "cheat_analysis -- one Python script that opens an SQLite database and reads object ids from stdin; the stochastic analysis it is named for is not written yet. Run `nix flake show` for the command map.";

  # nixpkgs is the only input. eachDefaultSystem is the one thing flake-utils
  # would add here, and the canonical block below already defines it as
  # `forAllSystems`, so a second input would buy nothing.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: with a closed pattern,
    # adding a second input later fails with (measured, on a scratch flake)
    # `error: function 'outputs' called with unexpected argument 'dep'`.
    # `self` is mandatory -- the canonical block anchors $SRC_ROOT on it, and
    # without it this flake does not evaluate at all.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 0 -- identity
      # ======================================================================
      # Cosmetic: the canonical block reads it in exactly one place, the
      # interactive dev-shell banner. It still has to be right, because that
      # banner is how a human tells two open shells apart.
      repoName = "cheat_analysis";

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need on PATH. `nix flake check` realises
      # this closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task -- measured by
      # misspelling one: `error: attribute 'rufff' missing`.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports only `error: undefined variable
      # 'nosuchattr'` (measured on `nix eval --expr 'with { a = 1; }; nosuchattr'`)
      # -- no hint of which set it came from, and the name is not greppable.
      #
      # cheat_analysis.py imports sqlite3, os.path and traceback -- standard
      # library only, and sqlite3 is already linked into the nixpkgs
      # interpreter (`import sqlite3` answers 3.53.3 here). So there is nothing
      # to install and no `setup` verb, and no verb below touches the network,
      # which is why none of their descriptions carries a `(network)` marker.
      # uv is on PATH for the first third-party dependency; the tree has no
      # requirements.txt and no pyproject.toml today, so nothing uses it yet.
      #
      # Pin the interpreter by MAJOR (python313), never by rolling alias
      # (python3): the alias moves with nixpkgs, and at the rev this flake
      # locks it has already moved -- `pkgs.python3.name` is python3-3.14.7
      # there, while `pkgs.python313.name` is python3-3.13.15 (both measured
      # against flake.lock). Writing `python3` would therefore hand this repo a
      # different interpreter than the one every verb here was tested on.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.python313
        pkgs.uv
        pkgs.ruff

        # ---- not invoked by any verb below ----
        # The canonical anchor is pure bash builtins, so not even it needs git.
        # These three are carried over from the toolchain this flake already
        # shipped: this pass converges the machinery, it does not re-litigate
        # the toolchain.
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty, and honestly so: the script imports the standard library only,
      # so nothing here dlopens a .so that NixOS has no /usr/lib to find it in.
      # An empty list makes the canonical ldPreamble emit nothing at all, and
      # that is measured, not assumed: with LD_LIBRARY_PATH=/sentinel/path in
      # the environment, `nix develop -c` sees exactly /sentinel/path, and the
      # generated dev-lint wrapper contains no occurrence of the name at all.
      #
      # The moment a manylinux wheel lands in a .venv here, pkgs.stdenv.cc.cc.lib
      # is the usual first entry: at the locked rev its lib/ carries
      # libstdc++.so.6, whose absence is exactly the `libstdc++.so.6: cannot
      # open shared object file` on `import numpy`. Linux-only attrs are safe
      # in this list -- the canonical block only forces it on Linux.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. This attrset is applied to BOTH surfaces -- the dev
      # shell and every `nix run` wrapper -- so a command cannot behave
      # differently depending on how it was invoked. Anything that must READ an
      # existing value (LD_LIBRARY_PATH) or UNSET one (SOURCE_DATE_EPOCH) is
      # the canonical block's business, not this attrset's.
      envVars = pkgs: {
        # Keep uv on the nix interpreter. Measured in an empty directory: with
        # UV_PYTHON set, `uv venv` reports "Using CPython 3.13.15 interpreter
        # at: /nix/store/...-python3-3.13.15/bin/python"; with it unset, the
        # same command builds the venv from a managed CPython under
        # ~/.local/share/uv/python instead. Two interpreters, one venv, no way
        # to tell which one is live.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        # `uv help python` documents this exact spelling as the environment
        # form of --no-python-downloads: [env: "UV_PYTHON_DOWNLOADS=never"].
        UV_PYTHON_DOWNLOADS = "never";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#run`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-lint` actually runs.
      #
      # Fixed house vocabulary -- setup, build, test, lint, fmt, run -- and a
      # verb the repo has no meaning for is OMITTED rather than stubbed,
      # because absence is information and a stub that echoes "not applicable"
      # turns the command map into a liar. So, for this repo:
      #
      #   no `setup` -- standard library only, nothing to install
      #   no `build` -- a single script, there is no artifact to produce
      #   no `test`  -- the tree contains exactly one Python file
      #                 (cheat_analysis.py) and no test of any kind, so a
      #                 pytest verb collecting zero items would report green
      #                 forever
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time.
      # Two rules, and the first one is the whole ballgame:
      #
      #   1. ANCHOR EVERY PATH TO $REPO_ROOT, which the canonical block below
      #      resolves to this repo from any cwd. A bare trailing "$@" expands
      #      to nothing when there are no arguments and leaves the tool to
      #      supply its own default -- and ruff's default is `.`, the CALLER's
      #      directory, not ours.
      #   2. Quote the expansion. Unquoted $@ fails the build (measured: the
      #      dev-lint derivation dies on `SC2068 (error): Double quote array
      #      expansions to avoid re-splitting elements`), and
      #      "''${@:-$REPO_ROOT}" keeps a path containing a space one argument.
      #
      # Explicit arguments are still forwarded verbatim and still resolve
      # against the caller's cwd, because the default only fires when $# is 0.
      commands = pkgs: {
        lint = {
          description = "ruff check";
          # --no-cache is not a speed knob, it is part of the anchoring.
          # Measured: ruff derives .ruff_cache from its OWN cwd and never from
          # the paths it was handed, so `ruff check /elsewhere` run from an
          # empty directory dropped a .ruff_cache into that directory -- a
          # write outside the repo, which is the thing this flake exists to
          # stop. Pointing the cache at $REPO_ROOT does not degrade when that
          # is the store snapshot, it aborts the run (measured):
          #   error: Failed to initialize cache at /nix/store/...-source/.ruff_cache:
          #   Read-only file system (os error 30)
          # The only Python file in this tree is 616 bytes; a cache saves
          # nothing measurable here.
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          # The only mutating verb, so the only one that refuses to guess. With
          # no arguments it targets $REPO_ROOT, and when nobody invoked us from
          # a checkout that is this flake's read-only store snapshot -- nothing
          # there CAN be rewritten. need_writable_checkout says so in a message
          # naming both $PWD and the store path, rather than letting ruff
          # surface a permission error on /nix/store and leaving the reader to
          # work out which directory it meant. Explicit paths are the caller's
          # own business -- the guard's own message names them as the escape
          # hatch -- so they skip it.
          text = ''
            if [ "$#" -eq 0 ]; then
              need_writable_checkout
            fi
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
        run = {
          # WARNING for agents: this script is interactive by design -- it
          # loops on input() for the database path until os.path.isfile()
          # accepts one, then asks once more for the object ids. There is no
          # batch flag to pass because the script reads no CLI arguments at
          # all, so with an idle stdin this WILL sit there until the harness
          # times out. Feed it, e.g.
          #   printf 'game.db\n1 2 3\n' | nix run .#run
          # with game.db in the cwd you launched from (the script resolves a
          # relative path against that cwd, not against $REPO_ROOT). Measured:
          # that exits 0 and prints the two prompts and nothing else, because
          # the analysis half of the script is not written yet. A closed stdin
          # is the other safe option: measured, EOFError at the first prompt
          # and exit 1, rather than a hang.
          #
          # `python3` unqualified is safe here: there is no .venv to miss, and
          # writeShellApplication puts the toolchain ahead of the caller's PATH
          # -- measured by putting a rogue `python3` first in PATH and running
          # this verb anyway, which still reached the pinned interpreter.
          #
          # "$@" is forwarded although the script ignores argv today, so that
          # it is not this wrapper that has to change when that stops.
          description = "run the analysis script (prompts on stdin -- pipe input or it blocks)";
          text = ''python3 "$REPO_ROOT/cheat_analysis.py" "$@"'';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 5 -- checks beyond the canonical two
      # ======================================================================
      # The canonical `anchoring` check proves the MECHANISM (rootPreamble and
      # guardPreamble) behaves. It cannot prove that THIS repo's verbs call it,
      # because it knows nothing about them. This one does exactly that, and
      # the failure it guards against is measurable in one line: an unanchored
      # verb hands ruff its own default of `.`, and in a foreign directory
      # `ruff check --no-cache` then printed "All checks passed!" and exited 0
      # having read none of this repo, while `ruff format --no-cache` in the
      # same directory reformatted the file sitting there.
      #
      # No exit codes are asserted: dev-lint legitimately exits 1 today (I001
      # and E722 in cheat_analysis.py) and would flip to 0 the day someone
      # fixes them, which would turn good news into a failing check. What is
      # asserted is what got READ and what got WRITTEN.
      extraChecks = pkgs: {
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check" { nativeBuildInputs = lib.attrValues (wrappers pkgs); }
            ''
              set -euo pipefail

              # A decoy carrying the marker files a naive Python anchor would
              # accept, plus one filename this repo does NOT contain.
              mkdir decoy
              cd decoy
              printf 'import os\nx  =1\n' > bot.py
              printf 'import json\ny  =2\n' > sibling_only.py
              printf 'requests\n' > requirements.txt
              printf '{ description = "a different repo"; outputs = _: { }; }\n' > flake.nix
              cp -r . ../decoy.orig

              # Grep by NAME, not by directory: if the anchor wrongly lands on
              # the decoy, ruff is also standing in it and prints paths
              # relative to it, so a grep for "decoy" matches nothing and the
              # leak sails through. A filename this repo does not contain is
              # the thing that cannot be spelled both ways.
              dev-lint > lint.log 2>&1 || true
              if grep -q sibling_only lint.log; then
                echo "dev-lint graded the decoy" >&2
                cat lint.log >&2
                exit 1
              fi
              # ...and it must have graded SOMETHING: a verb that read nothing
              # at all also passes the test above.
              if ! grep -q ${lib.escapeShellArg "${self}"} lint.log; then
                echo "dev-lint graded neither the decoy nor this repo" >&2
                cat lint.log >&2
                exit 1
              fi

              # Refusal, not silence -- and refusal by the guard specifically.
              # Measured: deleting the need_writable_checkout call from dev-fmt
              # still leaves this build green without the second test, because
              # ruff then aborts by itself on the read-only store path. Same
              # exit code, no damage, but the actionable message is gone, so
              # the wording is what has to be asserted.
              if dev-fmt > fmt.log 2>&1; then
                echo "dev-fmt succeeded in a foreign tree; it must refuse" >&2
                cat fmt.log >&2
                exit 1
              fi
              if ! grep -q "needs a writable" fmt.log; then
                echo "dev-fmt failed, but not by calling need_writable_checkout" >&2
                cat fmt.log >&2
                exit 1
              fi

              # `*.log`, and every log file here must match it -- a file named
              # plainly `log` would not be excluded and would fail this diff.
              diff -r --exclude='*.log' . ../decoy.orig
              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
