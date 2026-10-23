#!/usr/bin/env bash
#
# install.sh - provision a machine from this dotfiles repository.
#
# This is the single entry point for all three kinds of setup this repository
# performs:
#
#   link      Symlink the files under home/ into $HOME. The repository uses the
#             same directory layout as a home directory, and every file is
#             linked individually so applications can still create unrelated
#             files in the same directories.
#
#   packages  Install the explicitly listed packages from packages/pacman.txt.
#             The list only uses the official repositories, so no AUR helper is
#             needed.
#
#   system    Copy selected files from anywhere in the filesystem into system/,
#             which mirrors the filesystem root (/etc/sudoers becomes
#             system/etc/sudoers, /boot/grub/grub.cfg becomes
#             system/boot/grub/grub.cfg). /etc is the usual target. These files
#             are deliberately copied rather than symlinked: a symlink from
#             /etc/sudoers into a user-writable checkout would let any process
#             running as the user change root-owned configuration and escalate
#             privileges.
#
# Usage:
#   ./install.sh                     link home/ into $HOME (same as "link")
#   ./install.sh link [--restore]    create/refresh symlinks or undo them
#   ./install.sh packages            install packages/pacman.txt with pacman
#   ./install.sh system export       copy tracked live files into ./system
#   ./install.sh system apply        copy ./system back to the live filesystem
#   ./install.sh system diff         show differences
#   ./install.sh system list         list the tracked absolute paths
#   ./install.sh --dry-run ...       show what would happen, change nothing
#   ./install.sh --help              show the full help text
#
# Environment:
#   DOTFILES_TARGET           destination home directory (default: $HOME)
#   DOTFILES_BACKUP_DIR       home backup location (default: ~/.dotfiles-backup)
#   DOTFILES_SYSTEM_ROOT      prefix applied to system paths, useful for testing
#                             (default: empty, meaning the real filesystem)
#   DOTFILES_SYSTEM_BACKUP_DIR
#                             system backup location
#                             (default: /var/backups/dotfiles-system)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Resolve the repository root from the script location so the script works
# from any working directory (including via a symlink in ~/.local/bin, as long
# as bash can read the link target).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOME_SOURCE_DIR="$SCRIPT_DIR/home"
PACKAGE_FILE="$SCRIPT_DIR/packages/pacman.txt"
SYSTEM_MIRROR_DIR="$SCRIPT_DIR/system"
SYSTEM_PATHS_FILE="$SCRIPT_DIR/system-paths.txt"

# Destinations and backup locations are overridable, which keeps the script
# testable without touching the real account or filesystem.
TARGET_DIR="${DOTFILES_TARGET:-${HOME:?HOME is not set}}"
HOME_BACKUP_ROOT="${DOTFILES_BACKUP_DIR:-$TARGET_DIR/.dotfiles-backup}"
SYSTEM_BACKUP_ROOT="${DOTFILES_SYSTEM_BACKUP_DIR:-/var/backups/dotfiles-system}"

# Optional prefix for system paths. Empty means operate on the real filesystem.
# A value such as /tmp/test-root makes /etc/sudoers resolve to
# /tmp/test-root/etc/sudoers, so exports, applies, and diffs can be tested
# without touching the real system.
SYSTEM_ROOT="${DOTFILES_SYSTEM_ROOT:-}"
SYSTEM_ROOT="${SYSTEM_ROOT%/}"

if [[ -n "$SYSTEM_ROOT" && "$SYSTEM_ROOT" != /* ]]; then
    printf 'error: DOTFILES_SYSTEM_ROOT must be an absolute path\n' >&2
    exit 1
fi

DRY_RUN=0
RESTORE=0
COMMAND=""
SUBCOMMAND=""
RUN_ID=""

# Filled by load_system_paths: parallel arrays of absolute paths and optional
# modes (empty string when the default applies).
SYSTEM_PATHS=()
SYSTEM_MODES=()

# Filled by owner_args_for before applying a file.
OWNER_ARGS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Provision a machine from this dotfiles repository.

Usage:
  ./install.sh                     link home/ into $HOME (default)
  ./install.sh link [--restore]    create symlinks, or undo them
  ./install.sh packages            install packages/pacman.txt
  ./install.sh system <command>    sync tracked system files

Commands:
  link                Symlink every file under home/ into the destination
                      home directory. Existing files are moved to a timestamped
                      backup first. Re-running is safe and only refreshes
                      links that are missing or point elsewhere.
  link --restore      Remove links that point into this repository and restore
                      the newest backup for each file. Files that are not
                      symlinks are left alone.
  packages            Install every package listed in packages/pacman.txt using
                      `pacman -S --needed --noconfirm`. Run `sudo pacman -Syu`
                      first so the package databases are current.
  system export       Copy tracked files from the live filesystem into system/.
                      Needs root for files such as /etc/sudoers (mode 0440).
  system apply        Copy system/ back to the live filesystem after validating
                      sudoers files with `visudo -cf`. Existing files are
                      backed up first.
  system diff         Show differences between the live filesystem and
                      system/, including file modes. Exits 1 when differences
                      exist, like `diff`.
  system list         Print the absolute paths listed in system-paths.txt.

Options:
  -n, --dry-run       Print commands instead of running them. Applies to link,
                      packages, system export, and system apply.
  --restore           Undo the link command. Only valid with link.
  -h, --help          Show this help.

Files and lists:
  home/               Mirrors $HOME and is symlinked into place.
  packages/pacman.txt One package per line; blank lines and # comments ignored.
  system/             Mirrors the filesystem root. /etc/sudoers is stored as
                      system/etc/sudoers, /boot/grub/grub.cfg as
                      system/boot/grub/grub.cfg, and so on.
  system-paths.txt    Absolute paths to track, one per line. A directory entry
                      tracks every regular file below it. An optional second
                      field sets the mode applied to the live file, for
                      example:
                        /etc/sudoers 0440
                        /etc/NetworkManager/conf.d/
                      Blank lines and # comments are ignored. Without an
                      explicit mode, sudoers files use 0440 and everything else
                      uses 0644. Repository copies stay readable and editable
                      (0644, or 0755 for executable modes). Symlinks are not
                      tracked.

Environment:
  DOTFILES_TARGET           destination home directory (default: $HOME)
  DOTFILES_BACKUP_DIR       home backup location (default: ~/.dotfiles-backup)
  DOTFILES_SYSTEM_ROOT      prefix applied to system paths, useful for testing
                            (default: empty, meaning the real filesystem)
  DOTFILES_SYSTEM_BACKUP_DIR
                            system backup location
                            (default: /var/backups/dotfiles-system)

Examples:
  ./install.sh --dry-run           # preview linking
  ./install.sh --restore           # undo linking, restore backups
  ./install.sh packages --dry-run  # preview package installation
  sudo ./install.sh system export  # import tracked system files
  sudo ./install.sh system apply   # push them back to the live filesystem
  ./install.sh system list         # show what is tracked
EOF
}

# Fail with a consistent prefix and exit status 1.
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Print a command, or execute it when not in dry-run mode. %q keeps arguments
# with spaces or quotes readable in the preview.
run() {
    if (( DRY_RUN )); then
        printf '  would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# True when both paths exist and resolve to the same file. Used to tell a link
# that already points at the repository from one that points elsewhere.
same_file() {
    [[ -e "$1" && -e "$2" ]] \
        && [[ "$(readlink -f -- "$1")" == "$(readlink -f -- "$2")" ]]
}

# Print a package/path list with comments and surrounding whitespace removed.
# packages/pacman.txt and system-paths.txt share this format, so they use one
# parser instead of duplicating the awk program.
read_list() {
    awk '
        {
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        }
        NF { print }
    ' "$1"
}

# Refuse to modify the live filesystem unless running as root. A test prefix
# (DOTFILES_SYSTEM_ROOT) needs no privilege because it points at a sandbox, and
# dry runs only print commands, so they can be previewed unprivileged.
need_root() {
    if (( DRY_RUN )) && [[ "$SUBCOMMAND" != "diff" ]]; then
        return
    fi

    if [[ -z "$SYSTEM_ROOT" ]] && (( EUID != 0 )); then
        die "'$COMMAND $SUBCOMMAND' needs root; run: sudo $SCRIPT_DIR/install.sh $COMMAND $SUBCOMMAND"
    fi
}

# ---------------------------------------------------------------------------
# link - symlink home/ into the target home directory
# ---------------------------------------------------------------------------

# Link one repository file. Individual files (not whole directories) are linked
# so applications can keep creating their own files in the same directories
# without those files ending up in the repository.
link_file() {
    local src="$1"
    local rel="${src#"$HOME_SOURCE_DIR"/}"
    local dest="$TARGET_DIR/$rel"

    if [[ -L "$dest" ]] && same_file "$dest" "$src"; then
        printf 'ok       %s\n' "$rel"
        return
    fi

    # Never replace a real directory with a symlink; that would hide its
    # contents and is almost certainly not what the user wants.
    if [[ -d "$dest" && ! -L "$dest" ]]; then
        printf 'skip     %s (destination is a directory)\n' "$rel" >&2
        return
    fi

    # Preserve whatever was there before, grouped by run so a later --restore
    # knows which backup belongs to which invocation.
    if [[ -e "$dest" || -L "$dest" ]]; then
        local backup="$HOME_BACKUP_ROOT/$RUN_ID/$rel"
        printf 'backup   %s -> %s\n' "$rel" "$backup"
        run mkdir -p -- "$(dirname -- "$backup")"
        run mv -- "$dest" "$backup"
    fi

    printf 'link     %s -> %s\n' "$rel" "$src"
    run mkdir -p -- "$(dirname -- "$dest")"
    run ln -s -- "$src" "$dest"
}

# Undo link_file: remove our symlink and put the newest backed-up file back.
restore_file() {
    local src="$1"
    local rel="${src#"$HOME_SOURCE_DIR"/}"
    local dest="$TARGET_DIR/$rel"
    local backup=""

    if [[ -L "$dest" ]] && same_file "$dest" "$src"; then
        printf 'unlink   %s\n' "$rel"
        run rm -- "$dest"
    elif [[ ! -L "$dest" ]]; then
        printf 'ok       %s (not linked)\n' "$rel"
        return
    else
        # The destination is a symlink, but not one of ours. Leave it alone.
        printf 'skip     %s (symlink points elsewhere)\n' "$rel" >&2
        return
    fi

    # Timestamped run directories sort chronologically, so the reverse-sorted
    # list visits the newest backup first.
    if [[ -d "$HOME_BACKUP_ROOT" ]]; then
        while IFS= read -r dir; do
            if [[ -e "$dir/$rel" || -L "$dir/$rel" ]]; then
                backup="$dir/$rel"
                break
            fi
        done < <(find "$HOME_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)
    fi

    if [[ -n "$backup" ]]; then
        printf 'restore  %s <- %s\n' "$rel" "$backup"
        run mkdir -p -- "$(dirname -- "$dest")"
        run mv -- "$backup" "$dest"
    fi
}

do_link() {
    [[ -d "$HOME_SOURCE_DIR" ]] || die "$HOME_SOURCE_DIR does not exist"

    # NUL-separated so filenames containing newlines survive; sorted for
    # deterministic output. Symlinks inside home/ are followed as entries, not
    # recursed into.
    local -a files=()
    mapfile -d '' files < <(
        find "$HOME_SOURCE_DIR" \( -type f -o -type l \) -print0 | sort -z
    )

    if (( ${#files[@]} == 0 )); then
        die "no files found in $HOME_SOURCE_DIR"
    fi

    if (( RESTORE )); then
        echo "Restoring files into $TARGET_DIR"
        for src in "${files[@]}"; do
            restore_file "$src"
        done
        echo
        echo "Done. Backups remain in $HOME_BACKUP_ROOT."
        return
    fi

    RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
    echo "Linking files into $TARGET_DIR (backups: $HOME_BACKUP_ROOT/$RUN_ID)"
    for src in "${files[@]}"; do
        link_file "$src"
    done
    echo
    if (( DRY_RUN )); then
        echo "Dry run complete; nothing was changed."
    else
        echo "Done."
    fi
}

# ---------------------------------------------------------------------------
# packages - install packages/pacman.txt
# ---------------------------------------------------------------------------

do_packages() {
    command -v pacman >/dev/null 2>&1 \
        || die "pacman is not available on this system"
    [[ -f "$PACKAGE_FILE" ]] || die "$PACKAGE_FILE does not exist"

    local -a packages=()
    mapfile -t packages < <(read_list "$PACKAGE_FILE")

    if (( ${#packages[@]} == 0 )); then
        die "no packages listed in $PACKAGE_FILE"
    fi

    # Use sudo only when not already root. If neither applies, stop before
    # printing a misleading dry-run preview.
    local -a sudo_cmd=()
    if (( EUID == 0 )); then
        sudo_cmd=()
    elif command -v sudo >/dev/null 2>&1; then
        sudo_cmd=(sudo)
    else
        die "run as root or install sudo"
    fi

    if (( DRY_RUN )); then
        printf 'Would install %d packages with:\n  %s pacman -S --needed --noconfirm\n\n' \
            "${#packages[@]}" "${sudo_cmd[*]:-}"
        printf '%s\n' "${packages[@]}"
        return
    fi

    "${sudo_cmd[@]}" pacman -S --needed --noconfirm "${packages[@]}"
}

# ---------------------------------------------------------------------------
# system - copy selected files between the live filesystem and ./system
# ---------------------------------------------------------------------------
#
# system/ mirrors the filesystem root. A configured path is always absolute:
#
#   /etc/sudoers           -> system/etc/sudoers
#   /boot/grub/grub.cfg    -> system/boot/grub/grub.cfg
#   /usr/local/bin/foo     -> system/usr/local/bin/foo
#
# A directory entry tracks every regular file below it, so adding a new file to
# /etc/NetworkManager/conf.d/ is picked up by the next export without editing
# system-paths.txt. Files are copied, never symlinked, and backups preserve the
# original modes and ownership.

# Map a logical absolute path to its location in the repository.
system_repo_path() {
    printf '%s%s' "$SYSTEM_MIRROR_DIR" "$1"
}

# Map a logical absolute path to its location on the live filesystem. With an
# empty SYSTEM_ROOT this is the path itself; with a test prefix it is prefixed.
system_live_path() {
    printf '%s%s' "$SYSTEM_ROOT" "$1"
}

# Default mode when system-paths.txt does not specify one.
default_mode_for() {
    case "$1" in
        */sudoers|*/sudoers.d/*) printf '0440' ;;
        *)                       printf '0644' ;;
    esac
}

# Resolve the mode for one file: the configured override for its entry, or the
# per-file default (so a directory entry containing sudoers files still works).
mode_for_path() {
    local path="$1"
    local configured="$2"

    if [[ -n "$configured" ]]; then
        printf '%s' "$configured"
    else
        default_mode_for "$path"
    fi
}

# Reject entries that could escape system/ or that cannot be mirrored safely.
validate_system_path() {
    local path="$1"

    [[ "$path" == /* ]] || die "path is not absolute: $path"
    [[ "$path" != "/" ]] || die "refusing to track the filesystem root"
    [[ "$path" != *"/../"* && "$path" != */.. ]] \
        || die "path must not contain '..': $path"
}

# Parse system-paths.txt into the SYSTEM_PATHS and SYSTEM_MODES arrays. A line
# is "<absolute path> [mode]"; paths with spaces are rejected rather than
# silently misparsed.
load_system_paths() {
    [[ -f "$SYSTEM_PATHS_FILE" ]] || die "$SYSTEM_PATHS_FILE does not exist"

    local line path mode
    local -a parts=()

    SYSTEM_PATHS=()
    SYSTEM_MODES=()

    while IFS= read -r line; do
        read -r -a parts <<< "$line"

        if (( ${#parts[@]} == 1 )); then
            path="${parts[0]}"
            mode=""
        elif (( ${#parts[@]} == 2 )); then
            path="${parts[0]}"
            mode="${parts[1]}"
        else
            die "invalid entry in $SYSTEM_PATHS_FILE (paths with spaces are not supported): $line"
        fi

        validate_system_path "$path"

        if [[ -n "$mode" && ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
            die "invalid mode '$mode' for $path (expected 3 or 4 octal digits)"
        fi

        SYSTEM_PATHS+=("$path")
        SYSTEM_MODES+=("$mode")
    done < <(read_list "$SYSTEM_PATHS_FILE")

    if (( ${#SYSTEM_PATHS[@]} == 0 )); then
        die "no paths listed in $SYSTEM_PATHS_FILE"
    fi
}

# Print the logical absolute paths of the regular files under one configured
# entry. $1 is the filesystem base to walk (the live root prefix or the
# repository mirror) and $2 is the configured absolute path. NUL-separated so
# filenames with spaces or newlines survive.
each_file_under() {
    local base="$1"
    local path="$2"
    local root_path="$base$path"
    local file logical

    if [[ -L "$root_path" ]]; then
        # Symlinks are not tracked: applying one would silently replace a link
        # with a regular file or vice versa, which is easy to get wrong.
        return 0
    elif [[ -f "$root_path" ]]; then
        printf '%s\0' "$path"
    elif [[ -d "$root_path" ]]; then
        while IFS= read -r -d '' file; do
            if [[ -z "$base" ]]; then
                logical="$file"
            else
                logical="${file#"$base"}"
            fi
            printf '%s\0' "$logical"
        done < <(find "$root_path" -type f -print0 | sort -z)
    fi
}

export_file() {
    local path="$1"
    local mode="$2"
    local src
    local dest

    src="$(system_live_path "$path")"
    dest="$(system_repo_path "$path")"

    printf 'export   %s\n' "$path"
    # -D creates parent directories. The repository copy is always writable by
    # its owner (0644, or 0755 when the applied mode is executable) so the
    # checkout stays editable. The configured mode is applied on "apply".
    run install -D -m "$(export_mode_for "$mode")" "$src" "$dest"
}

# Repository copies use a friendly mode: ordinary read/write, plus the
# executable bit when the applied mode has one. Exact modes such as 0440 are
# not useful in a git checkout and would make the file hard to edit.
export_mode_for() {
    case "$1" in
        *[1357]) printf '0755' ;;
        *)       printf '0644' ;;
    esac
}

do_export() {
    need_root
    load_system_paths

    local i path mode logical live
    run mkdir -p "$SYSTEM_MIRROR_DIR"
    if [[ -n "$SYSTEM_ROOT" ]]; then
        echo "Exporting $SYSTEM_ROOT (live root) -> $SYSTEM_MIRROR_DIR"
    else
        echo "Exporting live filesystem -> $SYSTEM_MIRROR_DIR"
    fi

    for i in "${!SYSTEM_PATHS[@]}"; do
        path="${SYSTEM_PATHS[i]}"
        mode="${SYSTEM_MODES[i]}"
        live="$(system_live_path "$path")"

        if [[ ! -e "$live" ]]; then
            printf 'skip     %s (missing in live filesystem)\n' "$path" >&2
            continue
        fi

        if [[ -L "$live" ]]; then
            printf 'skip     %s (symlink; regular files only)\n' "$path" >&2
            continue
        fi

        while IFS= read -r -d '' logical; do
            export_file "$logical" "$(mode_for_path "$logical" "$mode")"
        done < <(each_file_under "$SYSTEM_ROOT" "$path")
    done

    # The export normally runs as root, so hand the checkout back to the
    # invoking user. Directory modes are normalized; file modes were set by
    # install above. Skipped in dry-run mode because nothing was written.
    if (( ! DRY_RUN )); then
        local owner group
        owner="${SUDO_UID:-$(stat -c %u "$SCRIPT_DIR")}"
        group="${SUDO_GID:-$(stat -c %g "$SCRIPT_DIR")}"
        chown -R "$owner:$group" "$SYSTEM_MIRROR_DIR"
        find "$SYSTEM_MIRROR_DIR" -type d -exec chmod 0755 {} +
    fi
}

backup_file() {
    local dest="$1"
    local path="$2"

    if [[ -e "$dest" || -L "$dest" ]]; then
        local backup="$SYSTEM_BACKUP_ROOT/$RUN_ID/${path#/}"
        printf 'backup   %s -> %s\n' "$path" "$backup"
        run mkdir -p "$(dirname -- "$backup")"
        run cp -a -- "$dest" "$backup"
    fi
}

# Choose ownership for an applied file. On the real filesystem, preserve the
# owner/group of an existing destination (root for files that do not exist yet)
# so tracking a user-owned file does not silently make it root-owned. In a test
# root, leave ownership alone.
owner_args_for() {
    local dest="$1"

    OWNER_ARGS=()
    [[ -n "$SYSTEM_ROOT" ]] && return

    local uid gid
    if [[ -e "$dest" ]]; then
        read -r uid gid < <(stat -c '%u %g' -- "$dest")
    else
        uid=0
        gid=0
    fi

    OWNER_ARGS=(-o "$uid" -g "$gid")
}

apply_file() {
    local path="$1"
    local mode="$2"
    local src
    local dest

    src="$(system_repo_path "$path")"
    dest="$(system_live_path "$path")"

    # Directories and paths present in system-paths.txt but absent from the
    # checkout are left untouched.
    [[ -f "$src" ]] || return 0

    owner_args_for "$dest"
    backup_file "$dest" "$path"
    printf 'apply    %s\n' "$path"

    # sudoers.d must be root-owned and not writable by group/other.
    if [[ "$path" == */sudoers.d/* ]]; then
        run install -d -m 0750 "${OWNER_ARGS[@]}" "$(dirname -- "$dest")"
    fi

    run install -D -m "$mode" "${OWNER_ARGS[@]}" "$src" "$dest"
}

is_sudoers_path() {
    [[ "$1" == */sudoers || "$1" == */sudoers.d/* ]]
}

# A broken sudoers file can lock the machine out of sudo, so validate every
# candidate in a temporary file with the mode visudo expects before touching
# the real system. This only reads, so it also runs for dry-run applies.
validate_sudoers() {
    local i path logical file tmp output

    for i in "${!SYSTEM_PATHS[@]}"; do
        path="${SYSTEM_PATHS[i]}"
        while IFS= read -r -d '' logical; do
            is_sudoers_path "$logical" || continue

            file="$(system_repo_path "$logical")"
            [[ -f "$file" ]] || continue

            tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-sudoers.XXXXXX")"
            cp -- "$file" "$tmp"
            chmod 0440 "$tmp"

            if ! output="$(visudo -cf "$tmp" 2>&1)"; then
                printf 'error: invalid sudoers syntax in system%s\n%s\n' \
                    "$logical" "$output" >&2
                rm -f "$tmp"
                return 1
            fi

            rm -f "$tmp"
        done < <(each_file_under "$SYSTEM_MIRROR_DIR" "$path")
    done
}

do_apply() {
    need_root
    load_system_paths
    [[ -d "$SYSTEM_MIRROR_DIR" ]] || die "$SYSTEM_MIRROR_DIR does not exist"

    validate_sudoers || exit 1

    local i path mode logical repo
    RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

    if [[ -n "$SYSTEM_ROOT" ]]; then
        echo "Applying $SYSTEM_MIRROR_DIR -> $SYSTEM_ROOT (backups: $SYSTEM_BACKUP_ROOT/$RUN_ID)"
    else
        echo "Applying $SYSTEM_MIRROR_DIR -> live filesystem (backups: $SYSTEM_BACKUP_ROOT/$RUN_ID)"
    fi

    for i in "${!SYSTEM_PATHS[@]}"; do
        path="${SYSTEM_PATHS[i]}"
        mode="${SYSTEM_MODES[i]}"
        repo="$(system_repo_path "$path")"

        if [[ ! -e "$repo" && ! -L "$repo" ]]; then
            printf 'skip     %s (not in repository)\n' "$path" >&2
            continue
        fi

        while IFS= read -r -d '' logical; do
            apply_file "$logical" "$(mode_for_path "$logical" "$mode")"
        done < <(each_file_under "$SYSTEM_MIRROR_DIR" "$path")
    done
}

diff_file() {
    local path="$1"
    local mode="$2"
    local src
    local live
    local actual
    local rc=0

    src="$(system_repo_path "$path")"
    live="$(system_live_path "$path")"

    if [[ ! -e "$live" ]]; then
        printf 'missing  %s\n' "$live"
        return 1
    fi

    # apply would change the mode even when the contents match, so report that
    # as a difference too. Compare numerically so 0440 and 440 are equal.
    actual="$(stat -c %a -- "$live")"
    if (( 8#$actual != 8#$mode )); then
        printf 'mode     %s (is %s, expected %s)\n' "$path" "$actual" "$mode"
        rc=1
    fi

    diff -u --label "$live" --label "system$path" "$live" "$src" || rc=1
    return "$rc"
}

do_diff() {
    need_root
    load_system_paths
    [[ -d "$SYSTEM_MIRROR_DIR" ]] || die "$SYSTEM_MIRROR_DIR does not exist"

    local status=0 i path mode logical repo

    for i in "${!SYSTEM_PATHS[@]}"; do
        path="${SYSTEM_PATHS[i]}"
        mode="${SYSTEM_MODES[i]}"
        repo="$(system_repo_path "$path")"

        if [[ ! -e "$repo" && ! -L "$repo" ]]; then
            printf 'skip     %s (not in repository)\n' "$path" >&2
            continue
        fi

        while IFS= read -r -d '' logical; do
            diff_file "$logical" "$(mode_for_path "$logical" "$mode")" || status=1
        done < <(each_file_under "$SYSTEM_MIRROR_DIR" "$path")
    done

    if (( status == 0 )); then
        echo "No differences."
    fi
    exit "$status"
}

do_list() {
    load_system_paths
    local i
    for i in "${!SYSTEM_PATHS[@]}"; do
        printf '%s\n' "${SYSTEM_PATHS[i]}"
    done
}

# ---------------------------------------------------------------------------
# Argument parsing and dispatch
# ---------------------------------------------------------------------------

# Options may appear anywhere; non-option arguments are collected so the first
# selects the command and, for "system", the second selects the subcommand.
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        --restore)    RESTORE=1 ;;
        -h|--help)    usage; exit 0 ;;
        -*)
            printf 'error: unknown option: %s\n\n' "$arg" >&2
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done

COMMAND="${POSITIONAL[0]:-link}"
SUBCOMMAND="${POSITIONAL[1]:-}"

if (( ${#POSITIONAL[@]} > 2 )); then
    printf 'error: too many arguments\n\n' >&2
    usage >&2
    exit 2
fi

if [[ "$COMMAND" == "system" ]]; then
    if [[ -z "$SUBCOMMAND" ]]; then
        printf 'error: system needs a subcommand (export, apply, diff, or list)\n\n' >&2
        usage >&2
        exit 2
    fi
elif [[ -n "$SUBCOMMAND" ]]; then
    printf 'error: unexpected argument: %s\n\n' "$SUBCOMMAND" >&2
    usage >&2
    exit 2
fi

if (( RESTORE )) && [[ "$COMMAND" != "link" ]]; then
    echo "error: --restore can only be used with the link command" >&2
    exit 2
fi

case "$COMMAND" in
    link)     do_link ;;
    packages) do_packages ;;
    system)
        case "$SUBCOMMAND" in
            export) do_export ;;
            apply)  do_apply ;;
            diff)   do_diff ;;
            list)   do_list ;;
            *)
                printf 'error: unknown system subcommand: %s\n\n' "$SUBCOMMAND" >&2
                usage >&2
                exit 2
                ;;
        esac
        ;;
    help)     usage ;;
    *)
        printf 'error: unknown command: %s\n\n' "$COMMAND" >&2
        usage >&2
        exit 2
        ;;
esac
