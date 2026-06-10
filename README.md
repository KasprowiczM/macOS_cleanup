<div align="center">
  <img src="assets/clean_logo.svg" alt="macOS Cleanup Logo" width="120" />

  <br>

  <h1>Regain disk space with <i>zero blind spots</i>.<br>No compromises.</h1>

  <p>
    Safer than commercial apps, fully transparent, and built on a strict "Informed Consent" model.<br>
    Analyze your system, review the plan, and execute with absolute control over what gets deleted.
  </p>

  <p>
    <a href="https://macos-cleanup.64bit.site"><strong>Run Dry-Run Analysis on Official Site</strong></a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="user_guide.md"><strong>Read Documentation</strong></a>
  </p>

  <br>

  <a href="https://macos-cleanup.64bit.site">
  </a>

  <br><br>

  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</div>

<br>

---

<div align="center">
  <h2>🌍 Available Languages</h2>
  <a href="README.md">🇬🇧 English</a> &nbsp;|&nbsp; 
  <a href="README.pl.md">🇵🇱 Polski</a> &nbsp;|&nbsp; 
  <a href="README.es.md">🇪🇸 Español</a> &nbsp;|&nbsp; 
  <a href="README.fr.md">🇫🇷 Français</a> &nbsp;|&nbsp; 
  <a href="README.de.md">🇩🇪 Deutsch</a> &nbsp;|&nbsp; 
  <a href="README.it.md">🇮🇹 Italiano</a> &nbsp;|&nbsp; 
  <a href="README.pt.md">🇵🇹 Português</a>
</div>

---

## ⚡ Install in one line

Install and scan your Mac in seconds. The installation is perfectly safe and won't delete anything automatically.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

---

## 🛡️ The Safety Model

We believe a system utility should never be a source of anxiety. Our strict boundaries are hardcoded into the engine:

1. **User Data is Sacred**: Never touches `~/Documents`, `~/Desktop`, Mail, SSH/GPG keys, or active browser profiles.
2. **Quarantine by Default**: Files are not permanently deleted right away. They are moved to a temporary quarantine so you can easily restore them.
3. **No Sudo Required**: Reclaim massive amounts of space from user-level caches without exposing your system to root vulnerabilities.
4. **Pure Bash 3.2 Compatibility**: Fully native on macOS 10.15+. No heavy dependencies or backends.

---

## 💻 Native CLI Power

### Analyze (Dry Run)
Scan your system safely and review a detailed JSON/Markdown plan before committing to any changes:
```bash
bash cleanup_all.sh --dry-run
```

### Auto-Safe Clean
Automatically clean only files classified as strictly `SAFE`, moving them directly to quarantine:
```bash
bash cleanup_all.sh --auto-safe
```

### Restore from Quarantine
Made a mistake? Revert your last cleanup instantly:
```bash
bash cleanup_all.sh --restore latest
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
