# Public branding

## Brand idea

The current public identity is “Same Mac. Fresh start.” It presents macOS Cleanup as a careful local command-line utility, with an editorial website that explains the workflow without implying that it is a GUI or a one-click cleaner.

## Public assets

- [`assets/brand-banner.svg`](../assets/brand-banner.svg): 1280 × 460 website and README banner.
- [`assets/brand-icon.svg`](../assets/brand-icon.svg): current disk-and-check brand mark.

The seven website language routes are [English](https://macos-cleanup.64bit.site/), [Polish](https://macos-cleanup.64bit.site/pl/), [German](https://macos-cleanup.64bit.site/de/), [Spanish](https://macos-cleanup.64bit.site/es/), [French](https://macos-cleanup.64bit.site/fr/), [Italian](https://macos-cleanup.64bit.site/it/), and [Portuguese](https://macos-cleanup.64bit.site/pt/).

## Palette

| Name | Hex | Role |
|---|---|---|
| Charcoal | `#141311` | Dark surfaces and primary ink |
| Bone | `#EEE9DF` | Light backgrounds |
| Coral | `#ED826D` | Editorial warmth |
| Amber | `#F2AD5F` | Secondary accent |
| Jade | `#91D5AB` | Brand green |

For CLI and report risk states, retain separate semantics: jade/green `SAFE`, yellow `REVIEW`, red (for example, `#FFB5AB`) `DANGEROUS`. Always include the text label. The brand palette does not change risk meaning.

## Content boundaries

The website may use editorial imagery, but screenshots and terminal mockups must be identified as illustrative and must not show fabricated metrics. Keep CLI examples aligned with the repository. Quarantine moves do not free APFS space until purged; snapshot reclamation timing is controlled by macOS. Official product support is Apple Silicon with macOS 11 or later; the v3.0.7 CLI has a macOS 10.15 technical floor and does not block Intel by architecture, but Intel is outside official support.
