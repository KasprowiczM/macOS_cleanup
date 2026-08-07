# Protected Paths & Exclusions Policy

> ⚠️ **IMPORTANT**: Quarantine is not a backup and reclaims no space until purged. Files placed in quarantine remain safely isolated on disk until explicitly restored (`--restore`) or purged (`--purge-quarantine`).

## Non-Negotiable Protected Paths (`NEVER_TOUCH_PATHS`)

The `macOS_cleanup` script **never touches** the following locations under any circumstances:

- `/Users/yourname/Library/Mail`
- `/Users/yourname/Library/Containers/com.apple.mail`
- `/Users/yourname/Library/Keychains`
- `/Library/Keychains`
- `/System/Library/Keychains`
- `/Users/yourname/Library/Application Support/1Password`
- `/Users/yourname/Library/Application Support/1Password 7`
- `/Users/yourname/Library/Application Support/com.agilebits`
- `/Users/yourname/Library/Application Support/Bitwarden`
- `/Users/yourname/Library/Application Support/LastPass`
- `/Users/yourname/Library/Application Support/Dashlane`
- `/Users/yourname/Library/Application Support/Enpass`
- `/Users/yourname/Library/Application Support/Keybase`
- `/Users/yourname/Library/Application Support/macOS_cleanup`
- `/Users/yourname/Library/Caches/com.1password.1password`
- `/Users/yourname/Library/Caches/com.agilebits.onepassword7`
- `/Users/yourname/Library/Caches/com.bitwarden.desktop`
- `/Users/yourname/Library/Caches/com.lastpass.LastPass`
- `/Users/yourname/Library/Caches/com.dashlane.Dashlane`
- `/Users/yourname/Library/Caches/in.sinew.Enpass-Desktop`
- `/Users/yourname/Documents`
- `/Users/yourname/Desktop`
- `/Users/yourname/Pictures/Photos Library.photoslibrary`
- `/Users/yourname/Pictures/Photos Library`
- `/Users/yourname/Music/Music/Music Library.musiclibrary`
- `/Users/yourname/Music/Music Library.musiclibrary`
- `/Users/yourname/Movies`
- `/Users/yourname/Library/Mobile Documents`
- `/Users/yourname/Library/CloudStorage`
- `/Users/yourname/Dropbox`
- `/Users/yourname/OneDrive`
- `/Users/yourname/Google Drive`
- `/Users/yourname/Library/Application Support/Google/DriveFS`
- `/Users/yourname/Library/Application Support/Google/Chrome`
- `/Users/yourname/Library/Application Support/Firefox`
- `/Users/yourname/Library/Application Support/Microsoft Edge`
- `/Users/yourname/Library/Application Support/BraveSoftware`
- `/Users/yourname/Library/Application Support/Opera`
- `/Users/yourname/Library/Application Support/Vivaldi`
- `/Users/yourname/Library/Safari`
- `/Users/yourname/Library/MobileDevice/Provisioning Profiles`
- `/Users/yourname/Library/Keychains`
- `/Users/yourname/Developer`
- `/Users/yourname/Projects`
- `/Users/yourname/src`
- `/Users/yourname/code`
- `/Users/yourname/repos`
- `/Users/yourname/.ssh`
- `/Users/yourname/.gnupg`
- `/Users/yourname/.aws/credentials`
- `/Users/yourname/.aws/config`
- `/Users/yourname/.gitconfig`
- `/Users/yourname/.git-credentials`
- `/Users/yourname/.config`
- `/Users/yourname/.kube`
- `/Users/yourname/.docker`
- `/Users/yourname/.netrc`
- `/Users/yourname/.zshrc`
- `/Users/yourname/.zprofile`
- `/Users/yourname/.zsh_history`
- `/Users/yourname/.bash_profile`
- `/Users/yourname/.bashrc`
- `/Users/yourname/.bash_history`
- `/Users/yourname/.profile`
- `/Users/yourname/.npmrc`
- `/Users/yourname/.config/gh`

## Disposable Cache & Log Roots (`userDisposableRoots`)

Cleanup is strictly bounded to allowed disposable roots:
- `~/Library/Caches/*`
- `~/Library/Logs/*`
- `~/Library/Developer/Xcode/DerivedData/*`
- `~/Library/Developer/Xcode/Archives/*`
- `~/Library/Developer/Xcode/iOS DeviceSupport/*`
- `~/Library/Developer/CoreSimulator/Devices/*`
- `~/.cache/*`
- `~/.npm/_cacache/*`
- `~/.yarn/berry/cache/*`
- `~/.Trash/*`
- `~/Downloads/*.dmg` / `*.pkg` (older than 30 days)
