#!/usr/bin/env bash
# shellcheck shell=bash
#
# ctx.sh - Portable context switcher for GitHub Copilot CLI
# ==========================================================
#
# Composes AI agent configuration directories (profiles)
# stored under a root directory (default: ~/work/ai-config) into the
# COPILOT_CUSTOM_INSTRUCTIONS_DIRS environment variable, for the current
# shell session.
#
# Compatible with bash and zsh.
#
# ---------------------------------------------------------------------------
# INSTALLATION
# ---------------------------------------------------------------------------
#   1. Copy (or symlink) this file to ~/.config/ctx/ctx.sh
#        mkdir -p ~/.config/ctx
#        cp ctx.sh ~/.config/ctx/ctx.sh
#      (or run ./install.sh from this repo)
#
#   2. zsh setup - add to ~/.zshrc:
#        source "$HOME/.config/ctx/ctx.sh"
#
#   3. bash setup - add to ~/.bashrc:
#        source "$HOME/.config/ctx/ctx.sh"
#
#   4. Completion is registered automatically when this file is sourced.
#
# ---------------------------------------------------------------------------
# DIRECTORY LAYOUT EXPECTED
# ---------------------------------------------------------------------------
#   ${AI_CTX_PROFILES_CONFIG_ROOT:-$HOME/work/ai-config}/
#   └── profiles/
#       ├── review/
#       ├── architecture/
#       ├── incident/
#       ├── coding/
#       ├── dotnet/
#       ├── azure/
#       ├── terraform/
#       └── security/
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   ctx review                    # activate the "review" profile
#   ctx coding azure              # activate multiple profiles
#   ctx review dotnet security    # activate multiple profiles
#   ctx current                   # show active profiles/env vars
#   ctx clear                     # unset AI_CTX_PROFILES / COPILOT_CUSTOM_INSTRUCTIONS_DIRS / COPILOT_HOME
#   ctx clear --all               # remove the current context home and owned workspace artifacts
#   ctx --help                    # usage help
#
# --- AUTO-LOADING (.ctx files) -----------------------------------------
#   Drop a ".ctx" file in any project directory. Each non-empty, non-comment
#   line maps an arbitrary context name to a custom-instructions directory:
#
#       <context-name>:<path-to-folder>
#
#   Example:
#       review:/home/user/work/ai-config/profiles/review
#       dotnet:/home/user/work/ai-config/profiles/dotnet
#       security:./local-instructions
#
#   Relative paths are resolved against the directory containing the .ctx
#   file (not the current working directory). Unlike `ctx <profile> [profile...]`,
#   these names are NOT looked up under AI_CTX_PROFILES_CONFIG_ROOT/profiles - the
#   path on each line is used directly. Every path is validated to exist.
#
#   When your prompt renders after a `cd` into that directory (or a
#   descendant of it), AI_CTX_PROFILES and COPILOT_CUSTOM_INSTRUCTIONS_DIRS are
#   set (overwriting any previous value) from the file's contents. Leaving
#   the directory tree (into a location with no .ctx file) automatically
#   clears the context.
#
#   NOAUTOLOAD FLAG
#   ----------------
#   Add a bare "noautoload" line (no colon, case-insensitive) to the .ctx
#   file to prevent the directory-change hook from loading it automatically:
#
#       noautoload
#       review:/home/user/work/ai-config/profiles/review
#
#   The file remains valid and can be loaded explicitly at any time with
#   "ctx load <path-to-.ctx-file>" (see below).
#
#   SKILL DISCOVERY
#   ----------------
#   COPILOT_CUSTOM_INSTRUCTIONS_DIRS does not make Copilot CLI discover agent
#   skills stored in your .ctx entries. ctx sets COPILOT_HOME to a per-context
#   home and links each resolved entry's contracted skill source (.github/skills
#   for legacy profiles, .agents/skills for canonical AGENTS.md profiles) into
#   its skills folder.
#   Shared Copilot files are reconciled against the real Copilot home on every
#   activation. The cache remains after ctx clear; ctx clear --all removes it.
#
#   VS CODE WORKSPACE
#   ------------------
#   Running "ctx load <path>" explicitly (or any other on-demand activation
#   that calls the loader directly) creates/updates a multi-root VS Code
#   workspace file named "<folder-name>.code-workspace" (requires python3)
#   next to the .ctx file, so the project and its .ctx dependencies can all
#   be browsed in one VS Code window. The passive auto-load hook (directory
#   change / new shell finding an existing .ctx file) still sets
#   AI_CTX_PROFILES, COPILOT_CUSTOM_INSTRUCTIONS_DIRS, and the Copilot home/
#   links/skills as usual, but does NOT create or update this workspace
#   file. This keeps a plain "cd" into a .ctx-bearing directory from
#   creating files you didn't ask for (issue #30). Run "ctx load <path>"
#   yourself to generate it, or re-run it after the .ctx file changes to
#   refresh it — auto-load re-entering the same directory does not:
#
#     - This folder is added as "root: <folder-name>".
#     - Each .ctx entry is added as "ctx: <context-name>", pointing at the
#       resolved directory from that line.
#
#   Any other folders already present in the workspace file (added by you,
#   or by VS Code) are preserved; only entries previously generated by ctx
#   (named "root: ..." or "ctx: ...") are replaced on each explicit
#   "ctx load". Nothing is removed from the workspace file when the
#   context is cleared (run "ctx clear --all" to delete it instead).
#
#   Disable auto-loading for the session with:
#       export CTX_AUTO_LOAD=0
#
# ---------------------------------------------------------------------------

# --- Core implementation -----------------------------------------------

_ctx_root() {
    printf '%s\n' "${AI_CTX_PROFILES_CONFIG_ROOT:-$HOME/work/ai-config}"
}

_ctx_external_profiles_root() {
    local root="${AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT:-}" canonical
    [ -n "$root" ] || return 0
    case "$root" in
        /*) ;;
        *) printf 'ctx: error: AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT must be an absolute path: %s\n' "$root" >&2; return 1 ;;
    esac
    [ -d "$root" ] || { printf 'ctx: error: external profiles root is not a directory: %s\n' "$root" >&2; return 1; }
    canonical="$(realpath -m -- "$root" 2>/dev/null)" || { printf 'ctx: error: cannot resolve external profiles root: %s\n' "$root" >&2; return 1; }
    [ "$canonical" != "/" ] || { printf 'ctx: error: external profiles root cannot be the filesystem root\n' >&2; return 1; }
    printf '%s\n' "$canonical"
}

# Lowercase a context name without shell-specific case conversion syntax.
# `${name,,}` is not supported by zsh, despite ctx.sh supporting both shells.
_ctx_lowercase() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

_ctx_skill_canonical_name() {
    # Lowercases a skill basename exactly the way PowerShell's
    # ToLowerInvariant() does, so the two shells agree on skill-name
    # collisions for non-ASCII names (issue #40). Pure-ASCII names use the
    # fast tr path (LC_ALL=C, so A-Z folding is locale-independent) with no
    # external dependency. Non-ASCII names are folded with python3/python
    # (stdlib, locale-independent UTF-8) one code point at a time, keeping the
    # original code point whenever its lowercase mapping would expand to
    # multiple code points (e.g. U+0130) or when the whole-word mapping would
    # be context-sensitive (e.g. Greek final sigma), matching .NET's simple
    # per-character invariant mapping. It fails with a clear error when
    # neither interpreter is available, rather than silently diverging.
    local name="$1"
    if printf '%s' "$name" | LC_ALL=C grep -q '[^ -~]'; then
        local python_bin=""
        if command -v python3 >/dev/null 2>&1; then
            python_bin="python3"
        elif command -v python >/dev/null 2>&1; then
            python_bin="python"
        else
            printf 'ctx: error: cannot lowercase non-ASCII skill name "%s" (python3/python not found)\n' "$name" >&2
            return 1
        fi
        local folded
        folded="$(printf '%s' "$name" | "$python_bin" -c '
import sys
s = sys.stdin.buffer.read().decode("utf-8")
out = []
for c in s:
    low = c.lower()
    out.append(low if len(low) == 1 else c)
sys.stdout.buffer.write("".join(out).encode("utf-8"))
')" || {
            printf 'ctx: error: cannot lowercase non-ASCII skill name "%s"\n' "$name" >&2
            return 1
        }
        printf '%s\n' "$folded"
        return 0
    fi
    printf '%s\n' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]'
    return 0
}

_ctx_usage() {
    cat <<'EOF'
Usage:
  ctx <profile> [profile...]  Activate one or more profiles
  ctx current                   Show the currently active context
  ctx check                    Read-only audit against the nearest .ctx file
  ctx skills                   Read-only potential-Copilot-skill discovery
                               inventory (filesystem/configuration based)
  ctx clear                   Clear the currently active context
  ctx clear --all             Remove the current context home and generated
                               project artifacts next to the nearest .ctx file
                               Workspace files are removed only with the exact
                               generatedBy: "ctx" marker; unmarked, invalid,
                               and linked workspaces are preserved with a warning.
  ctx load <file>             Explicitly load a .ctx file (bypasses noautoload)
  ctx --help | -h             Show this help message

Examples:
  ctx review
  ctx coding azure
  ctx review dotnet security
  ctx load /path/to/project/.ctx

Environment:
  AI_CTX_PROFILES_CONFIG_ROOT      Root directory containing profiles/
                       (default: $HOME/work/ai-config)
  AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT
                       Optional absolute path to a trusted external profiles directory
  CTX_AUTO_LOAD        Set to 0 to disable automatic .ctx loading on cd
EOF
}

_ctx_print_status() {
    local profile="$1"
    local shared_csv="$2"

    printf '\n[AI Context]\n\n'
    printf 'Profile : %s\n' "${profile:-<none>}"
    printf 'Profiles: %s\n' "${shared_csv:-<none>}"
    printf '\nAI_CTX_PROFILES=%s\n' "${AI_CTX_PROFILES:-<unset>}"
    if _ctx_active_record_matches; then
        # Report the actually active mode from the matching activation
        # record, never the raw selector: a stale/mismatched
        # AI_CTX_PROFILES_COPILOT_MODE without a matching activation is not
        # reported as active.
        printf 'Mode: %s\n' "$(_ctx_mode_label "$_ctx_active_mode")"
        if [ "$_ctx_active_mode" != "synthetic-home" ]; then
            printf 'COPILOT_SKILLS_DIRS=%s\n' "${COPILOT_SKILLS_DIRS:-<unset>}"
        fi
        printf 'COPILOT_HOME=%s\n' "${COPILOT_HOME:-<unset>}"
    else
        # A context is active but there is no matching local activation
        # record: mode and any COPILOT_HOME/COPILOT_SKILLS_DIRS present are
        # unattributable, so label them unknown rather than guessing.
        printf 'Mode: <unknown>\n'
        if [ -n "${COPILOT_SKILLS_DIRS+x}" ]; then
            printf 'COPILOT_SKILLS_DIRS=%s (unknown)\n' "$COPILOT_SKILLS_DIRS"
        fi
        if [ -n "${COPILOT_HOME+x}" ]; then
            printf 'COPILOT_HOME=%s (unknown)\n' "$COPILOT_HOME"
        else
            printf 'COPILOT_HOME=<unset>\n'
        fi
    fi
    # Truthfully distinguish a present-empty all-canonical value from unset.
    printf '\nCOPILOT_CUSTOM_INSTRUCTIONS_DIRS=\n'
    if [ -z "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+x}" ]; then
        printf '<unset>\n'
    elif [ -z "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" ]; then
        printf '<present-empty>\n'
    else
        printf '%s\n' "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" | tr ',' '\n'
    fi
}

_ctx_current() {
    # Read-only: delegates to the .NET 10 engine named by CTX_ENGINE_DLL.
    # There is no legacy renderer fallback, so a missing/non-file engine is a
    # hard failure. The recorded mode is passed only when the session-local
    # activation record still matches; the mode is never inferred from
    # AI_CTX_PROFILES_COPILOT_MODE.
    if [ -z "${CTX_ENGINE_DLL:-}" ] || [ ! -f "$CTX_ENGINE_DLL" ]; then
        printf 'ctx: error: .NET 10 engine DLL not found: %s\n' "${CTX_ENGINE_DLL:-<unset>}" >&2
        return 1
    fi

    if _ctx_active_record_matches; then
        dotnet "$CTX_ENGINE_DLL" current --recorded-mode "$_ctx_active_mode"
    else
        dotnet "$CTX_ENGINE_DLL" current
    fi
}

_ctx_file_identity() {
    local path="$1" result
    if command -v stat >/dev/null 2>&1; then
        result="$(stat -c '%d:%i' -- "$path" 2>/dev/null)" || result=""
        # BSD/macOS stat does not accept GNU's `--` option separator.
        [ -n "$result" ] || result="$(stat -f '%d:%i' "$path" 2>/dev/null)"
    fi
    [ -n "$result" ] || return 1
    printf '%s\n' "$result"
}

_ctx_same_file() {
    # Returns 0 when both paths reference the same file (device:inode), used to
    # detect a case-alias on a case-insensitive filesystem without guessing:
    # only an exact existing spelling that resolves to the same file is treated
    # as the same entry. Returns 1 when either path is missing or identity
    # cannot be determined (callers fail closed).
    local a="$1" b="$2" ia ib
    [ -e "$a" ] || return 1
    [ -e "$b" ] || return 1
    ia="$(_ctx_file_identity "$a")" || return 1
    ib="$(_ctx_file_identity "$b")" || return 1
    [ "$ia" = "$ib" ]
}

_ctx_link_matches() {
    local link="$1" target="$2" link_target
    if [ -L "$link" ]; then
        link_target="$(readlink "$link")"
        [ "$link_target" = "$target" ]
        return
    fi
    [ -f "$link" ] && [ -f "$target" ] || return 1
    [ "$(_ctx_file_identity "$link")" = "$(_ctx_file_identity "$target")" ]
}

_ctx_workspace_is_generated() {
    local workspace_file="$1" python_bin=""
    if command -v python3 >/dev/null 2>&1; then
        python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        python_bin="python"
    else
        return 1
    fi
    "$python_bin" - "$workspace_file" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        workspace = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if isinstance(workspace, dict) and workspace.get("generatedBy") == "ctx" else 1)
PYEOF
}

_ctx_clear() {
    # $1: optional "--all" to also delete the artifacts ctx generates next
    # to the nearest .ctx file (.github/copilot/settings.local.json and the
    # "<folder-name>.code-workspace" file), instead of just leaving them in
    # place for next time.
    local prev_context="${AI_CTX_PROFILES:-}"
    local cleanup_status=0
    # Use the recorded mode of the matching activation, NOT the live selector
    # (which may be stale). With no matching record, home ownership is
    # unknown: ctx must never guess a mode from the selector or from the home
    # path, so COPILOT_HOME is left untouched and no home is deleted. Mode B
    # never touches COPILOT_HOME; Mode C never deletes the ephemeral home and
    # handles a drifted/replaced COPILOT_HOME separately below.
    local clear_mode=""
    if clear_mode="$(_ctx_active_record_mode)"; then
        : # recorded mode found
    fi
    # Capture COPILOT_HOME only where it is needed: the Mode A deletion safety
    # check (before the variable is unset below). Mode B clear and Mode C
    # clear never read it for ownership - Mode C uses the recorded ephemeral
    # path and Mode B leaves the variable untouched.
    local prev_home=""
    if [ "$clear_mode" = "synthetic-home" ]; then
        prev_home="${COPILOT_HOME:-}"
    fi
    # The non---all environment mutations and warning decisions are delegated
    # to the .NET engine via the line protocol. The engine applies the same
    # allowlisted unset operations atomically; on engine failure nothing is
    # mutated (fail closed) and clear returns non-zero.
    if ! _ctx_clear_apply_engine "$clear_mode"; then
        return 1
    fi
    # No matching activation record: report a present COPILOT_HOME as unknown
    # rather than attributing it to a mode or guessing a deletion target. The
    # literal string and stderr stream are unchanged; presence (not a non-empty
    # value) is what triggers the notice.
    if [ "$_ctx_protocol_outcome_warn_unowned_home_seen" -eq 1 ]; then
        printf 'ctx: warning: no matching activation record; COPILOT_HOME is unowned (unknown), left as-is: %s\n' "$_ctx_protocol_outcome_warn_unowned_home" >&2
    fi
    # The Mode C retained-path notice prints for BOTH plain clear and
    # clear --all, before the active record is cleared. A COPILOT_HOME that
    # no longer equals the recorded ephemeral path is preserved and reported
    # as changed/unowned.
    if [ "$_ctx_protocol_outcome_retained_ephemeral_home_seen" -eq 1 ]; then
        _ctx_report_retained_ephemeral_home "$_ctx_protocol_outcome_retained_ephemeral_home"
    fi
    if [ "$_ctx_protocol_outcome_warn_home_changed_seen" -eq 1 ]; then
        printf 'ctx: warning: COPILOT_HOME has changed from the recorded ephemeral path (unowned, unknown), left as-is: %s\n' "$_ctx_protocol_outcome_warn_home_changed" >&2
    fi
    # The engine already applied any COPILOT_SKILLS_DIRS unset; reset the
    # session-local ownership bookkeeping exactly as before.
    _ctx_reset_owned_skills_dirs

    if [ "${1:-}" = "--all" ]; then
        local dir_of_file="$_ctx_auto_load_dir"
        if [ -z "$dir_of_file" ]; then
            local ctx_file
            if ctx_file="$(_ctx_find_ctx_file)"; then
                dir_of_file="$(dirname "$ctx_file")"
            fi
        fi

        if [ -n "$dir_of_file" ]; then
            local settings_file="$dir_of_file/.github/copilot/settings.local.json"
            if [ -f "$settings_file" ]; then
                # Legacy cleanup: settings.local.json's skillDirectories is
                # confirmed inert (issue #1) and no longer written by ctx,
                # but pre-existing files from older ctx versions are still
                # removed here for one release. Safe to drop this block in
                # a future release once users have upgraded.
                if rm -f "$settings_file"; then
                    printf 'ctx: removed %s\n' "$settings_file"
                else
                    cleanup_status=$?
                    printf 'ctx: error: failed to remove %s (status %s)\n' "$settings_file" "$cleanup_status" >&2
                fi
            fi

            local folder_name workspace_file
            folder_name="$(basename "$dir_of_file")"
            workspace_file="$dir_of_file/$folder_name.code-workspace"
            if [ -L "$workspace_file" ]; then
                printf 'ctx: preserved linked workspace %s\n' "$workspace_file" >&2
            elif [ -f "$workspace_file" ]; then
                if _ctx_workspace_is_generated "$workspace_file"; then
                    if rm -f "$workspace_file"; then
                        printf 'ctx: removed %s\n' "$workspace_file"
                    else
                        cleanup_status=$?
                        printf 'ctx: error: failed to remove %s (status %s)\n' "$workspace_file" "$cleanup_status" >&2
                    fi
                else
                    printf 'ctx: preserved unowned workspace %s\n' "$workspace_file" >&2
                fi
            fi
        else
            if [ -n "$prev_context" ]; then
                # Context was activated manually (no .ctx file), so there are
                # no on-disk artifacts (settings.local.json / workspace file)
                # to clean up, but the COPILOT_HOME directory below still
                # gets removed - don't imply nothing happens at all.
                printf 'ctx: warning: no .ctx file found; skipping artifact cleanup\n' >&2
            else
                printf 'ctx: warning: no .ctx file found; nothing to remove\n' >&2
            fi
        fi

        # Mode B never touches COPILOT_HOME and skips the synthetic-home
        # deletion block entirely; Mode C never deletes the ephemeral home.
        # Only Mode A's existing safety-validated deletion runs.
        if [ "$clear_mode" = "synthetic-home" ] && [ -n "$prev_context" ]; then
            local sanitized homes_root home_dir
            if [ -n "$_ctx_auto_load_home_override" ]; then
                home_dir="$_ctx_auto_load_home_override"
            else
                sanitized="$(_ctx_sanitize_context_name "$prev_context")"
                homes_root="$(_ctx_copilot_home_root)"
                home_dir="$homes_root/$sanitized"
            fi
            if [ -z "$prev_home" ] || [ "$home_dir" != "$prev_home" ] || ! _ctx_validate_home_path "$home_dir" >/dev/null; then
                printf 'ctx: error: refusing to remove unsafe or unselected home: %s\n' "$home_dir" >&2
                cleanup_status=1
            elif [ -d "$home_dir" ] && [ ! -L "$home_dir" ]; then
                local remove_status=0
                rm -rf -- "$home_dir" || remove_status=$?
                if [ "$remove_status" -ne 0 ]; then
                    printf 'ctx: error: failed to remove %s (status %s)\n' "$home_dir" "$remove_status" >&2
                    cleanup_status="$remove_status"
                else
                    printf 'ctx: removed %s\n' "$home_dir"
                fi
            fi
        fi
    fi

    # Never leave a stale active record for an already-cleared context, even
    # when --all reported an unrelated artifact cleanup error above.
    _ctx_reset_active_record
    export CTX_AUTO_LOAD_DIR=""
    _ctx_auto_load_dir=""
    _ctx_auto_load_home_override=""
    printf 'AI context cleared.\n'
    return "$cleanup_status"
}

_ctx_resolve_profile_identifier() {
    # Resolve a name under the configured root, or its explicit external
    # allowlist. Its physical target must be an immediate child of a trusted
    # root; traversal and untrusted profile symlinks remain rejected.
    local name="$1" profiles_root external_root root_canonical candidate candidate_root canonical parent
    case "$name" in
        ''|.|..|*/*|*\\*)
            printf 'ctx: error: invalid profile identifier "%s"\n' "$name" >&2
            return 1 ;;
    esac
    profiles_root="$(_ctx_root)/profiles"
    external_root="$(_ctx_external_profiles_root)" || return 1
    root_canonical="$(realpath -m -- "$profiles_root" 2>/dev/null)" || return 1
    for candidate_root in "$profiles_root" "$external_root"; do
        [ -n "$candidate_root" ] || continue
        candidate="$candidate_root/$name"
        [ -d "$candidate" ] || continue
        canonical="$(realpath -m -- "$candidate" 2>/dev/null)" || return 1
        parent="$(dirname "$canonical")"
        if [ "$parent" = "$root_canonical" ] || { [ -n "$external_root" ] && [ "$parent" = "$external_root" ]; }; then
            printf '%s\n' "$canonical"
            return 0
        fi
        printf 'ctx: error: invalid profile identifier "%s"\n' "$name" >&2
        return 1
    done
    printf 'ctx: error: unknown profile "%s" (looked in %s%s)\n' "$name" "$profiles_root" "${external_root:+ and $external_root}" >&2
    printf 'ctx: available profiles:\n' >&2
    { [ -d "$profiles_root" ] && find "$profiles_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null; [ -n "$external_root" ] && find "$external_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null; } | LC_ALL=C sort -u | sed 's/^/  - /' >&2
    return 1
}

ctx() {
    if [ "$#" -eq 0 ]; then _ctx_usage; return 0; fi
    case "$1" in
        -h|--help) _ctx_usage; return 0 ;;
        current) _ctx_current; return $? ;;
        check) _ctx_check; return $? ;;
        skills) _ctx_skills; return 0 ;;
        clear) _ctx_clear "$2"; return $? ;;
        load)
            if [ -z "${2:-}" ]; then
                printf 'ctx: error: "ctx load" requires a path argument\n' >&2
                printf 'Usage: ctx load <path-to-.ctx-file>\n' >&2
                return 1
            fi
            local load_file load_dir
            case "$2" in
                /*) load_file="$2" ;;
                *) load_file="$PWD/$2" ;;
            esac
            if [ ! -f "$load_file" ]; then
                printf 'ctx: error: file not found: %s\n' "$load_file" >&2
                return 1
            fi
            # Same normalization as the parser, so the auto-load hook sees the
            # folder ctx load just activated (#75).
            load_dir="$(CDPATH= cd -- "$(dirname -- "$load_file")" && pwd)"
            if _ctx_load_ctx_file "$load_file"; then
                _ctx_auto_load_dir="$load_dir"
            else
                return $?
            fi
            return 0
            ;;
    esac

    local root profile_name profile_dir context_name context_lc profile_name_lc
    root="$(_ctx_root)"
    if [ ! -d "$root" ]; then printf 'ctx: error: AI config root does not exist: %s\n' "$root" >&2; return 1; fi
    local mode
    mode="$(_ctx_validate_copilot_mode)" || return 1
    local dirs_csv="" skills_dirs_csv=""
    local -a resolved_dirs_manual=() context_names=() seen_names=() legacy_dirs=() canon_labels=()
    _ctx_canon_args=()
    for context_name in "$@"; do
        context_lc="$(_ctx_lowercase "$context_name")"
        for profile_name_lc in "${seen_names[@]}"; do
            if [ "$profile_name_lc" = "$context_lc" ]; then printf 'ctx: error: duplicate profile "%s"\n' "$context_name" >&2; return 1; fi
        done
        seen_names+=("$context_lc")
        if ! profile_dir="$(_ctx_resolve_profile_identifier "$context_name")"; then return 1; fi
        context_names+=("$context_name"); resolved_dirs_manual+=("$profile_dir")
        if _ctx_profile_is_canonical "$profile_dir"; then
            _ctx_canon_args+=("${#context_names[@]}" "$context_name" "$profile_dir")
            canon_labels+=("$context_name")
        else
            legacy_dirs+=("$profile_dir")
        fi
    done
    [ "${#context_names[@]}" -gt 0 ] || return 1
    profile_name="${context_names[0]}"
    # Canonical profiles are only projectable in Mode A. Reject any canonical
    # selection under Modes B/C before any environment export, workspace write,
    # or Copilot-home setup/creation (issue #48).
    if [ "${#canon_labels[@]}" -gt 0 ] && [ "$mode" != "synthetic-home" ]; then
        printf 'ctx: error: canonical profile(s) require synthetic-home mode (active mode: %s): %s\n' "$mode" "${canon_labels[*]}" >&2
        return 1
    fi
    # Mode A includes only legacy roots in COPILOT_CUSTOM_INSTRUCTIONS_DIRS;
    # an all-canonical selection yields the present-empty value.
    dirs_csv="$(IFS=,; printf '%s' "${legacy_dirs[*]}")"
    # COPILOT_SKILLS_DIRS is computed/validated only in Modes B/C before any
    # state change; a comma in an included skills path rejects the activation.
    # Mode A must not run this new validation or otherwise change its parsing.
    local skills_dirs_csv=""
    if [ "$mode" = "global-user" ] || [ "$mode" = "ephemeral-clean" ]; then
        if ! skills_dirs_csv="$(_ctx_compute_skills_dirs_csv "${resolved_dirs_manual[@]}")"; then return 1; fi
    fi
    local new_context="${context_names[*]}"; new_context="${new_context// /+}"
    local new_home="" old_ephemeral_home=""
    if [ "$mode" = "ephemeral-clean" ]; then
        # Mode C: preflight home creation before any state change so a
        # failure leaves the previous context and all files untouched.
        if ! new_home="$(_ctx_create_ephemeral_copilot_home)"; then return 1; fi
    fi
    if [ "$mode" = "synthetic-home" ]; then
        # Mode A: preflight home creation and link reconciliation before any
        # state change so a failure leaves the previous context, COPILOT_HOME,
        # and all files untouched.
        if ! _ctx_setup_copilot_home "$new_context" "" "${resolved_dirs_manual[@]}"; then return 1; fi
    fi
    if [ "$(_ctx_active_record_mode)" = "ephemeral-clean" ]; then
        # Remember the replaced Mode C home so its retained-path notice can be
        # printed only after the replacement below actually succeeds.
        old_ephemeral_home="$_ctx_active_home_value"
    fi
    AI_CTX_PROFILES="$new_context"
    case "$mode" in
        global-user)
            # Mode B: never set up or touch COPILOT_HOME at all.
            ;;
        synthetic-home)
            # Mode A: COPILOT_HOME was preflighted above before any state
            # change; no further setup needed here.
            ;;
        ephemeral-clean)
            export COPILOT_HOME="$new_home"
            ;;
    esac
    case "$mode" in
        global-user|ephemeral-clean)
            # B/C: export the freshly computed value; fully replaced each
            # activation, then record its exact state as ctx-owned this session.
            if [ -n "$skills_dirs_csv" ]; then
                export COPILOT_SKILLS_DIRS="$skills_dirs_csv"
            else
                unset COPILOT_SKILLS_DIRS
            fi
            _ctx_record_owned_skills_dirs
            ;;
        synthetic-home)
            # A: unset only a value that still matches what a prior B/C
            # activation in this session established; a user's own value is
            # never touched.
            _ctx_unset_owned_skills_dirs
            ;;
    esac
    export COPILOT_CUSTOM_INSTRUCTIONS_DIRS="$dirs_csv" AI_CTX_PROFILES
    # Publish the session record only after a fully successful activation.
    _ctx_set_active_record "$mode"
    _ctx_warn_global_user_copilot_home "$mode"
    if [ -n "$old_ephemeral_home" ]; then
        _ctx_report_retained_ephemeral_home "$old_ephemeral_home"
    fi
    _ctx_print_status "$AI_CTX_PROFILES" ""
}
# --- Auto-loading via .ctx files ----------------------------------------

_ctx_auto_load_dir=""
# Ordered canonical projection entries ("order label source-dir" triples) for
# the activation currently being preflighted; set by the manual and .ctx
# activation callers and read by _ctx_setup_copilot_home. Reset per activation.
_ctx_canon_args=()
# Tracks the "home:" directive override (issue #7), if any, from the last
# .ctx file auto-loaded, so _ctx_clear --all knows to look for the
# synthetic COPILOT_HOME at that location instead of the centralized one.
_ctx_auto_load_home_override=""
# Tracks the exact COPILOT_SKILLS_DIRS state ctx established this session
# (Modes B/C). _ctx_skills_dirs_owned is 1 while such a record exists;
# _ctx_skills_dirs_was_set records whether the activation left the variable
# set, and _ctx_skills_dirs_value records its exact value when set. Clear and
# a switch into Mode A unset the variable only when the current presence/value
# still matches this record, so a user's later value is never erased. Failed
# activations never touch the record.
_ctx_skills_dirs_owned=0
_ctx_skills_dirs_was_set=0
_ctx_skills_dirs_value=""

# Session-local activation record (no on-disk registry). Written only after
# an activation has actually succeeded; reset on clear and never on a failed
# activation. `ctx current`/`ctx check` report the mode and home of the
# matching record, never the raw selector, so a stale
# AI_CTX_PROFILES_COPILOT_MODE without a matching activation is not reported
# as active.
_ctx_active_mode=""
_ctx_active_context=""
_ctx_active_custom_dirs=""
_ctx_active_home_was_set=0
_ctx_active_home_value=""

_ctx_active_record_mode() {
    # Prints the recorded mode when the activation record's context and
    # custom-instructions directories still match the current environment;
    # prints nothing and returns 1 otherwise. COPILOT_HOME is deliberately not
    # compared here: clear and replacement notices handle Mode C home drift
    # separately, and only `current`/`check` require full record fidelity.
    [ -n "$_ctx_active_mode" ] || return 1
    [ "$_ctx_active_context" = "${AI_CTX_PROFILES:-}" ] || return 1
    [ "$_ctx_active_custom_dirs" = "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-}" ] || return 1
    printf '%s\n' "$_ctx_active_mode"
}

_ctx_active_record_matches() {
    # Returns 0 when the session-local activation record matches the current
    # activated context (AI_CTX_PROFILES and COPILOT_CUSTOM_INSTRUCTIONS_DIRS
    # unchanged since the activation), 1 otherwise. A record whose context no
    # longer matches is foreign/stale and must not be attributed. For Mode C
    # the record additionally matches only while the current COPILOT_HOME is
    # still the exact recorded ephemeral path, so a changed/foreign home is
    # never attributed to the recorded activation.
    local mode
    mode="$(_ctx_active_record_mode)" || return 1
    if [ "$mode" = "ephemeral-clean" ]; then
        [ -n "${COPILOT_HOME+x}" ] || return 1
        [ "$COPILOT_HOME" = "$_ctx_active_home_value" ] || return 1
    fi
    return 0
}

_ctx_record_owned_skills_dirs() {
    # Records the exact COPILOT_SKILLS_DIRS state a successful B/C activation
    # established this session, so clear and a Mode A switch unset the variable
    # only when the current value still matches; a user's later value is
    # preserved.
    _ctx_skills_dirs_owned=1
    if [ -n "${COPILOT_SKILLS_DIRS+x}" ]; then
        _ctx_skills_dirs_was_set=1
        _ctx_skills_dirs_value="$COPILOT_SKILLS_DIRS"
    else
        _ctx_skills_dirs_was_set=0
        _ctx_skills_dirs_value=""
    fi
}

_ctx_reset_owned_skills_dirs() {
    # Clears the session-local skills-ownership bookkeeping without touching
    # the environment. The clear path applies the unset via the engine and
    # then resets this record.
    _ctx_skills_dirs_owned=0
    _ctx_skills_dirs_was_set=0
    _ctx_skills_dirs_value=""
}

_ctx_unset_owned_skills_dirs() {
    # Unsets COPILOT_SKILLS_DIRS only when the current presence/value still
    # matches what a prior B/C activation in this session established; never
    # touches a user's own value. Resets the ownership record regardless.
    if [ "$_ctx_skills_dirs_owned" -eq 1 ]; then
        if [ "$_ctx_skills_dirs_was_set" -eq 1 ] && [ -n "${COPILOT_SKILLS_DIRS+x}" ] && [ "$COPILOT_SKILLS_DIRS" = "$_ctx_skills_dirs_value" ]; then
            unset COPILOT_SKILLS_DIRS
        fi
        _ctx_reset_owned_skills_dirs
    fi
}

_ctx_set_active_record() {
    # $1: the mode that actually activated. Must be called only after the
    # activation succeeded and the environment is fully set up.
    _ctx_active_mode="$1"
    _ctx_active_context="${AI_CTX_PROFILES:-}"
    _ctx_active_custom_dirs="${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-}"
    case "$1" in
        global-user)
            if [ -n "${COPILOT_HOME+x}" ]; then
                _ctx_active_home_was_set=1
                _ctx_active_home_value="$COPILOT_HOME"
            else
                _ctx_active_home_was_set=0
                _ctx_active_home_value=""
            fi
            ;;
        ephemeral-clean)
            _ctx_active_home_was_set=1
            _ctx_active_home_value="${COPILOT_HOME:-}"
            ;;
        *)
            _ctx_active_home_was_set=0
            _ctx_active_home_value=""
            ;;
    esac
}

_ctx_reset_active_record() {
    _ctx_active_mode=""
    _ctx_active_context=""
    _ctx_active_custom_dirs=""
    _ctx_active_home_was_set=0
    _ctx_active_home_value=""
}

_ctx_report_retained_ephemeral_home() {
    # $1: the retained ephemeral home path (never deleted by ctx).
    printf 'ctx: retained ephemeral COPILOT_HOME (not deleted): %s — may contain Copilot auth/session/cache data; moving any needed data out is the user\x27s or workflow\x27s responsibility; it consumes disk until the directory is manually removed\n' "$1"
}

_ctx_ctx_file_has_noautoload() {
    # Returns 0 (true) when the given .ctx file contains a bare "noautoload"
    # directive (case-insensitive). Deliberately independent of
    # _ctx_parse_ctx_file (which fully validates the file and can fail) so
    # the auto-load hook can always honor the flag even on an otherwise
    # invalid .ctx file.
    local ctx_file="$1"
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$(_ctx_lowercase "$line")" in
            noautoload) return 0 ;;
        esac
    done < "$ctx_file"
    return 1
}

_ctx_find_ctx_file() {
    # Search from $PWD upward to the filesystem root for a ".ctx" file.
    local dir="$PWD"
    while [ -n "$dir" ]; do
        if [ -f "$dir/.ctx" ]; then
            printf '%s\n' "$dir/.ctx"
            return 0
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

_ctx_auto_load_hook() {
    [ "${CTX_AUTO_LOAD:-1}" = "0" ] && return 0

    local ctx_file
    if ctx_file="$(_ctx_find_ctx_file)"; then
        local dir_of_file
        dir_of_file="$(dirname "$ctx_file")"
        if _ctx_ctx_file_has_noautoload "$ctx_file"; then
            # File explicitly opts out of auto-loading. If we previously
            # had this file loaded (e.g. flag was added after loading),
            # clear it now and forget the directory so we don't linger.
            if [ "$_ctx_auto_load_dir" = "$dir_of_file" ]; then
                _ctx_clear
                _ctx_auto_load_dir=""
            fi
            return 0
        fi
        if [ "$_ctx_auto_load_dir" != "$dir_of_file" ]; then
            if _ctx_load_ctx_file "$ctx_file" noworkspace; then
                _ctx_auto_load_dir="$dir_of_file"
            else
                # Propagate the loader's failure so direct hook callers (and
                # tests) can observe that the auto-load did not succeed. The
                # status reaches the invoking shell hook and can become the
                # shell prompt-command status, so callers that must not
                # surface it should discard it explicitly.
                return $?
            fi
        fi
    else
        if [ -n "$_ctx_auto_load_dir" ]; then
            _ctx_clear
            _ctx_auto_load_dir=""
        fi
    fi
}

_ctx_copilot_home_root() {
    printf '%s\n' "${AI_CTX_PROFILES_CONFIG_ROOT:+}" >/dev/null # no-op, keeps shellcheck quiet about unused pattern
    printf '%s\n' "${AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT:-$HOME/.config/ctx/homes}"
}

_ctx_sanitize_context_name() {
    # Sanitizes a context name for safe use as a single path component.
    # '+' is already filesystem-safe and left as-is. Every disallowed
    # Unicode character is replaced with exactly one '_', decoding UTF-8
    # bytes independent of locale so bash/zsh match PowerShell (issue #48):
    # ASCII letters/digits/'.'/'_'/'-'/'+' are kept, disallowed ASCII bytes
    # become '_', and each non-ASCII character (one UTF-8 lead byte plus its
    # continuation bytes) becomes a single '_'. Uses POSIX `od` only; no
    # locale-sensitive pattern matching or byte-oriented tr. Allowed bytes
    # are re-encoded with printf '%b' using the \0NNN octal form, which both
    # bash and zsh decode (the bare \NNN form is left literal by zsh).
    local name="$1" out="" b
    for b in $(printf '%s' "$name" | od -An -v -tu1); do
        if { [ "$b" -ge 48 ] && [ "$b" -le 57 ]; } \
           || { [ "$b" -ge 65 ] && [ "$b" -le 90 ]; } \
           || { [ "$b" -ge 97 ] && [ "$b" -le 122 ]; } \
           || [ "$b" -eq 43 ] || [ "$b" -eq 45 ] || [ "$b" -eq 46 ] || [ "$b" -eq 95 ]; then
            out="$out$(printf '%b' "\\0$(printf '%03o' "$b")")"
        elif [ "$b" -ge 128 ] && [ "$b" -le 191 ]; then
            # UTF-8 continuation byte; already counted by its lead byte.
            :
        else
            # Disallowed ASCII byte, or the lead byte of a non-ASCII character.
            out="${out}_"
        fi
    done
    printf '%s' "$out"
}

_ctx_profile_is_canonical() {
    # A resolved profile directory is canonical when it has a root-level
    # AGENTS.md; otherwise it keeps legacy behavior (issue #48).
    [ -f "$1/AGENTS.md" ]
}

_ctx_canonical_profile_within_root() {
    # A canonical profile must physically resolve beneath the configured or
    # explicitly trusted external profiles root. Symlinks are followed in
    # both paths; intermediate symlink/.. components are resolved by realpath.
    local profile_dir="$1" profiles_root external_root root root_canonical profile_canonical
    profiles_root="$(_ctx_root)/profiles"
    external_root="$(_ctx_external_profiles_root)" || return 1
    profile_canonical="$(realpath -m -- "$profile_dir" 2>/dev/null)" || return 1
    for root in "$profiles_root" "$external_root"; do
        [ -n "$root" ] || continue
        root_canonical="$(realpath -m -- "$root" 2>/dev/null)" || return 1
        case "$profile_canonical" in
            "$root_canonical"/*) return 0 ;;
        esac
    done
    return 1
}

_ctx_in_list() {
    # $1: needle; remaining args: list. Returns 0 when the needle is present.
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

_ctx_valid_projection_name() {
    # Returns 0 when $1 matches the manifest grammar
    # <4+ ASCII digits>-<A-Za-z0-9+._->.instructions.md. The bracket ranges
    # are evaluated under LC_ALL=C so a locale's collation rules cannot admit
    # non-ASCII characters (which would otherwise pass [a-z] under a UTF-8
    # locale in some shells); the caller's locale is restored afterwards.
    local name="$1" stem digits label saved_lc_all="${LC_ALL-}" lc_all_set=0 fail=0
    [ -n "${LC_ALL+x}" ] && lc_all_set=1
    export LC_ALL=C
    case "$name" in
        *.instructions.md) stem="${name%.instructions.md}" ;;
        *) fail=1 ;;
    esac
    if [ "$fail" -eq 0 ]; then
        case "$stem" in
            *-*) : ;;
            *) fail=1 ;;
        esac
    fi
    if [ "$fail" -eq 0 ]; then
        digits="${stem%%-*}"
        label="${stem#*-}"
        [ "${#digits}" -ge 4 ] || fail=1
    fi
    if [ "$fail" -eq 0 ]; then
        case "$digits" in *[!0-9]*) fail=1 ;; esac
    fi
    if [ "$fail" -eq 0 ]; then
        [ -n "$label" ] || fail=1
    fi
    if [ "$fail" -eq 0 ]; then
        case "$label" in *[!A-Za-z0-9+._-]*) fail=1 ;; esac
    fi
    if [ "$lc_all_set" -eq 1 ]; then export LC_ALL="$saved_lc_all"; else unset LC_ALL; fi
    return "$fail"
}

_ctx_projection_basename() {
    # $1: one-based selection order, $2: raw label.
    printf '%04d-%s.instructions.md' "$1" "$(_ctx_sanitize_context_name "$2")"
}

_ctx_project_instructions() {
    # $1: COPILOT_HOME. Remaining args: triples "order label source-dir".
    # Reconciles the desired canonical instruction projections transactionally:
    # all source bytes are read and staged in one uniquely created per-call
    # staging directory before any target or manifest is changed; the
    # .ctx-managed manifest is expanded to cover old managed plus all desired
    # names before any target replacement; and stale targets are pruned and the
    # manifest shrunk only after all desired writes succeed. An interrupted run
    # therefore leaves only managed, retryable state. Fails closed on
    # unsafe/malformed/unmanaged state, and no step clobbers an existing file
    # with `>` (noclobber-safe). Target replacement uses rename, which never
    # follows a link at the destination. Only the current invocation's staging
    # directory is ever removed; no user files are swept by wildcard.
    local home_dir="$1"; shift
    local -a args=("$@")
    local proj_dir="$home_dir/instructions/ctx-profiles"
    local parent_dir="$home_dir/instructions"
    local manifest="$proj_dir/.ctx-managed"

    local -a desired=()
    local order label source name
    set -- "${args[@]}"
    while [ "$#" -gt 0 ]; do
        order="$1"; label="$2"; source="$3"; shift 3
        desired+=("$(_ctx_projection_basename "$order" "$label")")
    done

    # No canonical entries and no ctx manifest is a pure no-op: the
    # instructions directory may be user-owned or an unrelated linked path, so
    # it is neither validated nor touched.
    if [ "${#desired[@]}" -eq 0 ] && [ ! -e "$manifest" ]; then
        return 0
    fi

    local item
    for item in "$parent_dir" "$proj_dir"; do
        if [ -L "$item" ] || { [ -e "$item" ] && [ ! -d "$item" ]; }; then
            printf 'ctx: error: unsafe projection directory: %s\n' "$item" >&2
            return 1
        fi
    done

    local -a managed=()
    if [ -L "$manifest" ]; then
        printf 'ctx: error: malformed projection manifest: %s\n' "$manifest" >&2
        return 1
    fi
    if [ -e "$manifest" ]; then
        if [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
            printf 'ctx: error: malformed projection manifest: %s\n' "$manifest" >&2
            return 1
        fi
        local line
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            [ -z "$line" ] && continue
            if ! _ctx_valid_projection_name "$line"; then
                printf 'ctx: error: malformed projection manifest: %s\n' "$manifest" >&2
                return 1
            fi
            managed+=("$line")
        done < "$manifest"
    fi

    for name in "${desired[@]}"; do
        if [ -e "$proj_dir/$name" ] || [ -L "$proj_dir/$name" ]; then
            if ! _ctx_in_list "$name" "${managed[@]}"; then
                # Not managed under this exact spelling. It may be a filesystem
                # alias (case-insensitive filesystem) of a managed projection;
                # only an exact existing managed spelling that resolves to the
                # same file is treated as managed. Never guessed.
                local managed_alias=0 m2
                for m2 in "${managed[@]}"; do
                    if _ctx_same_file "$proj_dir/$name" "$proj_dir/$m2"; then managed_alias=1; break; fi
                done
                if [ "$managed_alias" -eq 0 ]; then
                    printf 'ctx: error: unmanaged projection file exists and is not in the manifest: %s\n' "$proj_dir/$name" >&2
                    return 1
                fi
            fi
            if [ -L "$proj_dir/$name" ] || [ ! -f "$proj_dir/$name" ]; then
                printf 'ctx: error: unsafe managed projection target (must be a regular non-link file): %s\n' "$proj_dir/$name" >&2
                return 1
            fi
        fi
    done

    if [ "${#desired[@]}" -gt 0 ] && [ ! -d "$proj_dir" ]; then
        mkdir -p "$proj_dir" || {
            printf 'ctx: error: could not create projection directory: %s\n' "$proj_dir" >&2
            return 1
        }
    fi

    # Phase 1: create one uniquely named per-transaction staging directory
    # inside the projection directory (so renames stay on the same filesystem)
    # and stage every desired output inside it. All source bytes are read
    # before any target or manifest is changed; a missing/unreadable source
    # aborts with no mutation. Only this invocation's staging directory is ever
    # removed; leftover directories from a crash are ignored safely, and no
    # user files are swept by wildcard.
    local tmpdir=""
    if [ "${#desired[@]}" -gt 0 ]; then
        tmpdir="$(mktemp -d "$proj_dir/.ctx-txn.XXXXXX" 2>/dev/null)" || {
            printf 'ctx: error: could not create staging directory in %s\n' "$proj_dir" >&2
            return 1
        }
    fi
    set -- "${args[@]}"
    while [ "$#" -gt 0 ]; do
        order="$1"; label="$2"; source="$3"; shift 3
        name="$(_ctx_projection_basename "$order" "$label")"
        if [ ! -f "$source/AGENTS.md" ]; then
            printf 'ctx: error: could not read projection source: %s\n' "$source/AGENTS.md" >&2
            [ -n "$tmpdir" ] && rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        fi
        if ! { printf -- '---\napplyTo: "**"\n---\n\n'; cat -- "$source/AGENTS.md"; } > "$tmpdir/$name" 2>/dev/null; then
            printf 'ctx: error: could not stage projection: %s\n' "$name" >&2
            [ -n "$tmpdir" ] && rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        fi
    done

    # Phase 2: expand the manifest to cover old managed plus all desired names
    # before any target replacement, so a partially completed run stays
    # recoverable. Written via a temp file + rename (never clobbered in place);
    # every write/move is checked and only this transaction's staging
    # directory is cleaned, preserving the previous valid manifest on failure.
    if [ "${#desired[@]}" -gt 0 ]; then
        local -a union=()
        local m
        for m in "${managed[@]}"; do
            if ! _ctx_in_list "$m" "${union[@]}"; then union+=("$m"); fi
        done
        for name in "${desired[@]}"; do
            if ! _ctx_in_list "$name" "${union[@]}"; then union+=("$name"); fi
        done
        if ! printf '%s\n' "${union[@]}" > "$tmpdir/manifest" 2>/dev/null; then
            printf 'ctx: error: could not write projection manifest: %s\n' "$manifest" >&2
            rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        fi
        mv -f -- "$tmpdir/manifest" "$manifest" || {
            printf 'ctx: error: could not write projection manifest: %s\n' "$manifest" >&2
            rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        }
    fi

    # Phase 3: replace each target with its completed temp via rename; rename
    # replaces the destination entry itself and never follows a link there.
    set -- "${args[@]}"
    while [ "$#" -gt 0 ]; do
        order="$1"; label="$2"; source="$3"; shift 3
        name="$(_ctx_projection_basename "$order" "$label")"
        if ! mv -f -- "$tmpdir/$name" "$proj_dir/$name" 2>/dev/null; then
            printf 'ctx: error: could not write projection: %s\n' "$proj_dir/$name" >&2
            rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        fi
    done

    # Phase 4: only after all desired writes succeeded, prune stale managed
    # projections that are no longer selected. Every removal is checked; a
    # failure (including a directory/non-regular stale target, which is never
    # deleted recursively) aborts while keeping the expanded union manifest so
    # a retry remains possible. A stale name that is only a case-alias of a
    # desired file on a case-insensitive filesystem is not deleted.
    local m
    for m in "${managed[@]}"; do
        if ! _ctx_in_list "$m" "${desired[@]}"; then
            local stale="$proj_dir/$m" skip_stale=0 d2
            for d2 in "${desired[@]}"; do
                if _ctx_same_file "$stale" "$proj_dir/$d2"; then skip_stale=1; break; fi
            done
            [ "$skip_stale" -eq 1 ] && continue
            if [ -e "$stale" ] && [ ! -L "$stale" ] && [ ! -f "$stale" ]; then
                printf 'ctx: error: refusing to remove non-regular stale projection: %s\n' "$stale" >&2
                rm -rf -- "$tmpdir" 2>/dev/null
                return 1
            fi
            if [ -e "$stale" ] || [ -L "$stale" ]; then
                rm -f -- "$stale" || {
                    printf 'ctx: error: could not remove stale projection: %s\n' "$stale" >&2
                    rm -rf -- "$tmpdir" 2>/dev/null
                    return 1
                }
            fi
        fi
    done

    # Phase 5: shrink the manifest to the desired set; an empty desired set
    # removes the manifest and any now-empty directories it owns. Removal and
    # writes are checked: a failure returns an error instead of silently
    # claiming success with stale manifest state.
    if [ "${#desired[@]}" -eq 0 ]; then
        rm -f -- "$manifest" || {
            printf 'ctx: error: could not remove projection manifest: %s\n' "$manifest" >&2
            [ -n "$tmpdir" ] && rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        }
        rmdir "$proj_dir" 2>/dev/null || true
        rmdir "$parent_dir" 2>/dev/null || true
    else
        if ! printf '%s\n' "${desired[@]}" > "$tmpdir/manifest" 2>/dev/null; then
            printf 'ctx: error: could not write projection manifest: %s\n' "$manifest" >&2
            rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        fi
        mv -f -- "$tmpdir/manifest" "$manifest" || {
            printf 'ctx: error: could not write projection manifest: %s\n' "$manifest" >&2
            rm -rf -- "$tmpdir" 2>/dev/null
            return 1
        }
    fi
    [ -n "$tmpdir" ] && rm -rf -- "$tmpdir" 2>/dev/null
    return 0
}

_ctx_skill_source_dirs() {
    # Prints candidate skill directories for a resolved profile directory:
    # canonical profiles use .agents/skills/<name> with a regular non-link
    # SKILL.md; legacy profiles use .github/skills as before (issue #48).
    local rd="$1" skill_root s
    if _ctx_profile_is_canonical "$rd"; then
        skill_root="$rd/.agents/skills"
        [ -d "$skill_root" ] || return 0
        while IFS= read -r s; do
            [ -f "$s/SKILL.md" ] && [ ! -L "$s/SKILL.md" ] || continue
            printf '%s\n' "$s"
        done < <(find "$skill_root" -mindepth 1 -maxdepth 1 -type d -print)
    else
        skill_root="$rd/.github/skills"
        [ -d "$skill_root" ] || return 0
        find "$skill_root" -mindepth 1 -maxdepth 1 -type d -print
    fi
}

_ctx_validate_home_path() {
    # Print the canonical, safe path. Custom homes may only be descendants
    # of HOME or AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT; existing symlink components are forbidden.
    local candidate="$1" canonical root root_canonical part prefix rest
    [ -n "$candidate" ] || { printf 'ctx: error: unsafe home: empty path\n' >&2; return 1; }
    case "$candidate" in /*) ;; *) printf 'ctx: error: unsafe home: path is not absolute: %s\n' "$candidate" >&2; return 1 ;; esac
    canonical="$(realpath -m -- "$candidate" 2>/dev/null)" || { printf 'ctx: error: unsafe home: %s\n' "$candidate" >&2; return 1; }
    [ "$canonical" != "/" ] || { printf 'ctx: error: unsafe home: filesystem root\n' >&2; return 1; }
    local allowed=1 root_is_candidate=0
    for root in "$HOME" "${AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT:-}"; do
        [ -n "$root" ] || continue
        root_canonical="$(realpath -m -- "$root" 2>/dev/null)" || continue
        if [ "$canonical" = "$root_canonical" ]; then root_is_candidate=1; fi
        if [ "$canonical" != "$root_canonical" ] && [[ "$canonical" == "$root_canonical"/* ]]; then allowed=0; fi
    done
    [ "$root_is_candidate" -eq 0 ] || { printf 'ctx: error: unsafe home: %s is an allowed root, not a descendant\n' "$candidate" >&2; return 1; }
    [ "$allowed" -eq 0 ] || { printf 'ctx: error: unsafe home: %s is outside HOME/AI_CTX_PROFILES_SYNTHETIC_HOMES_ROOT\n' "$candidate" >&2; return 1; }
    rest="${candidate#/}"; prefix="/"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        if [ "$rest" = "$part" ]; then rest=""; else rest="${rest#*/}"; fi
        [ -n "$part" ] || continue
        prefix="${prefix%/}/$part"
        [ ! -L "$prefix" ] || { printf 'ctx: error: unsafe home: symlink component in %s\n' "$candidate" >&2; return 1; }
    done
    printf '%s\n' "$canonical"
}

_ctx_validate_copilot_mode() {
    # Select and validate the active Copilot integration mode. Accepts
    # exactly synthetic-home | global-user | ephemeral-clean,
    # case-sensitively; unset/empty defaults to synthetic-home (today's
    # behavior). Prints the active mode to stdout and returns 0, or prints
    # ctx: error: ... to stderr and returns 1.
    local mode="${AI_CTX_PROFILES_COPILOT_MODE:-synthetic-home}"
    case "$mode" in
        synthetic-home|global-user|ephemeral-clean) : ;;
        *)
            printf 'ctx: error: invalid AI_CTX_PROFILES_COPILOT_MODE "%s" (allowed values: synthetic-home, global-user, ephemeral-clean)\n' "$mode" >&2
            return 1 ;;
    esac
    printf '%s\n' "$mode"
}

_ctx_mode_label() {
    # Maps a mode selector value to its user-facing letter/name label used by
    # ctx current and ctx check: A — synthetic-home, B — global-user,
    # C — ephemeral-clean. Selector values themselves are unchanged.
    case "$1" in
        synthetic-home) printf 'A — synthetic-home\n' ;;
        global-user) printf 'B — global-user\n' ;;
        ephemeral-clean) printf 'C — ephemeral-clean\n' ;;
        *) return 1 ;;
    esac
}

_ctx_warn_global_user_copilot_home() {
    # Mode B never sets, unsets, or otherwise changes COPILOT_HOME; it only
    # reads the existing value (including empty) to warn that it is preserved.
    # Emitted to stderr after a successful Mode B activation only — never in
    # Modes A/C, on a failed activation, or from read-only commands.
    # $1: the mode that actually activated.
    if [ "$1" = "global-user" ] && [ -n "${COPILOT_HOME+x}" ]; then
        printf 'ctx: warning: global-user mode preserves the existing COPILOT_HOME: "%s". This may point to a synthetic home from a previous ctx activation.\n' "$COPILOT_HOME" >&2
    fi
}

_ctx_compute_skills_dirs_csv() {
    # Computes the COPILOT_SKILLS_DIRS value for Modes B/C: the existing
    # <resolved-dir>/.github/skills directories of the given resolved dirs,
    # in the same stable order they are given, comma-joined. Prints nothing
    # when zero such directories exist. Side-effect-free: on failure prints
    # ctx: error to stderr and returns 1, rejecting the whole activation
    # before any state change.
    local rd skill_dir csv=""
    for rd in "$@"; do
        skill_dir="$rd/.github/skills"
        [ -d "$skill_dir" ] || continue
        case "$skill_dir" in
            *,*)
                printf 'ctx: error: COPILOT_SKILLS_DIRS path contains a literal comma: %s\n' "$skill_dir" >&2
                return 1 ;;
        esac
        [ -z "$csv" ] && csv="$skill_dir" || csv="$csv,$skill_dir"
    done
    printf '%s\n' "$csv"
}

# List of files
# symlinked back to the real ~/.copilot so global auth/config/session
# history keep working identically across all contexts. This is also the
# authoritative list the 3.4a reconciliation loop walks on every
# activation to detect + repair a symlink that Copilot CLI silently
# replaced with a plain file via rename(tmp, path).
_ctx_copilot_home_shared_files() {
    cat <<'EOF'
settings.json
config.json
mcp-config.json
session-store.db
session-store.db-shm
session-store.db-wal
EOF
}

# Directories symlinked back to the real ~/.copilot the same way (treated
# defensively with the same reconciliation, even though only files were
# empirically observed broken - see plan section 3.4a).
_ctx_copilot_home_shared_dirs() {
    cat <<'EOF'
session-state
installed-plugins
logs
EOF
}

_ctx_reconcile_symlink() {
    # Ensures $home_dir/$name is a symlink pointing at $real_target,
    # self-healing the confirmed rename()-through-symlink hazard (plan
    # 3.4a): if Copilot CLI (or anything else) replaced the symlink with
    # a plain file/dir holding new data, that data is copied back onto
    # the real ~/.copilot target *before* the symlink is recreated, so
    # the most recent write is preserved rather than silently lost.
    #
    # $1: home_dir   $2: name (relative path under home_dir)
    # $3: real_target (absolute path under ~/.copilot)
    # $4: kind - "file" or "dir"
    local home_dir="$1" name="$2" real_target="$3" kind="$4"
    local link_path="$home_dir/$name"

    if [ -L "$link_path" ]; then
        local current_target
        current_target="$(readlink "$link_path")"
        if [ "$current_target" = "$real_target" ]; then
            # Already correct; no-op (idempotency, plan 3.4).
            return 0
        fi
        # Stale/incorrect symlink target - remove and recreate below.
        rm -f "$link_path"
    elif [ -e "$link_path" ]; then
        # Not a symlink but exists: the confirmed hazard from 3.4a - the
        # CLI's write-tmp+rename() replaced our symlink with a real file
        # (or, defensively, a real dir) holding this context's latest
        # data. Copy it over the real target so the write is not lost,
        # then remove it and recreate the symlink.
        mkdir -p "$(dirname "$real_target")"
        if [ "$kind" = "dir" ]; then
            rm -rf "$real_target"
            cp -a "$link_path" "$real_target"
            rm -rf "$link_path"
        else
            cp -f "$link_path" "$real_target"
            rm -f "$link_path"
        fi
    fi

    if [ ! -e "$link_path" ]; then
        mkdir -p "$(dirname "$link_path")"
        if [ "$kind" = "dir" ]; then
            mkdir -p "$real_target"
        else
            mkdir -p "$(dirname "$real_target")"
            [ -e "$real_target" ] || : > "$real_target"
        fi
        if ! ln -s "$real_target" "$link_path" 2>/dev/null; then
            printf 'ctx: warning: could not create symlink %s -> %s\n' "$link_path" "$real_target" >&2
            return 1
        fi
    fi
    return 0
}

_ctx_create_ephemeral_copilot_home() {
    # Mode C (ephemeral-clean): creates a brand-new, unique, empty
    # COPILOT_HOME on every call via mktemp -d. Never reused, never
    # looked up by name. No symlinks/copies to or from the real
    # ~/.copilot, no reconciliation, no skills/ subfolder. Prints the
    # created path and returns 0, or prints ctx: error to stderr and
    # returns 1. Side-effect-free on the environment so callers can
    # preflight Mode C home creation before any state change.
    local home_dir
    home_dir="$(mktemp -d "${TMPDIR:-/tmp}/ctx-ephemeral.XXXXXXXXXX" 2>/dev/null)" || {
        printf 'ctx: error: could not create ephemeral COPILOT_HOME (mktemp failed)\n' >&2
        return 1
    }
    if [ -L "$home_dir" ]; then
        printf 'ctx: error: ephemeral COPILOT_HOME path is a symlink, refusing: %s\n' "$home_dir" >&2
        return 1
    fi
    printf '%s\n' "$home_dir"
    return 0
}

_ctx_setup_copilot_home() {
    # $1: context-name (raw, e.g. "review+test")
    # $2: home-dir override (absolute path) or "" to use the centralized
    #     default. Set via the .ctx file's optional "home:<path>" directive
    #     (issue #7); manual "ctx <profile>..." invocations always pass "".
    # remaining args: resolved directories for the active context
    local context_name="$1"
    local home_override="$2"
    shift 2
    local -a resolved_dirs=("$@")

    local sanitized homes_root home_dir copilot_dir
    if [ -n "$home_override" ]; then
        home_dir="$home_override"
    else
        sanitized="$(_ctx_sanitize_context_name "$context_name")"
        homes_root="$(_ctx_copilot_home_root)"
        home_dir="$homes_root/$sanitized"
    fi
    copilot_dir="${CTX_COPILOT_DIR:-$HOME/.copilot}"

    # Canonical instruction projection is validated/reconciled before any
    # other mutation so an unsafe/unmanaged projection fails the whole
    # activation atomically (issue #48).
    _ctx_project_instructions "$home_dir" "${_ctx_canon_args[@]}" || return 1

    mkdir -p "$home_dir/skills" || {
        printf 'ctx: warning: could not create %s; leaving COPILOT_HOME unset\n' "$home_dir" >&2
        return 1
    }
    mkdir -p "$copilot_dir" 2>/dev/null || true

    local ok=1
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        _ctx_reconcile_symlink "$home_dir" "$f" "$copilot_dir/$f" "file" || ok=0
    done <<EOF
$(_ctx_copilot_home_shared_files)
EOF

    local d
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        _ctx_reconcile_symlink "$home_dir" "$d" "$copilot_dir/$d" "dir" || ok=0
    done <<EOF
$(_ctx_copilot_home_shared_dirs)
EOF

    if [ "$ok" -ne 1 ]; then
        printf 'ctx: warning: one or more COPILOT_HOME symlinks could not be created; leaving COPILOT_HOME unset for this session\n' >&2
        return 1
    fi

    # Reconcile skills/: desired (name -> target) pairs come from each
    # resolved dir's contracted skill source (.github/skills for legacy
    # profiles, .agents/skills for canonical profiles), if present. Skill
    # names are compared case-insensitively using the same canonical key as
    # PowerShell's ToLowerInvariant() (COPILOT_HOME targets are
    # case-insensitive on Windows), so two source dirs contributing "foo"
    # and "Foo" collide and the whole colliding group is skipped (issue #40).
    local -A desired_skills=() desired_skill_names=() collided_skills=() collided_contribs=()
    local -a desired_skill_order=() collided_skill_order=()
    local rd sname lcname
    for rd in "${resolved_dirs[@]}"; do
        local s
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            sname="$(basename "$s")"
            if ! lcname="$(_ctx_skill_canonical_name "$sname")"; then
                return 1
            fi
            if [ -n "${collided_skills[$lcname]+set}" ]; then
                collided_contribs[$lcname]="${collided_contribs[$lcname]}, $rd"
            elif [ -n "${desired_skills[$lcname]+set}" ]; then
                collided_skills[$lcname]=1
                collided_skill_order+=("$lcname")
                collided_contribs[$lcname]="${collided_contribs[$lcname]}, $rd"
                unset "desired_skills[$lcname]"
            else
                desired_skills[$lcname]="${s%/}"
                desired_skill_names[$lcname]="$sname"
                desired_skill_order+=("$lcname")
                collided_contribs[$lcname]="$rd"
            fi
        done < <(_ctx_skill_source_dirs "$rd")
    done

    local cname
    for cname in "${collided_skill_order[@]}"; do
        printf 'ctx: warning: skill name collision "%s" from: %s; skipping all of them\n' "$cname" "${collided_contribs[$cname]}" >&2
    done

    # Remove stale skill symlinks no longer in desired set (a colliding
    # group is skipped, so any stale link of theirs is removed too).
    if [ -d "$home_dir/skills" ]; then
        local existing ename existing_lc
        while IFS= read -r existing; do
            ename="$(basename "$existing")"
            if ! existing_lc="$(_ctx_skill_canonical_name "$ename")"; then
                return 1
            fi
            if [ -z "${desired_skills[$existing_lc]:-}" ]; then
                # Skills are directory symlinks; rm -rf mirrors
                # _ctx_reconcile_symlink and the PowerShell equivalent
                # (Remove-Item -Recurse -Force).
                rm -rf "$existing"
            fi
        done < <(find "$home_dir/skills" -mindepth 1 -maxdepth 1 -print)
    fi

    # Create/repair desired skill symlinks (idempotent). Names that became a
    # collision are no longer desired and are skipped. Exactly one on-disk
    # spelling per canonical key is kept: link_ok is set only by the
    # enumerated entry whose on-disk spelling matches the desired one exactly
    # and which is a correct link, so a differently-cased entry that a
    # case-insensitive filesystem would alias can never suppress recreation of
    # the desired spelling; every other entry mapping to the same canonical
    # key is removed first (issue #40 P1).
    local name on_disk target link existing2 existing2_lc link_ok
    for name in "${desired_skill_order[@]}"; do
        [ -n "${desired_skills[$name]+set}" ] || continue
        on_disk="${desired_skill_names[$name]}"
        target="${desired_skills[$name]}"
        link="$home_dir/skills/$on_disk"
        link_ok=0
        while IFS= read -r existing2; do
            [ -n "$existing2" ] || continue
            if ! existing2_lc="$(_ctx_skill_canonical_name "$(basename "$existing2")")"; then
                return 1
            fi
            if [ "$existing2_lc" = "$name" ]; then
                if [ "$existing2" = "$link" ] && [ -L "$existing2" ] && [ "$(readlink "$existing2")" = "$target" ]; then
                    link_ok=1
                else
                    rm -rf "$existing2"
                fi
            fi
        done < <(find "$home_dir/skills" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
        if [ "$link_ok" -eq 1 ]; then
            continue
        fi
        if ! ln -s "$target" "$link" 2>/dev/null; then
            printf 'ctx: warning: could not create skill symlink %s -> %s\n' "$link" "$target" >&2
        fi
    done

    export COPILOT_HOME="$home_dir"
    return 0
}

_ctx_update_skill_directories() {
    # Merges the given skill directories (remaining args) into the
    # "skillDirectories" array of .github/copilot/settings.local.json located
    # under $1 (the directory containing the .ctx file). Creates the file
    # (and any missing parent directories) if it does not already exist.
    # Preserves any other keys, and any pre-existing skillDirectories entries,
    # already in the file.
    local base_dir="$1"
    shift
    [ "$#" -eq 0 ] && return 0

    local settings_dir="$base_dir/.github/copilot"
    local settings_file="$settings_dir/settings.local.json"

    local python_bin=""
    if command -v python3 >/dev/null 2>&1; then
        python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        python_bin="python"
    else
        printf 'ctx: warning: python3 not found; cannot update %s with skill directories\n' "$settings_file" >&2
        return 0
    fi

    mkdir -p "$settings_dir"

    "$python_bin" - "$settings_file" "$@" <<'PYEOF'
import json
import sys

settings_file = sys.argv[1]
new_dirs = sys.argv[2:]

settings = {}
try:
    with open(settings_file, "r", encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            settings = json.loads(content)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

if not isinstance(settings, dict):
    settings = {}

existing = settings.get("skillDirectories") or []
if not isinstance(existing, list):
    existing = []

merged = list(dict.fromkeys(existing + new_dirs))
settings["skillDirectories"] = merged

with open(settings_file, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
}

_ctx_update_workspace_file() {
    # Creates/updates a "<folder-name>.code-workspace" file next to the .ctx
    # file (under $1, the directory containing the .ctx file) so the project
    # and its .ctx dependencies can be browsed together in VS Code: this
    # folder is added as "root: <name>", and each .ctx entry (remaining
    # args, given as alternating name/path pairs) is added as
    # "ctx: <context-name>". Folders not generated by ctx (i.e. not named
    # "root: ..." / "ctx: ...") are left untouched; other top-level keys
    # (settings, extensions, ...) already in the file are preserved.
    local base_dir="$1"
    shift
    local folder_name
    folder_name="$(basename "$base_dir")"
    local workspace_file="$base_dir/$folder_name.code-workspace"

    local python_bin=""
    if command -v python3 >/dev/null 2>&1; then
        python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        python_bin="python"
    else
        printf 'ctx: warning: python3 not found; cannot update %s with workspace folders\n' "$workspace_file" >&2
        return 0
    fi

    "$python_bin" - "$workspace_file" "$folder_name" "$@" <<'PYEOF'
import json
import os
import sys

workspace_file = sys.argv[1]
folder_name = sys.argv[2]
rest = sys.argv[3:]
workspace_existed = os.path.exists(workspace_file)

pairs = [(rest[i], rest[i + 1]) for i in range(0, len(rest), 2)]

workspace = {}
try:
    with open(workspace_file, "r", encoding="utf-8") as f:
        content = f.read().strip()
        if content:
            workspace = json.loads(content)
except (FileNotFoundError, json.JSONDecodeError):
    workspace = {}

if not isinstance(workspace, dict):
    workspace = {}

existing = workspace.get("folders") or []
if not isinstance(existing, list):
    existing = []

user_folders = [
    f for f in existing
    if not (isinstance(f, dict) and isinstance(f.get("name"), str)
            and (f["name"].startswith("root: ") or f["name"].startswith("ctx: ")))
]

root_entry = {"path": ".", "name": f"root: {folder_name}"}
ctx_entries = [{"path": path, "name": f"ctx: {name}"} for name, path in pairs]

workspace["folders"] = [root_entry] + ctx_entries + user_folders
workspace.setdefault("settings", {})
if not workspace_existed:
    workspace["generatedBy"] = "ctx"

with open(workspace_file, "w", encoding="utf-8") as f:
    json.dump(workspace, f, indent=2)
    f.write("\n")
PYEOF
}

_ctx_parse_ctx_file() {
    # Side-effect-free parser shared by activation and read-only check. Results
    # are exposed in _ctx_parsed_* globals only after complete validation.
    local ctx_file="$1" dir_of_file line name entry_path resolved_path canonical_path profile_path label_lc
    local ai_context="" first_name="" home_override="" noautoload=0
    local -a dirs=() names=() pairs=()
    local -A seen_labels=() seen_targets=()
    _ctx_external_profiles_root >/dev/null || return 1
    # Normalize like cd/pwd so `ctx load ./task/.ctx`, auto-load, and check agree
    # and the workspace file is named after the folder, not "." (#75).
    dir_of_file="$(CDPATH= cd -- "$(dirname -- "$ctx_file")" && pwd)" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"; [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac
        case "$(_ctx_lowercase "$line")" in noautoload) noautoload=1; continue ;; esac
        case "$line" in *:*) : ;; *) printf 'ctx: error: invalid .ctx line in %s (expected <name>:<path>): %s\n' "$ctx_file" "$line" >&2; return 1 ;; esac
        name="${line%%:*}"; entry_path="${line#*:}"
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        entry_path="${entry_path#"${entry_path%%[![:space:]]*}"}"; entry_path="${entry_path%"${entry_path##*[![:space:]]}"}"
        if [ -z "$name" ] || [ -z "$entry_path" ]; then printf 'ctx: error: invalid .ctx line in %s (expected <name>:<path>): %s\n' "$ctx_file" "$line" >&2; return 1; fi
        label_lc="$(_ctx_lowercase "$name")"
        if [ "$label_lc" != home ]; then
            if [ -n "${seen_labels[$label_lc]+set}" ]; then printf 'ctx: error: duplicate .ctx entry label "%s"; first declared as "%s"\n' "$name" "${seen_labels[$label_lc]}" >&2; return 1; fi
            seen_labels[$label_lc]="$name"
        fi
        if [ "$entry_path" = '@profile' ]; then
            if ! profile_path="$(_ctx_resolve_profile_identifier "$name")"; then return 1; fi
            resolved_path="$profile_path"
        else
            case "$entry_path" in /*) resolved_path="$entry_path" ;; *) resolved_path="$dir_of_file/$entry_path" ;; esac
        fi
        if [ "$label_lc" = home ]; then
            if [ -n "$home_override" ]; then printf 'ctx: error: duplicate "home:" directive in %s\n' "$ctx_file" >&2; return 1; fi
            if ! home_override="$(_ctx_validate_home_path "$resolved_path")"; then return 1; fi
            continue
        fi
        if [ ! -d "$resolved_path" ]; then printf 'ctx: error: .ctx entry "%s" in %s points to missing directory: %s\n' "$name" "$ctx_file" "$resolved_path" >&2; return 1; fi
        if _ctx_profile_is_canonical "$resolved_path" && ! _ctx_canonical_profile_within_root "$resolved_path"; then
            printf 'ctx: error: canonical profile "%s" resolves outside the configured profiles root or trusted external profiles root: %s\n' "$name" "$resolved_path" >&2
            return 1
        fi
        canonical_path="$(realpath -m -- "$resolved_path" 2>/dev/null)" || return 1
        if [ -n "${seen_targets[$canonical_path]+set}" ]; then printf 'ctx: error: .ctx entries "%s" and "%s" resolve to the same directory\n' "${seen_targets[$canonical_path]}" "$name" >&2; return 1; fi
        # Store relative entries in realpath form (the kernel's own resolution and
        # the duplicate key above) so every caller derives the same string (#75).
        case "$entry_path" in /*) ;; *) resolved_path="$canonical_path" ;; esac
        seen_targets[$canonical_path]="$name"; names+=("$name"); dirs+=("$resolved_path"); pairs+=("$name" "$resolved_path")
        [ -z "$ai_context" ] && { ai_context="$name"; first_name="$name"; } || ai_context="$ai_context+$name"
    done < "$ctx_file"
    if [ "${#names[@]}" -eq 0 ]; then printf 'ctx: error: .ctx file is empty or invalid: %s\n' "$ctx_file" >&2; return 1; fi
    _ctx_parsed_dir="$dir_of_file"; _ctx_parsed_context="$ai_context"; _ctx_parsed_first_name="$first_name"; _ctx_parsed_home="$home_override"; _ctx_parsed_noautoload="$noautoload"
    _ctx_parsed_names=("${names[@]}"); _ctx_parsed_dirs=("${dirs[@]}"); _ctx_parsed_pairs=("${pairs[@]}")
}

_ctx_load_ctx_file() {
    # $2 (optional): pass "noworkspace" to skip the .code-workspace write.
    # Only the passive auto-load hook uses this; explicit `ctx load` always
    # generates/updates the workspace file (#30). Manual profile activation
    # (`ctx <profile>...`) never calls this function or the workspace writer
    # at all, before or after this change.
    local ctx_file="$1" skip_workspace="${2:-}" dirs_csv shared_csv mode skills_dirs_csv
    _ctx_parse_ctx_file "$ctx_file" || return 1
    mode="$(_ctx_validate_copilot_mode)" || return 1
    if [ -n "$_ctx_parsed_home" ] && [ "$mode" != "synthetic-home" ]; then
        printf 'ctx: error: "home:" directive is only valid in synthetic-home mode (active mode: %s); allowed values: synthetic-home, global-user, ephemeral-clean\n' "$mode" >&2
        return 1
    fi
    # Classify each ordered .ctx entry as canonical or legacy, then reject any
    # canonical entry under Modes B/C before any environment export, workspace
    # write, or Copilot-home setup/creation (issue #48).
    local -a legacy_dirs=() canon_labels=()
    _ctx_canon_args=()
    local _p_name _p_path _p_order=0
    local -a _pairs=("${_ctx_parsed_pairs[@]}")
    set -- "${_pairs[@]}"
    while [ "$#" -gt 0 ]; do
        _p_name="$1"; _p_path="$2"; shift 2
        _p_order=$((_p_order + 1))
        if _ctx_profile_is_canonical "$_p_path"; then
            _ctx_canon_args+=("$_p_order" "$_p_name" "$_p_path")
            canon_labels+=("$_p_name")
        else
            legacy_dirs+=("$_p_path")
        fi
    done
    if [ "${#canon_labels[@]}" -gt 0 ] && [ "$mode" != "synthetic-home" ]; then
        printf 'ctx: error: canonical profile(s) require synthetic-home mode (active mode: %s): %s\n' "$mode" "${canon_labels[*]}" >&2
        return 1
    fi
    dirs_csv="$(IFS=,; printf '%s' "${legacy_dirs[*]}")"
    # COPILOT_SKILLS_DIRS is computed/validated only in Modes B/C before any
    # state change; a comma in an included skills path rejects the activation.
    # Mode A must not run this new validation or otherwise change its parsing.
    local skills_dirs_csv=""
    if [ "$mode" = "global-user" ] || [ "$mode" = "ephemeral-clean" ]; then
        if ! skills_dirs_csv="$(_ctx_compute_skills_dirs_csv "${_ctx_parsed_dirs[@]}")"; then return 1; fi
    fi
    local new_home="" old_ephemeral_home=""
    if [ "$mode" = "ephemeral-clean" ]; then
        # Mode C: preflight home creation before any state change (including
        # the workspace-file write) so a failure leaves the previous context
        # and all files untouched.
        if ! new_home="$(_ctx_create_ephemeral_copilot_home)"; then return 1; fi
    fi
    if [ "$mode" = "synthetic-home" ]; then
        # Mode A: preflight home creation and link reconciliation before any
        # state change (including the workspace-file write) so a failure
        # leaves the previous context, COPILOT_HOME, and all files untouched.
        if ! _ctx_setup_copilot_home "$_ctx_parsed_context" "$_ctx_parsed_home" "${_ctx_parsed_dirs[@]}"; then return 1; fi
    fi
    if [ "$(_ctx_active_record_mode)" = "ephemeral-clean" ]; then
        # Remember the replaced Mode C home so its retained-path notice can be
        # printed only after the replacement below actually succeeds.
        old_ephemeral_home="$_ctx_active_home_value"
    fi
    [ "$skip_workspace" = "noworkspace" ] || _ctx_update_workspace_file "$_ctx_parsed_dir" "${_ctx_parsed_pairs[@]}"
    export AI_CTX_PROFILES="$_ctx_parsed_context" COPILOT_CUSTOM_INSTRUCTIONS_DIRS="$dirs_csv"
    case "$mode" in
        global-user)
            # Mode B: never set up or touch COPILOT_HOME at all.
            ;;
        synthetic-home)
            # Mode A: COPILOT_HOME was preflighted above before any state
            # change; no further setup needed here.
            ;;
        ephemeral-clean)
            export COPILOT_HOME="$new_home"
            ;;
    esac
    case "$mode" in
        global-user|ephemeral-clean)
            # B/C: export the freshly computed value; fully replaced each
            # activation, then record its exact state as ctx-owned this session.
            if [ -n "$skills_dirs_csv" ]; then
                export COPILOT_SKILLS_DIRS="$skills_dirs_csv"
            else
                unset COPILOT_SKILLS_DIRS
            fi
            _ctx_record_owned_skills_dirs
            ;;
        synthetic-home)
            # A: unset only a value that still matches what a prior B/C
            # activation in this session established; a user's own value is
            # never touched.
            _ctx_unset_owned_skills_dirs
            ;;
    esac
    _ctx_auto_load_home_override="$_ctx_parsed_home"
    # Publish the session record only after a fully successful activation.
    _ctx_set_active_record "$mode"
    _ctx_warn_global_user_copilot_home "$mode"
    if [ -n "$old_ephemeral_home" ]; then
        _ctx_report_retained_ephemeral_home "$old_ephemeral_home"
    fi
    if [ "$_ctx_parsed_context" = "$_ctx_parsed_first_name" ]; then shared_csv=""; else shared_csv="${_ctx_parsed_context#*+}"; shared_csv="${shared_csv//+/, }"; fi
    _ctx_print_status "$_ctx_parsed_first_name" "$shared_csv"
}
_ctx_check_skip_links_and_skills() {
    # Modes B/C and unattributable (no-record) state do not own the Mode-A
    # synthetic-home shared-link or skill-symlink trees; those checks report
    # CHECK SKIP rather than FAIL. $1 is unused (kept for parity with the
    # Mode A check); remaining args are the resolved .ctx dirs used to list
    # the desired skill names.
    shift
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        printf 'CHECK SKIP link:%s\n' "$f"
    done <<EOF
$(_ctx_copilot_home_shared_files)
$(_ctx_copilot_home_shared_dirs)
EOF
    local -A skip_desired=()
    local -a desired_names=()
    local rd s sname
    for rd in "$@"; do
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            sname="$(basename "$s")"
            [ -n "${skip_desired[$sname]+set}" ] || desired_names+=("$sname")
            skip_desired["$sname"]="${s%/}"
        done < <(_ctx_skill_source_dirs "$rd")
    done
    local sorted
    sorted="$(printf '%s\n' "${desired_names[@]}" | sort)"
    while IFS= read -r sname; do
        [ -n "$sname" ] || continue
        printf 'CHECK SKIP skill:%s\n' "$sname"
    done <<< "$sorted"
}

_ctx_check_instructions() {
    # Read-only canonical instruction audit. $1: expected COPILOT_HOME;
    # $2: recorded mode; remaining args: alternating "name source-dir" pairs.
    # Emits CHECK PASS/FAIL/SKIP instruction:<file>. B/C and unattributable
    # (no-record) states skip Mode-A-only projections.
    local expected_home="$1" recorded_mode="$2"; shift 2
    local -a entries=("$@")
    local n=${#entries[@]}

    if [ "$recorded_mode" != "synthetic-home" ]; then
        if [ "$n" -gt 0 ]; then
            set -- "${entries[@]}"
            while [ "$#" -gt 0 ]; do
                printf 'CHECK SKIP instruction:%s\n' "$1"
                shift 2
            done
        fi
        return 0
    fi

    local proj_dir="$expected_home/instructions/ctx-profiles"
    local parent_dir="$expected_home/instructions"
    local manifest="$proj_dir/.ctx-managed"
    local failures=0

    if [ -L "$parent_dir" ] || { [ -e "$parent_dir" ] && [ ! -d "$parent_dir" ]; } \
       || [ -L "$proj_dir" ] || { [ -e "$proj_dir" ] && [ ! -d "$proj_dir" ]; }; then
        if [ "$n" -gt 0 ]; then
            set -- "${entries[@]}"
            while [ "$#" -gt 0 ]; do
                printf 'CHECK FAIL instruction:%s\n' "$1"
                shift 2
            done
            return 1
        fi
        # No expected canonical entries: an unrelated (possibly linked)
        # instructions path without ctx manifest state is not an applicable
        # check; only a present ctx manifest is audited below.
    fi

    local -a managed=()
    local manifest_ok=1
    if [ -L "$manifest" ]; then
        manifest_ok=0
    elif [ -e "$manifest" ]; then
        if [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
            manifest_ok=0
        else
            local line
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%$'\r'}"
                [ -z "$line" ] && continue
                if ! _ctx_valid_projection_name "$line"; then manifest_ok=0; break; fi
                managed+=("$line")
            done < "$manifest"
        fi
    elif [ "$n" -gt 0 ]; then
        # A matching Mode A record with expected canonical entries requires a
        # readable manifest.
        manifest_ok=0
    fi
    # A malformed/unreadable/linked manifest is a CHECK FAIL even with zero
    # expected entries: ctx-owned state that cannot be trusted is never
    # silently accepted.
    if [ "$manifest_ok" -eq 0 ]; then
        printf 'CHECK FAIL instruction:manifest\n'
        return 1
    fi

    local -a expected_names=()
    local name source target
    set -- "${entries[@]}"
    while [ "$#" -gt 0 ]; do
        name="$1"; source="$2"; shift 2
        expected_names+=("$name")
        target="$proj_dir/$name"
        if _ctx_in_list "$name" "${managed[@]}" \
           && [ -f "$target" ] && [ ! -L "$target" ] \
           && { printf -- '---\napplyTo: "**"\n---\n\n'; cat -- "$source/AGENTS.md"; } | cmp -s - "$target"; then
            printf 'CHECK PASS instruction:%s\n' "$name"
        else
            printf 'CHECK FAIL instruction:%s\n' "$name"
            failures=$((failures + 1))
        fi
    done

    local m
    for m in "${managed[@]}"; do
        if ! _ctx_in_list "$m" "${expected_names[@]}"; then
            printf 'CHECK FAIL instruction:%s: stale projection\n' "$m"
            failures=$((failures + 1))
        fi
    done
    [ "$failures" -eq 0 ]
}

_ctx_check_skills_dirs() {
    # Modes B/C: audits COPILOT_SKILLS_DIRS against the expected stable CSV
    # derived from the existing .github/skills directories of the parsed .ctx
    # entries (same computation as activation). Emits CHECK PASS/FAIL; when
    # the expected CSV cannot be computed (e.g. a literal comma path) it emits
    # CHECK SKIP rather than guessing. Read-only.
    shift
    local expected_csv="" status=0
    expected_csv="$(_ctx_compute_skills_dirs_csv "$@" 2>/dev/null)" || status=$?
    if [ "$status" -ne 0 ]; then
        printf 'CHECK SKIP COPILOT_SKILLS_DIRS\n'
        return 0
    fi
    if [ -n "$expected_csv" ]; then
        if [ -n "${COPILOT_SKILLS_DIRS+x}" ] && [ "$COPILOT_SKILLS_DIRS" = "$expected_csv" ]; then
            printf 'CHECK PASS COPILOT_SKILLS_DIRS\n'
        else
            printf 'CHECK FAIL COPILOT_SKILLS_DIRS: expected %s, got %s\n' "$expected_csv" "${COPILOT_SKILLS_DIRS:-<unset>}"
            return 1
        fi
    elif [ -z "${COPILOT_SKILLS_DIRS+x}" ]; then
        printf 'CHECK PASS COPILOT_SKILLS_DIRS\n'
    else
        printf 'CHECK FAIL COPILOT_SKILLS_DIRS: expected <unset>, got %s\n' "$COPILOT_SKILLS_DIRS"
        return 1
    fi
    return 0
}

_ctx_check() {
    local ctx_file dir_of_file line name entry_path resolved_path home_override=""
    local expected_context="" expected_dirs="" first=1 profile_lookup
    local -a names=() dirs=()
    local failures=0
    local recorded_mode="" selector_mode=""
    local -A seen_labels=() seen_targets=()
    local -a legacy_dirs=() canon_entries=()
    local _p_name _p_path _p_order=0

    if ! ctx_file="$(_ctx_find_ctx_file)"; then
        printf 'ctx check: no .ctx file found; nothing to check\n'
        return 0
    fi
    if ! _ctx_parse_ctx_file "$ctx_file"; then
        printf 'CHECK FAIL parser: invalid .ctx file\n'
        return 1
    fi
    dir_of_file="$_ctx_parsed_dir"; expected_context="$_ctx_parsed_context"; home_override="$_ctx_parsed_home"
    names=("${_ctx_parsed_names[@]}"); dirs=("${_ctx_parsed_dirs[@]}")
    # Canonical entries are never listed in COPILOT_CUSTOM_INSTRUCTIONS_DIRS;
    # expected_dirs is therefore the ordered legacy roots only. A canonical
    # entry's expected projection is keyed by its one-based selection order.
    local -a _pairs=("${_ctx_parsed_pairs[@]}")
    set -- "${_pairs[@]}"
    while [ "$#" -gt 0 ]; do
        _p_name="$1"; _p_path="$2"; shift 2
        _p_order=$((_p_order + 1))
        if _ctx_profile_is_canonical "$_p_path"; then
            canon_entries+=("$(_ctx_projection_basename "$_p_order" "$_p_name")" "$_p_path")
        else
            legacy_dirs+=("$_p_path")
        fi
    done
    expected_dirs="$(IFS=,; printf '%s' "${legacy_dirs[*]}")"
    if [ "${AI_CTX_PROFILES:-}" = "$expected_context" ]; then printf 'CHECK PASS AI_CTX_PROFILES\n'; else printf 'CHECK FAIL AI_CTX_PROFILES: expected %s, got %s\n' "$expected_context" "${AI_CTX_PROFILES:-<unset>}"; failures=$((failures+1)); fi
    # The active mode is the mode of the matching session-local activation
    # record, never the raw selector. A record matches only while its context
    # and custom-instructions directories match the parsed .ctx file; a stale
    # or mismatched record is not guessed at.
    if [ -n "$_ctx_active_mode" ] && [ "$_ctx_active_context" = "$expected_context" ] && [ "$_ctx_active_custom_dirs" = "$expected_dirs" ]; then
        recorded_mode="$_ctx_active_mode"
    fi
    if [ -n "$recorded_mode" ]; then
        if ! selector_mode="$(_ctx_validate_copilot_mode)"; then
            printf 'CHECK FAIL COPILOT_MODE: invalid selector "%s" (allowed values: synthetic-home, global-user, ephemeral-clean), recorded active mode %s\n' "${AI_CTX_PROFILES_COPILOT_MODE:-}" "$(_ctx_mode_label "$recorded_mode")"
            failures=$((failures+1))
        elif [ "$selector_mode" = "$recorded_mode" ]; then
            printf 'CHECK PASS COPILOT_MODE: recorded %s matches selector\n' "$(_ctx_mode_label "$recorded_mode")"
        else
            printf 'CHECK FAIL COPILOT_MODE: selector %s does not match recorded active mode %s\n' "$selector_mode" "$(_ctx_mode_label "$recorded_mode")"
            failures=$((failures+1))
        fi
    else
        printf 'CHECK UNKNOWN COPILOT_MODE: no matching local activation record\n'
    fi
    if [ -n "$expected_dirs" ]; then
        if [ "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-}" = "$expected_dirs" ]; then printf 'CHECK PASS COPILOT_CUSTOM_INSTRUCTIONS_DIRS\n'; else printf 'CHECK FAIL COPILOT_CUSTOM_INSTRUCTIONS_DIRS: expected %s, got %s\n' "$expected_dirs" "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-<unset>}"; failures=$((failures+1)); fi
    elif [ -n "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS+x}" ] && [ -z "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" ]; then
        # All-canonical Mode A requires a present-empty value; absent is not
        # accepted as empty.
        printf 'CHECK PASS COPILOT_CUSTOM_INSTRUCTIONS_DIRS\n'
    else
        printf 'CHECK FAIL COPILOT_CUSTOM_INSTRUCTIONS_DIRS: expected <present-empty>, got %s\n' "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-<unset>}"
        failures=$((failures+1))
    fi

    local expected_home
    if [ -n "$home_override" ]; then expected_home="$home_override"; else expected_home="$(_ctx_copilot_home_root)/$(_ctx_sanitize_context_name "$expected_context")"; fi

    case "$recorded_mode" in
        global-user)
            # Mode B: compare COPILOT_HOME only against the exact recorded
            # activation-time value (including still-unset); never inspect the
            # global ~/.copilot.
            if [ "$_ctx_active_home_was_set" -eq 1 ]; then
                if [ -n "${COPILOT_HOME+x}" ] && [ "$COPILOT_HOME" = "$_ctx_active_home_value" ]; then
                    printf 'CHECK PASS COPILOT_HOME\n'
                else
                    printf 'CHECK FAIL COPILOT_HOME: recorded %s, got %s\n' "$_ctx_active_home_value" "${COPILOT_HOME:-<unset>}"
                    failures=$((failures+1))
                fi
            elif [ -z "${COPILOT_HOME+x}" ]; then
                printf 'CHECK PASS COPILOT_HOME\n'
            else
                printf 'CHECK FAIL COPILOT_HOME: recorded <unset>, got %s\n' "${COPILOT_HOME:-}"
                failures=$((failures+1))
            fi
            _ctx_check_skills_dirs "$expected_home" "${dirs[@]}" || failures=$((failures+1))
            _ctx_check_skip_links_and_skills "$expected_home" "${dirs[@]}"
            ;;
        ephemeral-clean)
            # Mode C: PASS only when the current COPILOT_HOME still equals the
            # recorded ephemeral path (presence and exact value) AND that path
            # still exists as a real (non-symlink) directory. FAIL on unset,
            # changed, or foreign-replaced values; never inspect contents.
            if [ -n "${COPILOT_HOME+x}" ] && [ "$COPILOT_HOME" = "$_ctx_active_home_value" ] \
               && [ -n "$_ctx_active_home_value" ] && [ -d "$_ctx_active_home_value" ] && [ ! -L "$_ctx_active_home_value" ]; then
                printf 'CHECK PASS COPILOT_HOME\n'
            else
                printf 'CHECK FAIL COPILOT_HOME: expected recorded ephemeral home %s, got %s\n' "$_ctx_active_home_value" "${COPILOT_HOME:-<unset>}"
                failures=$((failures+1))
            fi
            _ctx_check_skills_dirs "$expected_home" "${dirs[@]}" || failures=$((failures+1))
            _ctx_check_skip_links_and_skills "$expected_home" "${dirs[@]}"
            ;;
        synthetic-home)
            # Mode A: existing COPILOT_HOME + shared-link + skill checks
            # unchanged (only the mode line/report differs).
            if [ "${COPILOT_HOME:-}" = "$expected_home" ] && [ -d "$expected_home" ]; then printf 'CHECK PASS COPILOT_HOME\n'; else printf 'CHECK FAIL COPILOT_HOME: expected %s, got %s\n' "$expected_home" "${COPILOT_HOME:-<unset>}"; failures=$((failures+1)); fi
            local f target current
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                target="${CTX_COPILOT_DIR:-$HOME/.copilot}/$f"
                if _ctx_link_matches "$expected_home/$f" "$target"; then printf 'CHECK PASS link:%s\n' "$f"; else printf 'CHECK FAIL link:%s: expected link to %s\n' "$f" "$target"; failures=$((failures+1)); fi
            done <<EOF
$(_ctx_copilot_home_shared_files)
EOF
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                target="${CTX_COPILOT_DIR:-$HOME/.copilot}/$f"
                if _ctx_link_matches "$expected_home/$f" "$target"; then printf 'CHECK PASS link:%s\n' "$f"; else printf 'CHECK FAIL link:%s: expected link to %s\n' "$f" "$target"; failures=$((failures+1)); fi
            done <<EOF
$(_ctx_copilot_home_shared_dirs)
EOF
            local -A seen=() collided=() first_target=() contributors=() actual=() actual_seen=() actual_dup=()
            local -a all_names=() actual_names=() actual_dup_names=()
            local rd s skill_name lcname
            for rd in "${dirs[@]}"; do
                while IFS= read -r s; do
                    [ -n "$s" ] || continue
                    skill_name="$(basename "$s")"
                    if ! lcname="$(_ctx_skill_canonical_name "$skill_name")"; then
                        printf 'CHECK FAIL skill:%s: cannot canonicalize skill name (python3/python not found)\n' "$skill_name"
                        failures=$((failures+1))
                        continue
                    fi
                    if [ -n "${collided[$lcname]+set}" ]; then
                        contributors[$lcname]="${contributors[$lcname]}, $rd"
                    elif [ -n "${seen[$lcname]+set}" ]; then
                        collided[$lcname]=1
                        contributors[$lcname]="${contributors[$lcname]}, $rd"
                    else
                        seen[$lcname]=1
                        first_target[$lcname]="${s%/}"
                        contributors[$lcname]="$rd"
                        all_names+=("$lcname")
                    fi
                done < <(_ctx_skill_source_dirs "$rd")
            done
            while IFS= read -r s; do
                skill_name="$(basename "$s")"
                if ! lcname="$(_ctx_skill_canonical_name "$skill_name")"; then
                    printf 'CHECK FAIL skill:%s: cannot canonicalize skill name (python3/python not found)\n' "$skill_name"
                    failures=$((failures+1))
                    continue
                fi
                actual_names+=("$skill_name")
                actual[$lcname]="$(readlink "$s" 2>/dev/null || printf '%s' plain)"
                if [ -n "${actual_seen[$lcname]+set}" ]; then
                    if [ -z "${actual_dup[$lcname]+set}" ]; then
                        actual_dup[$lcname]=1
                        actual_dup_names+=("$lcname")
                    fi
                else
                    actual_seen[$lcname]=1
                fi
            done < <(find "$expected_home/skills" -mindepth 1 -maxdepth 1 -print)
            local sorted_skills
            sorted_skills="$(printf '%s\n' "${all_names[@]}" | sort)"
            while IFS= read -r lcname; do
                [ -n "$lcname" ] || continue
                if [ -n "${collided[$lcname]+set}" ]; then
                    printf 'CHECK FAIL skill:%s: name collision between %s\n' "$lcname" "${contributors[$lcname]}"
                    failures=$((failures+1))
                elif [ "${actual[$lcname]:-}" = "${first_target[$lcname]}" ]; then
                    printf 'CHECK PASS skill:%s\n' "$(basename "${first_target[$lcname]}")"
                else
                    printf 'CHECK FAIL skill:%s: missing or wrong target\n' "$(basename "${first_target[$lcname]}")"
                    failures=$((failures+1))
                fi
            done <<< "$sorted_skills"
            local dname
            for dname in "${actual_dup_names[@]}"; do
                printf 'CHECK FAIL skill:%s: duplicate actual skill name\n' "$dname"
                failures=$((failures+1))
            done
            sorted_skills="$(printf '%s\n' "${actual_names[@]}" | sort)"
            while IFS= read -r skill_name; do
                [ -n "$skill_name" ] || continue
                if ! lcname="$(_ctx_skill_canonical_name "$skill_name")"; then
                    printf 'CHECK FAIL skill:%s: cannot canonicalize skill name (python3/python not found)\n' "$skill_name"
                    failures=$((failures+1))
                    continue
                fi
                [ -n "${seen[$lcname]:-}" ] || { printf 'CHECK FAIL skill:%s: unexpected skill\n' "$skill_name"; failures=$((failures+1)); }
            done <<< "$sorted_skills"
            ;;
        *)
            # No matching activation record: a present COPILOT_HOME or
            # COPILOT_SKILLS_DIRS is unattributable, so report CHECK UNKNOWN
            # rather than guessing. Unknown diagnostics are not applicable
            # checks and do not increment the failure count.
            if [ -n "${COPILOT_HOME+x}" ]; then printf 'CHECK UNKNOWN COPILOT_HOME: present with no matching local activation record\n'; fi
            if [ -n "${COPILOT_SKILLS_DIRS+x}" ]; then printf 'CHECK UNKNOWN COPILOT_SKILLS_DIRS: present with no matching local activation record\n'; fi
            _ctx_check_skip_links_and_skills "$expected_home" "${dirs[@]}"
            ;;
    esac

    # Canonical instruction projections are audited under the recorded mode
    # (Mode A checks, B/C and no-record SKIP). Read-only.
    _ctx_check_instructions "$expected_home" "$recorded_mode" "${canon_entries[@]}" || failures=$((failures + 1))

    # Strict check is read-only: do not invoke external copilot commands.
    # Even a seemingly informational probe may write caches/state.
    printf 'CHECK SKIP skills: copilot probe disabled in read-only check\n'

    local workspace="$dir_of_file/$(basename "$dir_of_file").code-workspace"
    if [ -e "$workspace" ] && [ ! -L "$workspace" ]; then
        local workspace_bin=""
        if command -v python3 >/dev/null 2>&1; then workspace_bin="python3"; elif command -v python >/dev/null 2>&1; then workspace_bin="python"; fi
        if [ -z "$workspace_bin" ]; then
            printf 'CHECK SKIP workspace: no python interpreter available\n'
        elif "$workspace_bin" - "$workspace" "${names[@]}" "${dirs[@]}" <<'PYEOF'
import json, sys
p=sys.argv[1]; n=len(sys.argv[2:])//2; names=sys.argv[2:2+n]; dirs=sys.argv[2+n:]
try:
    with open(p, encoding='utf-8') as f: w=json.load(f)
    folders=w.get('folders', []) if isinstance(w,dict) else []
    wanted=[('.', 'root: '+p.rsplit('/',2)[-2])] + list(zip(dirs, ['ctx: '+x for x in names]))
    have={(x.get('path'),x.get('name')) for x in folders if isinstance(x,dict)}
    missing=[x for x in wanted if x not in have]
    print('CHECK PASS workspace marker='+('ctx' if w.get('generatedBy') == 'ctx' else 'unmarked'))
    if missing:
        print('CHECK FAIL workspace: missing expected folder(s)')
        sys.exit(1)
except Exception:
    print('CHECK FAIL workspace: invalid JSON')
    sys.exit(1)
PYEOF
        then :; else failures=$((failures+1)); fi
    else
        printf 'CHECK SKIP workspace: no adjacent workspace file\n'
    fi
    if [ "$failures" -eq 0 ]; then printf 'ctx check: PASS\n'; return 0; fi
    printf 'ctx check: FAIL (%s)\n' "$failures"; return 1
}

# --- ctx skills: read-only skill-discovery inventory ----------------------
# `ctx skills` is a filesystem/configuration-based, strictly read-only
# inventory of the skill directories Copilot might discover. It is explicitly
# an inventory of *potential* discovery locations — it never claims a skill is
# loaded or invoked, and it never modifies settings, files, or the
# environment. Each candidate path is reported with a single classification
# (precedence: ctx-profile > expected-home > external) while all origins are
# retained. No Copilot CLI probe is performed.

_ctx_skills_normalize() {
    # Canonicalizes a candidate path for deduplication using platform-
    # appropriate rules without requiring the path to exist. Prefers GNU
    # realpath -m when available; otherwise falls back to the python3/python
    # stdlib (os.path.abspath + os.path.normpath), matching the repo's other
    # python-based helpers, so macOS/BSD and minimal systems that lack GNU
    # realpath are covered without a hard dependency. The path is passed to
    # python as argv (never via stdin) so leading/trailing spaces in the path
    # itself are preserved. Prints the normalized path, or nothing + 1 when it
    # cannot be normalized.
    local path="$1" normalized="" python_bin=""
    [ -n "$path" ] || return 1
    if command -v realpath >/dev/null 2>&1; then
        normalized="$(realpath -m -- "$path" 2>/dev/null)" || normalized=""
        [ -n "$normalized" ] && { printf '%s\n' "$normalized"; return 0; }
    fi
    if command -v python3 >/dev/null 2>&1; then
        python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        python_bin="python"
    fi
    if [ -n "$python_bin" ]; then
        normalized="$("$python_bin" -c 'import os,sys; sys.stdout.write(os.path.abspath(os.path.normpath(sys.argv[1])))' "$path")" || return 1
        [ -n "$normalized" ] || return 1
        printf '%s\n' "$normalized"
        return 0
    fi
    return 1
}

_ctx_skills_plugin_skill_dirs() {
    # Prints existing skill-directory paths under an installed-plugins root:
    # <root>/*/skills and <root>/*/.github/skills, one per line. Only actual,
    # observable directories are printed; the plugins root itself is never
    # reported as a skill directory.
    local root="$1" plugin
    [ -d "$root" ] || return 0
    while IFS= read -r plugin; do
        [ -n "$plugin" ] || continue
        [ -d "$plugin/skills" ] && printf '%s\n' "$plugin/skills"
        [ -d "$plugin/.github/skills" ] && printf '%s\n' "$plugin/.github/skills"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
}

_ctx_skills_add() {
    # $1: origin label — a distinct source token such as ctx-profile,
    #     expected-home, copilot-skill-dirs, settings-skill-dirs,
    #     personal-copilot, personal-agents, repo-github-skills,
    #     repo-agents-skills, repo-claude-skills, or plugin-skills.
    # $2: raw path
    # $3: "configured" flag — when 1 the path is reportable as missing when
    #     it does not exist (configured/expected locations); default discovery
    #     locations that do not exist are simply absent from the inventory.
    local origin="$1" raw="$2" configured="${3:-0}" key
    [ -n "$raw" ] || return 0
    key="$(_ctx_skills_normalize "$raw")" || return 0
    if [ -n "${_CTX_SKILLS_ORIGINS[$key]+set}" ]; then
        case ",${_CTX_SKILLS_ORIGINS[$key]}," in
            *",$origin,"*) : ;;
            *) _CTX_SKILLS_ORIGINS[$key]="${_CTX_SKILLS_ORIGINS[$key]},$origin" ;;
        esac
    else
        _CTX_SKILLS_ORIGINS[$key]="$origin"
        _CTX_SKILLS_PATHS+=("$key")
    fi
    if [ "$configured" = "1" ]; then
        _CTX_SKILLS_REPORT[$key]=1
    fi
}

_ctx_skills_origins_csv() {
    # Prints the deduplicated, alphabetically-sorted origin labels of a path
    # as a comma-joined CSV. Classification is computed separately by
    # _ctx_skills_classify (alphabetical order no longer equals precedence).
    local path="$1"
    printf '%s\n' "${_CTX_SKILLS_ORIGINS[$path]}" | tr ',' '\n' | sort -u | paste -sd, -
}

_ctx_skills_classify() {
    # $1: comma-joined origin labels. Returns the single classification by
    # precedence: ctx-profile > expected-home > external (every other source).
    case ",$1," in
        *,ctx-profile,*) printf 'ctx-profile\n' ;;
        *,expected-home,*) printf 'expected-home\n' ;;
        *) printf 'external\n' ;;
    esac
}

_ctx_skills_read_skill_directories() {
    # Prints each non-empty string entry of a settings file's
    # "skillDirectories" array, one per line. Read-only: never prints other
    # settings content or secrets. Returns 0 even on missing/unparseable
    # content so the inventory never fails on a bad settings file.
    local settings_file="$1" python_bin=""
    [ -f "$settings_file" ] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        python_bin="python"
    else
        return 0
    fi
    "$python_bin" - "$settings_file" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    dirs = data.get("skillDirectories") if isinstance(data, dict) else None
    if isinstance(dirs, list):
        for d in dirs:
            if isinstance(d, str) and d.strip():
                print(d)
except Exception:
    pass
PYEOF
}

_ctx_skills() {
    # Bookkeeping is local to this function so the read-only diagnostic can
    # never overwrite a caller's _CTX_SKILLS_* variables (bash and zsh both
    # provide dynamic scoping, so the helpers below can read these locals).
    local -A _CTX_SKILLS_ORIGINS
    local -a _CTX_SKILLS_PATHS
    local -A _CTX_SKILLS_REPORT

    printf '[ctx skills] potential Copilot skill discovery — inventory only; ctx does not claim these skills are loaded or invoked\n'

    # Active context/profile skill dirs are ctx-owned and attributable only
    # while the session activation record still matches the current
    # environment; otherwise attribution is unknown and ctx-owned paths are
    # not guessed.
    if _ctx_active_record_matches; then
        local d
        while IFS= read -r d || [ -n "$d" ]; do
            [ -n "$d" ] && _ctx_skills_add ctx-profile "$d/.github/skills" 0
        done < <(printf '%s' "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-}" | tr ',' '\n')
    else
        printf '[ctx skills] unknown: no matching ctx session activation record; ctx-owned paths are not guessed\n'
    fi

    # Expected <COPILOT_HOME>/skills (configured/expected; reportable missing).
    if [ -n "${COPILOT_HOME+x}" ] && [ -n "$COPILOT_HOME" ]; then
        _ctx_skills_add expected-home "$COPILOT_HOME/skills" 1
    fi

    # Personal discovery locations (default, not configured).
    _ctx_skills_add personal-copilot "${CTX_COPILOT_DIR:-$HOME/.copilot}/skills" 0
    _ctx_skills_add personal-agents "$HOME/.agents/skills" 0

    # Repository discovery locations in the current directory and applicable
    # ancestors.
    local dir="$PWD"
    while : ; do
        _ctx_skills_add repo-github-skills "$dir/.github/skills" 0
        _ctx_skills_add repo-agents-skills "$dir/.agents/skills" 0
        _ctx_skills_add repo-claude-skills "$dir/.claude/skills" 0
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done

    # COPILOT_SKILLS_DIRS entries (configured; reportable missing).
    if [ -n "${COPILOT_SKILLS_DIRS+x}" ] && [ -n "$COPILOT_SKILLS_DIRS" ]; then
        local d2
        while IFS= read -r d2 || [ -n "$d2" ]; do
            [ -n "$d2" ] && _ctx_skills_add copilot-skill-dirs "$d2" 1
        done < <(printf '%s' "$COPILOT_SKILLS_DIRS" | tr ',' '\n')
    fi

    # Configured "skillDirectories" in relevant Copilot settings files
    # (configured; reportable missing). Read-only.
    local sfd settings_file
    for settings_file in "${CTX_COPILOT_DIR:-$HOME/.copilot}/settings.json" \
                         "${COPILOT_HOME:+$COPILOT_HOME/settings.json}" \
                         "$HOME/.github/copilot/settings.json"; do
        [ -n "$settings_file" ] || continue
        while IFS= read -r sfd || [ -n "$sfd" ]; do
            [ -n "$sfd" ] && _ctx_skills_add settings-skill-dirs "$sfd" 1
        done < <(_ctx_skills_read_skill_directories "$settings_file")
    done
    dir="$PWD"
    while : ; do
        while IFS= read -r sfd || [ -n "$sfd" ]; do
            [ -n "$sfd" ] && _ctx_skills_add settings-skill-dirs "$sfd" 1
        done < <(_ctx_skills_read_skill_directories "$dir/.github/copilot/settings.json")
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done

    # Detectable additional-directory mechanisms and installed-plugin skill
    # paths: only actual, observable skill directories under installed
    # plugins are reported (a plugins root itself is never a skill
    # directory).
    local plugin_root plugin_skill
    for plugin_root in "${CTX_COPILOT_DIR:-$HOME/.copilot}/installed-plugins" \
                       "${COPILOT_HOME:+$COPILOT_HOME/installed-plugins}"; do
        [ -n "$plugin_root" ] || continue
        while IFS= read -r plugin_skill || [ -n "$plugin_skill" ]; do
            [ -n "$plugin_skill" ] && _ctx_skills_add plugin-skills "$plugin_skill" 0
        done < <(_ctx_skills_plugin_skill_dirs "$plugin_root")
    done

    # Report candidates (existing paths) first, then configured-but-missing
    # paths, both in sorted order. Do not fail on missing/inaccessible paths.
    local sorted path origins_csv classification
    sorted="$(printf '%s\n' "${_CTX_SKILLS_PATHS[@]}" | sort -u)"
    if [ -n "$sorted" ]; then
        while IFS= read -r path || [ -n "$path" ]; do
            [ -n "$path" ] || continue
            origins_csv="$(_ctx_skills_origins_csv "$path")"
            [ -n "$origins_csv" ] || continue
            classification="$(_ctx_skills_classify "${_CTX_SKILLS_ORIGINS[$path]}")"
            if [ -d "$path" ]; then
                printf '[ctx skills] candidate: %s (classification: %s, origins: %s)\n' "$path" "$classification" "$origins_csv"
            elif [ -n "${_CTX_SKILLS_REPORT[$path]+set}" ]; then
                printf '[ctx skills] missing: %s (classification: %s, origins: %s)\n' "$path" "$classification" "$origins_csv"
            fi
        done <<< "$sorted"
    else
        printf '[ctx skills] (no candidate skill directories found)\n'
    fi

    printf '[ctx skills] not observable: command-line arguments of another Copilot process\n'
    printf '[ctx skills] not observable: skill locations inside installed Copilot plugins beyond their detectable skills/ and .github/skills subdirectories\n'
    printf '[ctx skills] not observable: which skills Copilot actually loads or invokes (no Copilot CLI probe performed)\n'
}

# --- Issue #67 packet 2: shell<->engine protocol response adapter ---------
# Internal, currently uncalled helper (packet 3 wires it in). It validates the
# ENTIRE response before applying anything (parse-whole-then-apply): any
# validation failure applies NOTHING and returns 70. It never evals or sources
# engine output; it only performs direct export/unset on allowlisted names.

_ctx_protocol_env_allowed() {
    case "$1" in
        AI_CTX_PROFILES|COPILOT_CUSTOM_INSTRUCTIONS_DIRS|COPILOT_HOME|COPILOT_SKILLS_DIRS) return 0 ;;
        *) return 1 ;;
    esac
}

_ctx_protocol_request_field_allowed() {
    case "$1" in
        active.mode|active.context|active.custom_dirs|active.home_was_set|active.home_value|skills.owned|skills.was_set|skills.value|autoload.dir|autoload.home_override) return 0 ;;
        live.home_was_set|live.home_value|live.skills_was_set|live.skills_value) return 0 ;;
        outcome.warn_unowned_home|outcome.warn_home_changed|outcome.retained_ephemeral_home) return 0 ;;
        *) return 1 ;;
    esac
}

# Encodes a value into the protocol's escaped form in $_ctx_protocol_escaped:
# '\' -> "\\", LF -> "\n", CR -> "\r"; every other byte passes through
# literally. Assigning to a variable (not command substitution) keeps the
# result intact.
_ctx_protocol_escape() {
    local _in="$1" _c _out=""
    while [ -n "$_in" ]; do
        _c="${_in%"${_in#?}"}"
        _in="${_in#?}"
        case "$_c" in
            "\\") _out="${_out}\\\\";;
            $'\n') _out="${_out}\\n";;
            $'\r') _out="${_out}\\r";;
            *) _out="${_out}${_c}";;
        esac
    done
    _ctx_protocol_escaped="$_out"
}

# Prints one escaped "name value" request line.
_ctx_protocol_request_line() {
    _ctx_protocol_escape "$2"
    printf '%s %s\n' "$1" "$_ctx_protocol_escaped"
}

# Writes the 14-field `protocol clear` request from current shell state. The
# active.* fields come from the session-local activation record; the mode is
# the *matching* recorded mode (empty when no record matches), so the engine
# can reproduce "no matching activation record" without live selector fields.
_ctx_protocol_write_clear_request() {
    # $1: protocol dir, $2: matching recorded mode (may be empty)
    local _dir="$1" _mode="$2"
    local _live_home_was_set=0 _live_home_value="" _live_skills_was_set=0 _live_skills_value=""
    if [ -n "${COPILOT_HOME+x}" ]; then
        _live_home_was_set=1
        _live_home_value="${COPILOT_HOME:-}"
    fi
    if [ -n "${COPILOT_SKILLS_DIRS+x}" ]; then
        _live_skills_was_set=1
        _live_skills_value="${COPILOT_SKILLS_DIRS:-}"
    fi
    {
        printf 'CTX-REQ 1\n'
        _ctx_protocol_request_line active.mode "$_mode"
        _ctx_protocol_request_line active.context "${_ctx_active_context:-}"
        _ctx_protocol_request_line active.custom_dirs "${_ctx_active_custom_dirs:-}"
        _ctx_protocol_request_line active.home_was_set "${_ctx_active_home_was_set:-0}"
        _ctx_protocol_request_line active.home_value "${_ctx_active_home_value:-}"
        _ctx_protocol_request_line skills.owned "${_ctx_skills_dirs_owned:-0}"
        _ctx_protocol_request_line skills.was_set "${_ctx_skills_dirs_was_set:-0}"
        _ctx_protocol_request_line skills.value "${_ctx_skills_dirs_value:-}"
        _ctx_protocol_request_line autoload.dir "${_ctx_auto_load_dir:-}"
        _ctx_protocol_request_line autoload.home_override "${_ctx_auto_load_home_override:-}"
        _ctx_protocol_request_line live.home_was_set "$_live_home_was_set"
        _ctx_protocol_request_line live.home_value "$_live_home_value"
        _ctx_protocol_request_line live.skills_was_set "$_live_skills_was_set"
        _ctx_protocol_request_line live.skills_value "$_live_skills_value"
        printf 'END\n'
    } > "$_dir/request"
}

# Runs the engine's `protocol clear` round-trip and applies the response. Fails
# closed (no mutation) when the engine is missing or the dotnet invocation
# errors. Returns the adapter's code (the response EXIT, or 70 on invalid
# output).
_ctx_clear_apply_engine() {
    # $1: matching recorded mode (may be empty)
    local _mode="${1:-}" _dir _rc
    if [ -z "${CTX_ENGINE_DLL:-}" ] || [ ! -f "$CTX_ENGINE_DLL" ]; then
        printf 'ctx: error: .NET 10 engine DLL not found: %s\n' "${CTX_ENGINE_DLL:-<unset>}" >&2
        return 1
    fi
    _dir="$(mktemp -d "${TMPDIR:-/tmp}/ctx-clear-protocol.XXXXXXXXXX" 2>/dev/null)" || {
        printf 'ctx: error: .NET 10 engine DLL not found: %s\n' "$CTX_ENGINE_DLL" >&2
        return 1
    }
    if ! _ctx_protocol_write_clear_request "$_dir" "$_mode"; then
        rm -rf "$_dir"
        printf 'ctx: error: .NET 10 engine DLL not found: %s\n' "$CTX_ENGINE_DLL" >&2
        return 1
    fi
    if ! dotnet "$CTX_ENGINE_DLL" protocol clear --protocol-dir "$_dir"; then
        rm -rf "$_dir"
        printf 'ctx: error: .NET 10 engine DLL not found: %s\n' "$CTX_ENGINE_DLL" >&2
        return 1
    fi
    _ctx_apply_protocol_response "$_dir/response"
    _rc=$?
    rm -rf "$_dir"
    return "$_rc"
}

# Decodes the protocol escaping into $_ctx_protocol_unescaped. Returns 1 on an
# invalid escape. Assigning to a variable (not command substitution) keeps an
# embedded LF/CR intact.
_ctx_protocol_unescape() {
    local _in="$1" _c _next _out=""
    while [ -n "$_in" ]; do
        _c="${_in%"${_in#?}"}"
        _in="${_in#?}"
        if [ "$_c" = "\\" ]; then
            [ -n "$_in" ] || return 1
            _next="${_in%"${_in#?}"}"
            _in="${_in#?}"
            case "$_next" in
                "\\") _out="${_out}\\";;
                n) _out="${_out}"$'\n';;
                r) _out="${_out}"$'\r';;
                *) return 1 ;;
            esac
        else
            _out="${_out}${_c}"
        fi
    done
    _ctx_protocol_unescaped="$_out"
    return 0
}

_ctx_protocol_validate_set() {
    local _rest="$1" _name _val
    [ -n "$_rest" ] || return 1
    _name="${_rest%% *}"
    if [ "$_name" = "$_rest" ]; then
        _val=""
    else
        _val="${_rest#* }"
    fi
    _ctx_protocol_env_allowed "$_name" || return 1
    _ctx_protocol_unescape "$_val" || return 1
    return 0
}

_ctx_protocol_validate_setempty() {
    [ "$1" = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS" ] || return 1
    return 0
}

_ctx_protocol_validate_unset() {
    [ -n "$1" ] || return 1
    _ctx_protocol_env_allowed "$1" || return 1
    return 0
}

_ctx_protocol_validate_rec() {
    local _rest="$1" _name _val
    [ -n "$_rest" ] || return 1
    _name="${_rest%% *}"
    if [ "$_name" = "$_rest" ]; then
        _val=""
    else
        _val="${_rest#* }"
    fi
    _ctx_protocol_request_field_allowed "$_name" || return 1
    _ctx_protocol_unescape "$_val" || return 1
    return 0
}

_ctx_protocol_validate_exit() {
    local _val="$1"
    [ -n "$_val" ] || return 1
    case "$_val" in
        *[!0-9]*) return 1 ;;
    esac
    [ "$_val" -le 255 ] || return 1
    return 0
}

# Validates every line without applying anything: bad verb, bad ENVNAME, bad
# escape, missing/duplicate END, trailing bytes after END or a missing/duplicate
# EXIT all fail closed. Returns 0 only for a fully valid response.
_ctx_protocol_validate_response() {
    local _file="$1" _line _lineno=0 _saw_end=0 _exit_count=0
    while IFS= read -r _line; do
        _lineno=$((_lineno + 1))
        if [ "$_saw_end" -eq 1 ]; then
            return 1
        fi
        if [ "$_lineno" -eq 1 ]; then
            [ "$_line" = "CTX-RES 1" ] || return 1
            continue
        fi
        case "$_line" in
            END)
                [ "$_exit_count" -eq 1 ] || return 1
                _saw_end=1
                ;;
            "SET "*)      _ctx_protocol_validate_set "${_line#SET }" || return 1 ;;
            "SETEMPTY "*) _ctx_protocol_validate_setempty "${_line#SETEMPTY }" || return 1 ;;
            "UNSET "*)    _ctx_protocol_validate_unset "${_line#UNSET }" || return 1 ;;
            "REC "*)      _ctx_protocol_validate_rec "${_line#REC }" || return 1 ;;
            "MSG "*)      _ctx_protocol_unescape "${_line#MSG }" || return 1 ;;
            "EXIT "*)
                _ctx_protocol_validate_exit "${_line#EXIT }" || return 1
                _exit_count=$((_exit_count + 1))
                ;;
            *) return 1 ;;
        esac
    done < "$_file"
    [ "$_saw_end" -eq 1 ] || return 1
    return 0
}

# Second, apply-only pass over an already-validated response. Also captures the
# single EXIT value into $_ctx_protocol_exit and any flat outcome.* records into
# the _ctx_protocol_outcome_* variables (with *_seen flags, because a present
# outcome may legitimately carry an empty value).
_ctx_protocol_apply_response() {
    local _file="$1" _line _rest _name _val
    while IFS= read -r _line; do
        case "$_line" in
            END) break ;;
            "SET "*)
                _rest="${_line#SET }"
                _name="${_rest%% *}"
                if [ "$_name" = "$_rest" ]; then
                    _val=""
                else
                    _val="${_rest#* }"
                fi
                _ctx_protocol_unescape "$_val" || return 1
                export "$_name=$_ctx_protocol_unescaped"
                ;;
            "SETEMPTY "*)
                _name="${_line#SETEMPTY }"
                export "$_name="
                ;;
            "UNSET "*)
                _name="${_line#UNSET }"
                unset "$_name"
                ;;
            "REC "*)
                _rest="${_line#REC }"
                _name="${_rest%% *}"
                if [ "$_name" = "$_rest" ]; then
                    _val=""
                else
                    _val="${_rest#* }"
                fi
                _ctx_protocol_unescape "$_val" || return 1
                case "$_name" in
                    outcome.warn_unowned_home)
                        _ctx_protocol_outcome_warn_unowned_home="$_ctx_protocol_unescaped"
                        _ctx_protocol_outcome_warn_unowned_home_seen=1 ;;
                    outcome.warn_home_changed)
                        _ctx_protocol_outcome_warn_home_changed="$_ctx_protocol_unescaped"
                        _ctx_protocol_outcome_warn_home_changed_seen=1 ;;
                    outcome.retained_ephemeral_home)
                        _ctx_protocol_outcome_retained_ephemeral_home="$_ctx_protocol_unescaped"
                        _ctx_protocol_outcome_retained_ephemeral_home_seen=1 ;;
                esac
                ;;
            "EXIT "*)
                _ctx_protocol_exit="${_line#EXIT }"
                ;;
            *) : ;;
        esac
    done < "$_file"
    return 0
}

_ctx_apply_protocol_response() {
    # $1: path to the engine's response file. Validates then applies; returns 70
    # on any validation failure, applying nothing. On success returns the
    # response's EXIT value (the non---all clear path always emits EXIT 0).
    local _file="${1:-}"
    [ -n "$_file" ] || return 70
    [ -f "$_file" ] || return 70

    _ctx_protocol_exit=""
    _ctx_protocol_outcome_warn_unowned_home=""
    _ctx_protocol_outcome_warn_unowned_home_seen=0
    _ctx_protocol_outcome_warn_home_changed=""
    _ctx_protocol_outcome_warn_home_changed_seen=0
    _ctx_protocol_outcome_retained_ephemeral_home=""
    _ctx_protocol_outcome_retained_ephemeral_home_seen=0

    if command -v od >/dev/null 2>&1; then
        local _tokens _first3 _last
        _tokens="$(od -An -v -tx1 "$_file" 2>/dev/null | tr ' ' '\n' | grep -v '^$')"
        # NUL and raw CR are forbidden anywhere; the file must end with LF.
        if printf '%s\n' "$_tokens" | grep -qEx '00|0d'; then
            return 70
        fi
        _first3="$(printf '%s\n' "$_tokens" | head -n 3 | tr '\n' ' ')"
        if [ "$_first3" = "ef bb bf " ]; then
            return 70
        fi
        _last="$(printf '%s\n' "$_tokens" | tail -n 1)"
        [ "$_last" = "0a" ] || return 70
    fi

    _ctx_protocol_validate_response "$_file" || return 70
    _ctx_protocol_apply_response "$_file" || return 70
    return "${_ctx_protocol_exit:-0}"
}

# --- Shell integration (completion + chdir hooks) -----------------------

_ctx_list_subdirs() {
    local base="$1"
    [ -d "$base" ] || return 0
    find "$base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null
}

_ctx_list_profiles() {
    local external_root="${AI_CTX_PROFILES_EXTERNAL_PROFILES_ROOT:-}"
    {
        _ctx_list_subdirs "$(_ctx_root)/profiles"
        [ -n "$external_root" ] && _ctx_list_subdirs "$external_root"
    } | LC_ALL=C sort -u
}

if [ -n "${ZSH_VERSION:-}" ]; then
    # zsh completion
    _ctx_zsh_complete() {
        local -a words_arr
        words_arr=("${words[@]}")
        if [ "${#words_arr[@]}" -eq 3 ] && [ "${words_arr[2]}" = "clear" ]; then
            compadd --all
        elif [ "${#words_arr[@]}" -ge 3 ] && [ "${words_arr[2]}" = "load" ]; then
            _files
        elif [ "${#words_arr[@]}" -le 2 ]; then
            local -a profiles
            profiles=("${(f)$(_ctx_list_profiles)}")
            compadd current clear skills load -- "${profiles[@]}"
        else
            local -a shared
            shared=("${(f)$(_ctx_list_profiles)}")
            compadd -- "${shared[@]}"
        fi
    }
    compdef _ctx_zsh_complete ctx 2>/dev/null || true

    autoload -Uz add-zsh-hook 2>/dev/null
    if command -v add-zsh-hook >/dev/null 2>&1; then
        add-zsh-hook chpwd _ctx_auto_load_hook
    fi
    # Run once for the shell's starting directory.
    _ctx_auto_load_hook

elif [ -n "${BASH_VERSION:-}" ]; then
    # bash completion
    _ctx_bash_complete() {
        local cur
        cur="${COMP_WORDS[COMP_CWORD]}"

        if [ "$COMP_CWORD" -eq 1 ]; then
            mapfile -t COMPREPLY < <(compgen -W "current clear skills load $(_ctx_list_profiles | tr '\n' ' ')" -- "$cur")
        elif [ "$COMP_CWORD" -eq 2 ] && [ "${COMP_WORDS[1]}" = "clear" ]; then
            mapfile -t COMPREPLY < <(compgen -W "--all" -- "$cur")
        elif [ "$COMP_CWORD" -ge 2 ] && [ "${COMP_WORDS[1]}" = "load" ]; then
            mapfile -t COMPREPLY < <(compgen -f -- "$cur")
        else
            mapfile -t COMPREPLY < <(compgen -W "$(_ctx_list_profiles | tr '\n' ' ')" -- "$cur")
        fi
    }
    complete -F _ctx_bash_complete ctx

    _ctx_bash_chpwd() {
        if [ "${_ctx_bash_last_pwd:-}" != "$PWD" ]; then
            _ctx_bash_last_pwd="$PWD"
            _ctx_auto_load_hook
        fi
    }
    case "${PROMPT_COMMAND:-}" in
        *_ctx_bash_chpwd*) : ;;
        "") PROMPT_COMMAND="_ctx_bash_chpwd" ;;
        *) PROMPT_COMMAND="_ctx_bash_chpwd;${PROMPT_COMMAND}" ;;
    esac
    # Run once for the shell's starting directory.
    _ctx_bash_last_pwd="$PWD"
    _ctx_auto_load_hook
fi
