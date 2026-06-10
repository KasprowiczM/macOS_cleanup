<div align="center">
  <img src="assets/clean_logo.svg" alt="macOS Cleanup Logo" width="160" />

  <h1>macOS Cleanup <br> <span style="font-size: 0.6em; font-weight: normal;">The Professional System Cleaner</span></h1>

  <p>
    <strong>Safe, transparent, and built on an "Informed Consent" model.</strong><br>
    Unlike commercial black-box cleaners, macOS Cleanup uses a rigorous 4-phase safety pipeline to ensure it never deletes important files without your knowledge.
  </p>

  <a href="https://macos-cleanup.64bit.site"><strong>Visit Official Site</strong></a> ·
  <a href="#-quick-install"><strong>Installation</strong></a> ·
  <a href="user_guide.md"><strong>Documentation</strong></a>

  <br><br>

  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</div>

<br>

<div align="center">
</div>

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

## ⚡ Quick Install

Install and scan your Mac in seconds. The installation is perfectly safe and won't delete anything automatically.

```bash
curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macos_cleanup/main/install.sh | bash
```

---

## 🛡️ The Safety Model

We believe a system utility should never be a source of anxiety. Our strict boundaries are hardcoded into the engine:

1. **User Data is Sacred**: Never touches `~/Documents`, `~/Desktop`, Mail, SSH/GPG keys, or active browser profiles.
2. **Quarantine by Default**: Files are not permanently deleted right away. They are moved to a temporary quarantine so you can easily restore them.
3. **No Sudo Required**: Reclaim massive amounts of space from user-level caches without exposing your system to root vulnerabilities.
4. **Pure Bash 3.2 Compatibility**: Fully native on macOS 10.15+. No heavy dependencies or backends.

<div align="center">
  <br>
</div>

---

## 💻 Native CLI Power

Scan your system safely and review a detailed JSON/Markdown plan before committing to any changes.

<div align="center">
  <br>
</div>

### Analyze (Dry Run)
Scan your system and generate a detailed report without modifying a single file on disk:
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

## 📊 Comparison

<div align="center">
  <br>
</div>

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
