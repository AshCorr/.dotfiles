# Dotfiles

Configuration files from this machine, stored with the same layout as `$HOME`
inside [`home/`](home/), plus system files under [`system/`](system/), which
mirrors the filesystem root. A single [`install.sh`](install.sh) links the home
files into place, installs the listed packages, and copies tracked system files
between the repository and the live filesystem.

For home files, the live file and the repository entry are the same file, so
edits in either place are immediately visible. System files are copied, so they
are synced explicitly with `system export` and `system apply`.

## Usage

All setup goes through one script, [`install.sh`](install.sh):

| Command | What it does |
| --- | --- |
| `./install.sh` or `./install.sh link` | Symlink every file under `home/` into `$HOME` |
| `./install.sh link --restore` | Remove those symlinks and restore the newest backups |
| `./install.sh packages` | Install the packages listed in `packages/pacman.txt` |
| `./install.sh system export` | Copy tracked live files into `system/` |
| `./install.sh system apply` | Copy `system/` back to the live filesystem, backing up existing files |
| `./install.sh system diff` | Show content and mode differences between the live filesystem and `system/` |
| `./install.sh system list` | List the absolute paths configured in `system-paths.txt` |

Run `./install.sh --help` for the full reference. `--dry-run` (`-n`) is
supported by `link`, `packages`, `system export`, and `system apply`; it prints
the commands without running them. Dry-run previews of `system` commands do not
need root.

When a real file already exists at a link destination, it is moved to
`~/.dotfiles-backup/<timestamp>-<pid>/` before the symlink is created. Set
`DOTFILES_BACKUP_DIR` to use a different backup location, or `DOTFILES_TARGET`
to link into a home directory other than `$HOME`. `link --restore` only removes
symlinks that point into this repository and restores the newest backup for
each file.

## Software

`packages/pacman.txt` lists the explicitly installed pacman packages from this
machine. Install whichever are missing with:

```sh
sudo pacman -Syu                # refresh the package databases first
./install.sh packages --dry-run # preview
./install.sh packages           # install with --needed
```

All listed packages are from the official repositories; no AUR helper is
required. Lines starting with `#` and trailing `#` comments are ignored, so the
file can be grouped and annotated. The list includes machine-specific entries
such as the kernel, bootloader, AMD microcode, and NVIDIA drivers, so review it
before using it on different hardware. The installer uses
`pacman -S --needed --noconfirm`, so packages that are already present are
skipped.

## System files

`system/` mirrors the filesystem root, so it can hold any absolute path, not
just `/etc`:

| Live path | Repository copy |
| --- | --- |
| `/etc/sudoers` | `system/etc/sudoers` |
| `/etc/NetworkManager/conf.d/dns.conf` | `system/etc/NetworkManager/conf.d/dns.conf` |
| `/boot/grub/grub.cfg` | `system/boot/grub/grub.cfg` |
| `/usr/local/bin/example` | `system/usr/local/bin/example` |

`system-paths.txt` lists the absolute paths to track. Blank lines, comments,
and trailing `#` comments are ignored. A directory entry tracks every regular
file below it, so new drop-in files are picked up automatically. An optional
second field sets the mode applied to the live file:

```text
/etc/NetworkManager/conf.d/
/etc/systemd/resolved.conf.d/
/etc/sudoers 0440
/etc/sudoers.d/ 0440
/usr/local/bin/example 0755
```

Without an explicit mode, sudoers files use `0440` and everything else uses
`0644`. Modes are applied by `system apply`; repository copies are kept at
`0644` (or `0755` for executable modes) so they stay editable. Symlinks are not
tracked, and paths containing spaces are not supported.

Unlike the home-directory files, these are **copied, not symlinked**. Making
`/etc/sudoers` or a systemd unit a symlink into a user-writable repository would
let anything running as your user change root-owned configuration and escalate
privileges.

```sh
sudo ./install.sh system export   # copy tracked live files into system/
sudo ./install.sh system apply    # copy system/ back, backing up existing files
sudo ./install.sh system diff     # show differences
./install.sh system list          # list tracked paths
```

`export`, `apply`, and `diff` need root to read files such as `/etc/sudoers`
(mode `0440`), so the first import must be run with sudo. Before `apply`
overwrites anything, the current files are copied to
`/var/backups/dotfiles-system/<timestamp>/`. Sudoers files in the repository are
validated with `visudo -cf` first, and `apply` aborts before writing anything if
validation fails. `export` and `apply` only add or update files; they never
delete files from the repository or the live system. `diff` compares the files
stored in `system/` (contents and modes), so a live file that has never been
exported is not shown.

Because `system/` stores files verbatim, think before tracking secrets such as
`/etc/shadow`, private keys, or Wi-Fi credentials. The current list avoids
`/etc/NetworkManager/system-connections/` for that reason.

To add a system file, add its absolute path to `system-paths.txt` and export it:

```sh
printf '/etc/fstab\n' >> system-paths.txt
sudo ./install.sh system export
```

For testing, `DOTFILES_SYSTEM_ROOT` prefixes every live path, so
`DOTFILES_SYSTEM_ROOT=/tmp/root ./install.sh system diff` compares against a
sandbox. `DOTFILES_SYSTEM_BACKUP_DIR` overrides the backup location.

## Tracked home files

| Path | Description |
| --- | --- |
| `home/.zshrc`, `home/.bashrc`, `home/.bash_profile`, `home/.bash_logout` | Shell configuration |
| `home/.gitconfig` | Git configuration |
| `home/.Xresources` | X cursor resources |
| `home/.config/niri/config.kdl` | Niri configuration |
| `home/.config/niri/dms/*.kdl` | DankMaterialShell fragments for Niri |
| `home/.config/DankMaterialShell/settings.json` | DankMaterialShell settings |
| `home/.config/DankMaterialShell/monitors.json` | Monitor layout (hardware-specific) |
| `home/.config/mimeapps.list` | Default application associations |
| `home/.config/user-dirs.dirs`, `home/.config/user-dirs.locale` | XDG user directories |
| `home/.config/xdg-terminals.list` | Preferred terminal |

## Adding a home file

Copy it into `home/` using its path relative to `$HOME`, then run
`./install.sh`. For example:

```sh
mkdir -p home/.config/kitty
cp ~/.config/kitty/kitty.conf home/.config/kitty/
./install.sh
```