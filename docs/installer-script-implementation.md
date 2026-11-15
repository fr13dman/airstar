# Installer script: implementation notes

`install.sh` builds `airstar-cli` in release mode and installs it so every user on the Mac can run it. The default location is `/usr/local/sbin`. `scripts/test-install.sh` tests the installer without needing root.

## Usage

```sh
./install.sh                          # build, install to /usr/local/sbin, register PATH
./install.sh --prefix /usr/local/bin  # custom location
./install.sh --skip-build             # reuse .build/release/airstar-cli
./install.sh --no-path                # do not touch /etc/paths.d
./install.sh --uninstall              # remove the binary and the PATH entry
```

## What it does

1. **Checks the platform.** The script requires Darwin, macOS 14 or later, and `swift` on `PATH`.
2. **Builds.** It runs `swift build -c release --product airstar-cli` and finds the binary with `swift build -c release --show-bin-path`. When the script itself runs under `sudo`, the build runs as `$SUDO_USER`, so `.build/` doesn't end up owned by root:

   ```bash
   run_as_invoking_user() {
       if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
           sudo -u "$SUDO_USER" "$@"
       else
           "$@"
       fi
   }
   ```

3. **Installs.** It copies the binary with `install -m 0755` (as `root:wheel` when sudo is needed). Escalation happens only for the steps that need it: the `as_owner` helper finds the nearest existing parent of the destination and uses `sudo` only if that directory isn't writable. A user-writable `--prefix` therefore never prompts for a password.
4. **Registers PATH.** macOS's default `/etc/paths` lists `/usr/local/bin` but not `/usr/local/sbin`. The installer writes the prefix to `/etc/paths.d/airstar-cli`. The `path_helper` tool, which `/etc/zprofile` and `/etc/profile` run for every login shell, then adds it to every user's `PATH`. It skips this step if the prefix is already listed in `/etc/paths` or any `/etc/paths.d` file, so reinstalling never duplicates the entry.
5. **Verifies.** It runs `<prefix>/airstar-cli --version` from the installed location. This proves the binary loads outside `.build`, including its one `@rpath` dependency, which is covered below. It also warns, without failing, if ffmpeg is missing, since `info`, `play` and `cast` need it.

`--uninstall` removes the binary and the `paths.d` entry, but only if that entry names the same prefix. It leaves Keychain pairing credentials alone and tells you how to remove them with `pair --forget`.

## Dependencies of the binary

`otool -L` shows that the release binary links only system frameworks and `/usr/lib/swift` libraries. SwiftPM links the package dependencies statically (ArgumentParser, Hummingbird/SwiftNIO, BigInt). The one `@rpath` entry is `libswiftCompatibilitySpan.dylib`. On recent macOS it ships in `/usr/lib/swift`, the first rpath. On macOS 14 and 15 it resolves through the Xcode toolchain rpath, which exists on any Mac that can build the project. That makes copying the single binary enough. The verify step catches it if that ever stops being true.

## Choices considered

| Option | Decision |
| --- | --- |
| Install location | `/usr/local/sbin`, as requested, plus PATH registration. `/usr/local/bin` would need no PATH change and works with `--prefix /usr/local/bin`. Homebrew's `/opt/homebrew/bin` is owned by Homebrew and only on PATH for users who set up Homebrew's shell environment. |
| Making it available to all users | `/etc/paths.d`, the system-wide mechanism read by `path_helper`. Editing each user's shell rc files would miss other users and other shells. |
| Packaging | A plain bash script. A `.pkg` built with `pkgbuild` needs signing and notarization to install cleanly. A Homebrew formula needs a tap and a release tarball. Either can come later and reuse the same build step. |
| Privilege | `sudo` only for individual commands that need it. Asking you to run the whole script as root would build as root. |

## Tests (`scripts/test-install.sh`)

The test sets `AIRSTAR_PATHS_FILE` and `AIRSTAR_PATHS_D` to point the installer at a fake `/etc/paths` and `/etc/paths.d` in a temporary directory, and installs to temporary prefixes, so it never needs root. Its 16 checks cover:

- **Fresh install:** builds; the binary is executable with mode 755 and runs `--version` and `--help` from the install location; the PATH entry is written.
- **Reinstall with `--skip-build`:** reports that the PATH is already registered and doesn't duplicate the entry.
- **Prefix already in `/etc/paths`:** no `paths.d` entry is created.
- **`--no-path`:** installs without registering.
- **Uninstall:** removes the binary and the entry, and running it a second time is harmless.
- **Bad arguments:** unknown options and relative prefixes are rejected; `--help` works.

Run it with `scripts/test-install.sh`. All 16 checks pass.
