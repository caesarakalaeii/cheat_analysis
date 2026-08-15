{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "cheat_analysis -- Python script that scrapes an SQLite database for stochastic analysis. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the other forty, and a
  # hardcoded system list this repo cannot edit. That list is currently broken:
  # it still contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'flake-utils'".
    # `self` is destructured because rootPreamble needs this flake's own source
    # path -- see the comment there for why nothing else can supply it.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need. `nix flake check` realises this
      # closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # cheat_analysis.py imports sqlite3, os.path and traceback -- standard
      # library only, with sqlite3 already linked into the nixpkgs interpreter.
      # So there is nothing to install and no `setup` verb: this shell is fully
      # offline-capable as it stands. uv is here for the moment that stops being
      # true (the README promises "stochastic analysis" that is not written yet,
      # so a numpy/pandas dependency is the likely next commit); see the note on
      # nativeLibs before adding a wheel-based dependency.
      #
      # Pin the interpreter by MAJOR (python313), never by rolling alias
      # (python3): an alias that moves under us invalidates every .venv in the
      # fleet on the same afternoon, and the current default is already 3.14
      # territory, where many pinned deps have no wheels.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.python313
        pkgs.uv
        pkgs.ruff

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty, and honestly so: this repo has no third-party dependencies at all,
      # so nothing here dlopens a .so that NixOS has no /usr/lib to find it in.
      # An empty list makes ldPreamble below a no-op, which leaves the ambient
      # LD_LIBRARY_PATH completely untouched -- the right default.
      #
      # The moment someone installs a manylinux wheel into a .venv here (numpy,
      # pandas, scipy -- all plausible for the "stochastic analysis" half of this
      # script), add pkgs.stdenv.cc.cc.lib -- it supplies the libstdc++ whose
      # absence is exactly the `libstdc++.so.6: cannot open shared object file`
      # on `import numpy` -- and pkgs.zlib. Keep the list minimal even then;
      # LD_LIBRARY_PATH is a blunt instrument.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # Keep uv on the nix interpreter. Left alone it downloads its own
        # portable CPython, which then resolves a different set of wheels than
        # this shell pins: two Pythons, one venv, no way to tell which is live.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        UV_PYTHON_DOWNLOADS = "never";
        # /nix/store and the work tree are usually different filesystems, so
        # uv's default hardlink strategy warns on every single install.
        UV_LINK_MODE = "copy";
        PIP_DISABLE_PIP_VERSION_CHECK = "1";
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
      # verb the repo has no meaning for is OMITTED rather than stubbed, because
      # absence is information and a stub that echoes "not applicable" turns the
      # command map into a liar. So, for this repo:
      #
      #   no `setup` -- standard library only, nothing to install (see toolchain)
      #   no `build`  -- a single script, there is no artifact to produce
      #   no `test`   -- there are no tests in the tree, and inventing a
      #                  `pytest` verb that collects zero items would report
      #                  green forever
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time. Two
      # rules, and the first one is the whole ballgame:
      #
      #   1. ANCHOR EVERY PATH TO $REPO_ROOT. A verb must do the same thing from
      #      any working directory and must never read or write one file outside
      #      this repo, so every path argument defaults to $REPO_ROOT:
      #      `"''${@:-$REPO_ROOT}"`. Ending at a bare "$@" leaves the tool to
      #      supply its own default, and every default here is `.` -- which is
      #      the CALLER's directory, not ours. That is not theoretical: with a
      #      bare "$@", `nix run /path/to/repo#lint` (the flake-URL form CI and
      #      a cold agent use) from an unrelated directory printed "All checks
      #      passed!" having inspected zero of this repo's files while the same
      #      verb exited 1 from inside the tree, and `nix run /path/to/repo#fmt`
      #      REWROTE whatever Python was sitting in the caller's directory.
      #   2. Quote the expansion. Unquoted $@ fails the build with SC2068, and
      #      "''${@:-$REPO_ROOT}" keeps a path containing a space one argument.
      #
      # Explicit arguments are still forwarded verbatim and still resolve
      # against the caller's cwd, because the default only fires when $# is 0.
      commands = pkgs: {
        lint = {
          description = "ruff check";
          # --no-cache is not a speed knob, it is part of the anchoring. ruff
          # derives .ruff_cache from its OWN cwd and never from the paths it was
          # handed, so an anchored `nix run /path/to/repo#lint` still dropped a
          # .ruff_cache into the caller's tree -- a write outside the repo,
          # which is the thing we are here to stop. Pointing that cache at the
          # store snapshot instead does not degrade, it aborts the run:
          #   error: Failed to initialize cache at /nix/store/...-source/.ruff_cache:
          #   Read-only file system (os error 30)
          # This tree is one 616-byte file; the cache saves nothing measurable.
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          # The only mutating verb, so the only one that refuses to guess. With
          # no arguments it formats $REPO_ROOT -- and when that is the read-only
          # store snapshot (nobody invoked us from a checkout, see rootPreamble)
          # there is nothing there that CAN be rewritten. Say so in one line,
          # rather than letting ruff surface a permission-denied on /nix/store
          # and leaving the reader to work out which directory it meant.
          # Explicit paths are the caller's business, so they skip the guard.
          text = ''
            if [ "$#" -eq 0 ] && [ ! -w "$REPO_ROOT" ]; then
              echo "dev-fmt rewrites files in place, so it needs a writable checkout." >&2
              echo "REPO_ROOT is $REPO_ROOT -- this flake's read-only store snapshot," >&2
              echo "so there is nothing here to format. Run dev-fmt from inside a" >&2
              echo "checkout of this repo, or pass the paths to format explicitly." >&2
              exit 1
            fi
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
        run = {
          # WARNING for agents: this script is interactive by design -- it calls
          # input() in a loop for the database path and then for the object ids.
          # There is no batch flag to pass because there are no CLI arguments to
          # pass it to, so with an idle stdin this WILL sit there until the
          # harness times out. Feed it, e.g.
          #   printf 'game.db\n1 2 3\n' | nix run .#run
          # A closed stdin is the other safe option: it raises EOFError and exits
          # non-zero rather than hanging.
          #
          # `python3` unqualified is correct here, unusually for this fleet:
          # there is no .venv to miss, so the store interpreter the wrapper
          # prepends is the only one and both surfaces agree.
          #
          # The script path was already spelled through $REPO_ROOT, but that was
          # not enough while $REPO_ROOT itself was derived from the caller's cwd:
          # from an unrelated directory this died with
          # "can't open file '/somewhere/else/cheat_analysis.py'". It is honest
          # now because rootPreamble is.
          description = "run the analysis script (prompts on stdin -- pipe input or it blocks)";
          text = ''python3 "$REPO_ROOT/cheat_analysis.py" "$@"'';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT, and every verb above anchors its paths to
      # it, so $REPO_ROOT has to mean THIS repo from every possible cwd.
      #
      # It used to be `git rev-parse --show-toplevel || pwd`, which is a question
      # about the CALLER, not about us: run from an unrelated directory it
      # answered with the caller's tree (or, outside git, literally `pwd`), and
      # the mutating verb then rewrote files there. A wrapper sitting in the
      # store cannot ask where the user's checkout is, so the answer is baked in
      # at build time and the work tree is only an opt-in refinement:
      #
      #   1. ${self} -- the copy of this flake's source that nix necessarily
      #      already made in the store to evaluate this file. Read-only, always
      #      present, unambiguously this repo, and correct for the cold
      #      `nix run /path/to/repo#lint` that CI and a fresh agent run.
      #   2. the caller's git work tree, but only when it is a checkout of this
      #      same repo. That is the `nix develop` / `nix run .#fmt` case, whose
      #      whole point is linting and formatting edits that are not committed
      #      yet, in place, in the files the author is actually looking at.
      #
      # "same repo" is decided by comparing flake.nix byte for byte, and
      # deliberately erring strict: a false positive means writing into a
      # stranger's tree, a false negative only means working on the snapshot.
      # Nix copies a dirty work tree into the store as it stands, so an
      # uncommitted edit to a tracked flake.nix still compares equal to itself.
      # `$(<f)` is a bash redirect rather than cat: no process, and nothing extra
      # required on PATH.
      #
      # Still no `cd`: with every path anchored there is nothing left for a cd to
      # fix, and keeping the caller's cwd is what lets a relative path in an
      # explicit argument (`dev-lint ./scratch.py`) still mean what was typed.
      #
      # Two prices, both paid knowingly. Referencing ${self} makes the source a
      # dependency of the wrappers, so touching any tracked file rebuilds the
      # three of them -- writeShellApplication plus shellcheck, a second or two.
      # And a stale `nix develop` whose flake.nix has since been edited stops
      # matching the work tree and falls back to its own snapshot; re-enter the
      # shell, which you owe it anyway once the command map has changed. Nothing
      # above is specific to this repo, so this block stays fleet-generic.
      rootPreamble = ''
        FLAKE_ROOT=${lib.escapeShellArg self}
        REPO_ROOT="$FLAKE_ROOT"
        if worktree="$(git rev-parse --show-toplevel 2>/dev/null)" &&
          [ -f "$worktree/flake.nix" ] &&
          [ "$(<"$worktree/flake.nix")" = "$(<"$FLAKE_ROOT/flake.nix")" ]; then
          REPO_ROOT="$worktree"
        fi
        export REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
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
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

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

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `npm install`, no `dotnet restore`, no `read`, no `exec $SHELL`.
            # Bootstrapping in the hook makes a cold `nix develop -c pytest`
            # start downloading before it runs anything, on EVERY invocation --
            # the exact failure an unattended agent cannot diagnose. That is what
            # `dev-setup` is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "cheat_analysis dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';

        # Regression test for the anchoring, which is worth a derivation because
        # the bug it guards against was invisible from inside the repo: every
        # verb inherited the caller's cwd, so lint reported success over zero
        # files and fmt rewrote sources that belonged to somebody else. The build
        # sandbox is the ideal stranger's directory -- /build is not a git tree
        # and contains nothing of ours -- so the assertion is simply that the
        # verbs neither touch nor even mention what is sitting in it. Asserting
        # exit codes instead would be a fake check: lint legitimately exits 1
        # while cheat_analysis.py still has findings.
        anchoring =
          pkgs.runCommand "anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              printf 'import os,sys\nx=1\n' > decoy.py
              cp decoy.py decoy.expected

              dev-fmt > fmt.out 2>&1 || true
              cmp decoy.py decoy.expected || {
                echo "dev-fmt rewrote a file in the caller's directory:" >&2
                cat fmt.out >&2
                exit 1
              }

              dev-lint > lint.out 2>&1 || true
              if grep -q decoy.py lint.out; then
                echo "dev-lint inspected the caller's directory:" >&2
                cat lint.out >&2
                exit 1
              fi

              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
