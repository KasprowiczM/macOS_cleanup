<p align="center">
  <img src="assets/macos_cleanup_logo_dark.svg" alt="macOS Cleanup Logo" width="350" />
</p>

<h1 align="center">macOS Cleanup</h1>

<p align="center">
  <strong>Safe, predictable, and fully reversible macOS cleanup utility.</strong><br><br>
  <a href="https://macos-cleanup.64bit.site">Visit the Official Landing Page</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>
<br/>

## ⚡ Overview

macOS Cleanup is a professional, system-native utility that safely reclaims gigabytes of disk space on your Mac. Unlike aggressive system cleaners, it utilizes a rigorous **3-stage safety model** (Analyze → Plan → Quarantine), guaranteeing that your critical data remains perfectly untouched.



---

## 🚀 Quick Start

Get started immediately with zero risk using the built-in dry-run mode:

```bash
# Clone the repository
git clone https://github.com/KasprowiczM/macOS_cleanup.git
cd macOS_cleanup

# Run a safe dry-run analysis (no files will be deleted)
bash cleanup_all.sh --dry-run
```

---

## 🛡️ The Safety Model

We believe a cleanup script should never be a source of anxiety. Our non-negotiable rules are hardcoded into the engine:

1. **User Data is Sacred**: Never touches `~/Documents`, `~/Desktop`, Mail, or browser profiles (passwords, history).
2. **Quarantine by Default**: Files are not permanently deleted right away. They are moved to a temporary quarantine.
3. **No Sudo Required**: Reclaim massive amounts of space purely from user-level caches without root permissions.



---

## ⚙️ Core Commands

### Analyze (Dry Run)
Scan your system safely. Generates a detailed Markdown and JSON report of reclaimable space without modifying a single file on disk.
```bash
bash cleanup_all.sh --dry-run
```

### Auto-Safe Clean
Automatically clean only files classified as strictly `SAFE` (like build caches or temporary logs), moving them directly to quarantine.
```bash
bash cleanup_all.sh --auto-safe
```

### Restore from Quarantine
Made a mistake or an app started misbehaving? Everything is instantly reversible.
```bash
bash cleanup_all.sh --restore latest
```

---

## 📸 Interface Preview

<p align="center">
  <a href="https://macos-cleanup.64bit.site">
  </a>
</p>

---

## 🌍 Multilingual Guides

Detailed instructions and documentation are available in your preferred language. Simply select your language below:

* [🇬🇧 English (Default)](user_guide.md)
* [🇵🇱 Polski](user_guide.pl.md)
* [🇪🇸 Español](user_guide.es.md)
* [🇫🇷 Français](user_guide.fr.md)
* [🇩🇪 Deutsch](user_guide.de.md)
* [🇮🇹 Italiano](user_guide.it.md)
* [🇵🇹 Português](user_guide.pt.md)

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
