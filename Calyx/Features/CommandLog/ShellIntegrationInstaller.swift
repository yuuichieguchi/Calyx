// ShellIntegrationInstaller.swift
// Calyx
//
// Installs Calyx's own zsh/fish command-lifecycle shell integration
// scripts into a Calyx-owned directory tree -- never a user rc file (the
// command-log plan's explicit "the user's own rc files are never edited"
// constraint). CalyxShellIntegrationEnvironment points ZDOTDIR /
// XDG_DATA_DIRS at this installed tree; the scripts themselves relay the
// user's own shell startup chain back through afterward (see
// zshenvBody's own doc comment for the exact zsh ZDOTDIR relay this
// mirrors, verified against ghostty's own bundled `.zshenv`).

import Foundation

enum ShellIntegrationInstaller {

    /// Default install root: `~/Library/Application Support/Calyx/shell-integration`.
    /// Mirrors AgentHookScript.defaultInstallDirectory's shape (a
    /// subdirectory of AgentEndpointFile.defaultDirectory).
    static var defaultInstallDirectory: URL {
        URL(fileURLWithPath: AgentEndpointFile.defaultDirectory)
            .appendingPathComponent("shell-integration")
    }

    /// Installed at `<root>/zsh/.zshenv`. Sourced automatically by zsh
    /// itself once ZDOTDIR points at `<root>/zsh` -- either directly (no
    /// ghostty integration active) or via ghostty's own bundled
    /// `.zshenv` restoring ZDOTDIR here first. Responsible for: (1)
    /// restoring ZDOTDIR to the user's own original value from
    /// CALYX_ZSH_ZDOTDIR (existence-checked, not merely non-empty --
    /// unset means fall back to $HOME), (2) sourcing calyx.zsh (hook
    /// registration) from its own script directory when interactive,
    /// and (3) always sourcing the user's real `.zshenv` from the
    /// now-restored ZDOTDIR/$HOME, so the user's own dotfiles chain
    /// resumes exactly as if Calyx were never involved.
    ///
    /// Modeled directly on ghostty's own bundled `.zshenv`
    /// (`Resources/ghostty/shell-integration/zsh/.zshenv`, read-only
    /// reference -- never modified) with `GHOSTTY_ZSH_ZDOTDIR` swapped
    /// for `CALYX_ZSH_ZDOTDIR` and `ghostty-integration` swapped for
    /// `calyx.zsh`. Quoted throughout (`'builtin' 'export' ...`) for the
    /// same reason ghostty's own file is: this can be sourced with
    /// aliases enabled, and quoting survives that. The try/always roles
    /// are swapped relative to ghostty's file: ghostty's `try` sources
    /// the user's `.zshenv` (a real dependency -- `ghostty-integration`
    /// needs `fpath` etc. the user's file may set) with `ghostty-
    /// integration` itself only in the `always` block; `calyx.zsh` has
    /// no such dependency on the user's `.zshenv`, so it's the `try`
    /// step here, with sourcing the user's real `.zshenv` moved to
    /// `always` -- guaranteeing that step runs even if `calyx.zsh`
    /// itself errors, so an error in the Calyx script never breaks the
    /// user's own shell startup chain.
    static let zshenvBody = """
    if [[ -n "${CALYX_ZSH_ZDOTDIR+X}" ]]; then
        'builtin' 'export' ZDOTDIR="$CALYX_ZSH_ZDOTDIR"
        'builtin' 'unset' 'CALYX_ZSH_ZDOTDIR'
    else
        'builtin' 'unset' 'ZDOTDIR'
    fi

    {
        if [[ -o 'interactive' ]]; then
            # ${(%):-%x} is the path to the current file (this .zshenv);
            # :A:h resolves symlinks and takes its directory, so
            # calyx.zsh is found regardless of how this file itself was
            # reached (mirrors ghostty's own %x:A:h idiom).
            'builtin' 'typeset' _calyx_file="${${(%):-%x}:A:h}"/calyx.zsh
            [[ ! -r "$_calyx_file" ]] || 'builtin' 'source' '--' "$_calyx_file"
            'builtin' 'unset' '_calyx_file'
        fi
    } always {
        # Zsh treats unset ZDOTDIR as if it were $HOME; we do the same.
        # Zsh ignores unreadable rc files, and rc files that are
        # directories -- so does source. Use typeset in case we're in a
        # function with warn_create_global in effect.
        'builtin' 'typeset' _calyx_user_zshenv=${ZDOTDIR-$HOME}"/.zshenv"
        [[ ! -r "$_calyx_user_zshenv" ]] || 'builtin' 'source' '--' "$_calyx_user_zshenv"
        'builtin' 'unset' '_calyx_user_zshenv'
    }
    """

    /// Installed at `<root>/zsh/calyx.zsh`. Registers preexec/precmd
    /// hooks (array-append, matching ghostty's own `precmd_functions`/
    /// `preexec_functions` exposure -- not `add-zsh-hook`, so a user rc
    /// file that overwrites either array wholesale clobbers this
    /// exactly as it would clobber ghostty's own hook, no worse) that
    /// POST start/end command-lifecycle events to the local Calyx IPC
    /// server's `/command-event` endpoint, as a bounded-SYNCHRONOUS curl
    /// (`--connect-timeout 0.1 --max-time 0.3`, so ≤300ms worst case,
    /// typically ~5-15ms). Synchronous, not backgrounded, because output
    /// capture requires the server's start snapshot to happen-BEFORE the
    /// command runs: a backgrounded start POST races the command, and for
    /// any command faster than the curl round-trip (e.g. a ~12ms `echo`)
    /// the output is already on screen before the snapshot is taken, so
    /// the start count equals the end count and the captured delta is
    /// empty. The server ingests before responding 204
    /// (`CalyxMCPServer.routeCommandEvent`), so a completed foreground curl
    /// guarantees the snapshot precedes execution; the endpoint-file
    /// early-exit above keeps a dead server from ever spawning curl at all.
    /// Fails open
    /// (CALYX_SURFACE_ID and CALYX_SESSION_ID both unset, or
    /// agent-endpoint.json missing/unreadable, is a silent no-op) and
    /// suppresses an end event for an empty Enter (no preexec fired, so
    /// `_calyx_cmd_active` is never set for precmd to find).
    ///
    /// `_calyx_post`'s agent-endpoint.json sed-extraction is the same
    /// pattern as `AgentHookScript.scriptBody` verbatim (port/token
    /// regex), re-reading the file on every invocation so a server
    /// restart or token rotation is picked up without a new shell.
    /// `cmd_id` is a `$$-EPOCHREALTIME-RANDOM` nonce (unique enough for
    /// per-shell, per-command identity; needs no cryptographic
    /// strength). `ts` is epoch-milliseconds, integer-truncated by
    /// assigning the `EPOCHREALTIME * 1000` float result into a
    /// `typeset -i` variable (verified empirically: zsh's `integer`-
    /// typed assignment truncates toward zero, exactly the semantics
    /// `int(EPOCHREALTIME * 1000)` would give if `zsh/mathfunc` were
    /// loaded -- this avoids that extra `zmodload`). `command`/`cwd` are
    /// base64-encoded (`print -rn | base64 | tr -d '\\n'`, no line
    /// wrapping) rather than JSON-escaped -- JSON-escaping arbitrary
    /// strings inside sh was considered and rejected.
    static let calyxZshBody = """
    [[ -o interactive ]] || return 0
    [[ -z "${_CALYX_HOOKS_LOADED:-}" ]] || return 0
    'builtin' 'typeset' '-g' '_CALYX_HOOKS_LOADED=1'

    [[ -n "${CALYX_SURFACE_ID:-}" || -n "${CALYX_SESSION_ID:-}" ]] || return 0

    'builtin' 'zmodload' 'zsh/datetime' 2>/dev/null || return 0

    _calyx_post() {
        # CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController
        # alongside CALYX_SURFACE_ID, scoped to wherever this Calyx
        # process actually wrote agent-endpoint.json. The literal
        # fallback covers a pane launched before that injection existed.
        local endpoint_file="${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}"
        [[ -r "$endpoint_file" ]] || return 0
        local port token
        port=$(command sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
        token=$(command sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")
        [[ -n "$port" && -n "$token" ]] || return 0
        command curl -s --connect-timeout 0.1 --max-time 0.3 \\
            -X POST \\
            -H "Authorization: Bearer $token" \\
            -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-${CALYX_SURFACE_ID:-}}" \\
            -H 'Content-Type: application/json' \\
            --data-binary "$1" \\
            "http://127.0.0.1:$port/command-event" > /dev/null 2>&1 || return 0
    }

    _calyx_preexec() {
        'builtin' 'typeset' '-g' '_calyx_cmd_active=1'
        'builtin' 'typeset' '-g' _calyx_cmd_id="$$-${EPOCHREALTIME/./}-$RANDOM"
        local command_b64 cwd_b64
        command_b64=$(print -rn -- "$1" | command base64 | command tr -d '\\n')
        cwd_b64=$(print -rn -- "$PWD" | command base64 | command tr -d '\\n')
        typeset -i _calyx_ts
        _calyx_ts=$(( EPOCHREALTIME * 1000 ))
        _calyx_post "{\\"phase\\":\\"start\\",\\"cmd_id\\":\\"$_calyx_cmd_id\\",\\"command_b64\\":\\"$command_b64\\",\\"cwd_b64\\":\\"$cwd_b64\\",\\"ts\\":$_calyx_ts}"
    }

    _calyx_precmd() {
        local code=$?
        [[ -n "${_calyx_cmd_active:-}" ]] || return 0
        unset _calyx_cmd_active
        typeset -i _calyx_ts
        _calyx_ts=$(( EPOCHREALTIME * 1000 ))
        _calyx_post "{\\"phase\\":\\"end\\",\\"cmd_id\\":\\"$_calyx_cmd_id\\",\\"exit_code\\":$code,\\"ts\\":$_calyx_ts}"
    }

    'builtin' 'typeset' '-ag' 'preexec_functions'
    preexec_functions+=('_calyx_preexec')
    'builtin' 'typeset' '-ag' 'precmd_functions'
    precmd_functions+=('_calyx_precmd')

    return 0
    """

    /// Installed at `<root>/fish/vendor_conf.d/calyx-integration.fish`.
    /// fish's own vendor conf.d convention auto-sources this once `<root>`
    /// is on XDG_DATA_DIRS -- no ZDOTDIR-style relay needed, unlike zsh.
    /// Registers `fish_preexec`/`fish_postexec` event handlers (fish's
    /// own hook mechanism; both events pass the commandline as `$argv[1]`
    /// and are never emitted for an empty Enter, confirmed against
    /// fish's own shipped documentation) mirroring calyx.zsh's shape:
    /// same fail-open guard, same agent-endpoint.json sed-extraction,
    /// same bounded-synchronous curl (`--connect-timeout 0.1 --max-time
    /// 0.3`; see calyxZshBody's doc for why the start POST must be
    /// synchronous rather than backgrounded), same base64 encoding
    /// (`command base64 | string join ''`, fish's own idiom for
    /// flattening base64's multi-line output back to one line, playing
    /// the same role as zsh's `tr -d '\\n'`).
    ///
    /// One documented tradeoff: fish has no portable sub-second clock
    /// without a non-default `date` build (GNU date's `%N`), unlike
    /// zsh's `EPOCHREALTIME`. `ts` here is `` `date +%s` `` (whole
    /// seconds) `* 1000`, which is a plausible epoch-millisecond value
    /// (passes `CommandEvent.decode`'s range check) but loses
    /// sub-second precision for fish-tracked commands specifically --
    /// acceptable since nothing downstream needs sub-second resolution
    /// on duration.
    ///
    /// A second tradeoff, in `_calyx_postexec`: unlike zsh, whose native
    /// `$?` already reports `128 + signal` after a Ctrl-Z suspend,
    /// fish's own `$status` inside `fish_postexec` keeps the PREVIOUS
    /// real command's exit code across a suspend (measured directly
    /// against the installed fish binary -- a fresh shell reports 0, a
    /// shell with a prior failure keeps reporting that prior code).
    /// `_calyx_postexec` therefore consults fish's own `jobs` builtin --
    /// no `--stopped` filter exists, so its `State` column
    /// (`running`/`stopped`, header omitted inside a command
    /// substitution, columns tab-separated -- verified against the
    /// installed fish binary) is matched directly -- and, whenever any
    /// job is stopped, adds a separate `"suspended":true` field to the
    /// posted JSON body rather than touching `$status`. `exit_code`
    /// therefore always carries fish's own real value, and
    /// `AgentRegistry.handlePaneCommandFinished` excludes the event from
    /// settling the row through this flag rather than through
    /// `exitCode` (see that method's own doc comment for both routes).
    /// That "any job" scope is deliberate, not an oversight: fish
    /// exposes no way to attribute a stopped job to the specific command
    /// that just finished, so while any stopped job lingers in the pane,
    /// a later, unrelated command's own end event carries the flag too.
    /// The resulting failure mode is that later command's row staying
    /// live rather than settling to `.done` -- the same safe direction
    /// `AgentRegistry.stopSignals`' own doc comment describes, never the
    /// reverse. Because `exit_code` is never touched by this branch,
    /// that later command's own `CommandLogStore` record still logs its
    /// own real exit code -- the command log is no longer a second
    /// consequence of this cross-command scope, only the Agents row is.
    ///
    /// One case this cannot fix: for the SUSPENDED command's own end
    /// event, `$status` is still whatever fish last held before that
    /// command ran, since the command hasn't exited, only stopped --
    /// there is no real exit code yet for `_calyx_postexec` to report.
    /// That single record logs a code that does not describe it. This
    /// is fish's own semantics, not a choice this design makes: nothing
    /// available to `_calyx_postexec` can recover a value fish itself
    /// never computed.
    static let fishIntegrationBody = """
    status --is-interactive; or return 0

    if not set -q CALYX_SURFACE_ID; and not set -q CALYX_SESSION_ID
        return 0
    end

    function _calyx_post --argument-names body
        # CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController
        # alongside CALYX_SURFACE_ID, scoped to wherever this Calyx
        # process actually wrote agent-endpoint.json. The literal
        # fallback (fish has no ${VAR:-default}) covers a pane launched
        # before that injection existed.
        set -l endpoint_file "$CALYX_ENDPOINT_FILE"
        test -n "$endpoint_file"; or set endpoint_file "\(AgentEndpointFile.shellFallbackPath)"
        test -r "$endpoint_file"; or return 0
        set -l port (command sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
        set -l token (command sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")
        test -n "$port" -a -n "$token"; or return 0
        set -l surface_id "$CALYX_SESSION_ID"
        test -n "$surface_id"; or set surface_id "$CALYX_SURFACE_ID"
        command curl -s --connect-timeout 0.1 --max-time 0.3 \\
            -X POST \\
            -H "Authorization: Bearer $token" \\
            -H "X-Calyx-Surface-ID: $surface_id" \\
            -H 'Content-Type: application/json' \\
            --data-binary "$body" \\
            "http://127.0.0.1:$port/command-event" > /dev/null 2>&1; or return 0
    end

    function _calyx_preexec --on-event fish_preexec
        # fish_preexec does fire for a whitespace-only line (unlike a
        # truly empty one) -- guard against posting a noise record for it.
        # $argv[1] can span multiple lines (a multi-line command), so its
        # trimmed value must be captured into a variable first: passing
        # the command-substitution directly as `test -n (...)` splits a
        # multi-line result across several arguments, which `test`
        # rejects with "unexpected argument".
        set -l trimmed (string trim -- "$argv[1]")
        test -n "$trimmed"; or return 0
        set -g _calyx_cmd_active 1
        set -g _calyx_cmd_id "$fish_pid-"(date +%s000)"-"(random)
        set -l command_b64 (printf '%s' "$argv[1]" | command base64 | string join '')
        set -l cwd_b64 (printf '%s' "$PWD" | command base64 | string join '')
        set -l ts (math (date +%s) "*" 1000)
        _calyx_post "{\\"phase\\":\\"start\\",\\"cmd_id\\":\\"$_calyx_cmd_id\\",\\"command_b64\\":\\"$command_b64\\",\\"cwd_b64\\":\\"$cwd_b64\\",\\"ts\\":$ts}"
    end

    function _calyx_postexec --on-event fish_postexec
        set -l code $status
        set -q _calyx_cmd_active; or return 0
        set -e _calyx_cmd_active
        set -l suspended_field ""
        # Any job left stopped right now matches here, not only one
        # this command itself started -- see fishIntegrationBody's own
        # doc comment for why that cross-command scope is deliberate.
        string match -qr '\\tstopped\\t' -- (jobs 2>/dev/null); and set suspended_field ",\\"suspended\\":true"
        set -l ts (math (date +%s) "*" 1000)
        _calyx_post "{\\"phase\\":\\"end\\",\\"cmd_id\\":\\"$_calyx_cmd_id\\",\\"exit_code\\":$code,\\"ts\\":$ts$suspended_field}"
    end
    """

    /// `<directory>/zsh/.zshenv`.
    static func zshenvPath(in directory: URL) -> URL {
        directory.appendingPathComponent("zsh").appendingPathComponent(".zshenv")
    }

    /// `<directory>/zsh/calyx.zsh`.
    static func calyxZshPath(in directory: URL) -> URL {
        directory.appendingPathComponent("zsh").appendingPathComponent("calyx.zsh")
    }

    /// `<directory>/fish/vendor_conf.d/calyx-integration.fish`.
    static func fishIntegrationPath(in directory: URL) -> URL {
        directory.appendingPathComponent("fish")
            .appendingPathComponent("vendor_conf.d")
            .appendingPathComponent("calyx-integration.fish")
    }

    /// Writes the three integration files under `directory`, creating
    /// intermediate directories as needed, atomically, at 0644 (sourced,
    /// never executed directly -- unlike AgentHookScript's 0755). A
    /// symlink at any of the three destination paths is followed to its
    /// real file and overwritten in place, leaving the symlink itself
    /// intact (ConfigFileUtils.resolveConfigPath, mirroring
    /// OpenCodePluginManager.install's real, verified behavior).
    /// Idempotent: reinstalling with the same fixed body writes no bytes
    /// (`ConfigFileUtils.withExclusiveConfig` skips the write entirely
    /// when the transformed bytes equal the file's current bytes,
    /// leaving mtime untouched) but still restores the file's mode to
    /// 0644 if it has drifted (e.g. a user `chmod`); a body that
    /// actually differs still overwrites, at 0644, exactly as before.
    /// Returns `directory` itself, so callers can chain straight into
    /// CalyxShellIntegrationEnvironment.apply(rootDirectory:).
    static func install(toDirectory directory: URL) throws -> URL {
        let fm = FileManager.default
        let zshDirectory = directory.appendingPathComponent("zsh")
        let fishVendorDirectory = directory.appendingPathComponent("fish").appendingPathComponent("vendor_conf.d")
        try fm.createDirectory(at: zshDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: fishVendorDirectory, withIntermediateDirectories: true)

        try write(zshenvBody, to: zshenvPath(in: directory))
        try write(calyxZshBody, to: calyxZshPath(in: directory))
        try write(fishIntegrationBody, to: fishIntegrationPath(in: directory))

        return directory
    }

    /// Removes the three integration files from `directory`. Symmetric
    /// with `install`: routes through `ConfigFileUtils.withExclusiveConfig`,
    /// which resolves a symlinked destination path and deletes the real
    /// target file under the same per-path lock `install` uses, leaving
    /// the symlink itself intact (now dangling). A no-op for any file
    /// not present.
    static func remove(fromDirectory directory: URL) throws {
        for path in [zshenvPath(in: directory), calyxZshPath(in: directory), fishIntegrationPath(in: directory)] {
            try ConfigFileUtils.withExclusiveConfig(path: path.path) { _ in nil }
        }
    }

    /// `true` only when all three integration files exist (following
    /// symlinks, matching `FileManager.fileExists`'s own default
    /// behavior).
    static func isInstalled(inDirectory directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: zshenvPath(in: directory).path)
            && fm.fileExists(atPath: calyxZshPath(in: directory).path)
            && fm.fileExists(atPath: fishIntegrationPath(in: directory).path)
    }

    /// Shared write path for `install`: routes through
    /// `ConfigFileUtils.withExclusiveConfig`, which resolves a symlinked
    /// destination, takes the path's exclusive lock, and writes
    /// atomically at 0644 -- the mode a sourced (never executed) file
    /// needs, applied to the temp file before the rename inside the
    /// lock, so no other process can observe or race an intermediate
    /// permission state.
    private static func write(_ body: String, to path: URL) throws {
        let data = Data(body.utf8)
        try ConfigFileUtils.withExclusiveConfig(path: path.path, mode: 0o644, restoreModeOnNoWrite: true) { _ in data }
    }
}
