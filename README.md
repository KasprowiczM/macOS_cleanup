# 🍏 macOS Cleanup

<p align="left">
  <img src="assets/logo_clean.svg" alt="macOS Cleanup Logo" width="120" align="right" />
  <strong>The Professional System Cleaner</strong><br>
  Built on an Informed Consent model with strict data boundaries.<br><br>
  <a href="https://macos-cleanup.64bit.site">Visit the Official Landing Page</a>
</p>

<p align="left">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>

## 🌍 Read in Your Language

* [🇬🇧 English (Default)](README.md)
* [🇵🇱 Polski](README.pl.md)
* [🇪🇸 Español](README.es.md)
* [🇫🇷 Français](README.fr.md)
* [🇩🇪 Deutsch](README.de.md)
* [🇮🇹 Italiano](README.it.md)
* [🇵🇹 Português](README.pt.md)

---

## ⚡ 1-Line Installer

Install and run `macOS Cleanup` in seconds. Open your terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macos_cleanup/main/install.sh | bash
```

---

## 📸 Interface & Features

macOS Cleanup is a professional, system-native utility that safely reclaims gigabytes of disk space on your Mac. Unlike aggressive system cleaners, it utilizes a rigorous **4-stage safety model** (Analyze → Plan → Apply → Quarantine), guaranteeing that your critical data remains perfectly untouched.

<details open>
<summary><b>1. Professional Overview</b></summary>
<br>
<br>
</details>

<details open>
<summary><b>2. Safety First: The Informed Consent Model</b></summary>
<br>
<br>
</details>

<details open>
<summary><b>3. Native Bash CLI Power</b></summary>
<br>
<br>
</details>

<details open>
<summary><b>4. Compared to Alternatives</b></summary>
<br>
<br>
</details>

---

## 🛡️ The Safety Model

We believe a cleanup script should never be a source of anxiety. Our non-negotiable rules are hardcoded into the engine:

1. **User Data is Sacred**: Never touches `~/Documents`, `~/Desktop`, Mail, SSH/GPG keys, or browser profiles (passwords, history).
2. **Quarantine by Default**: Files are not permanently deleted right away. They are moved to a temporary quarantine.
3. **No Sudo Required**: Reclaim massive amounts of space purely from user-level caches without root permissions.
4. **Pure Bash 3.2 Compatibility**: No heavy backends. Fully native on macOS 10.15+.

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

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
