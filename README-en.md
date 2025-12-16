# installwp (macOS) — Herd + DBngin + WP-CLI

This repository contains an interactive Bash script that automates a local WordPress installation **on macOS** — optimized for **Herd** (web/PHP) and **DBngin** (database services).

## Who is this for?

WordPress developers who want fast, repeatable local test installs (theme/plugin development, WooCommerce testing, symlink workflows).

## Requirements

- macOS
- [Herd](https://herd.laravel.com/) installed
- [DBngin](https://dbngin.com/download) installed and **MySQL** or **MariaDB** running
- `wp` (WP-CLI) available on PATH (Herd often bundles `wp`)
- `curl`, `unzip` (available by default on macOS)

## Files

- `installwp-de.sh` — German version (prompts/logs/comments)
- `installwp-en.sh` — English version (prompts/logs/comments)
- `LICENSE` — MIT

## Usage

```bash
chmod +x installwp-en.sh
./installwp-en.sh
```

### Dry run

Dry run asks all questions, prints the plan/summary, and then exits **without** changing files/databases:

```bash
./installwp-en.sh --dry-run
```

## Disclaimer

This project is provided **“AS IS”**, without warranty. Use at your own risk.

## Credits / Backstory

This work came from multiple independent threads:

- **Brian Coords** published the idea/tutorial for a local setup with Herd, DBngin and WP-CLI:
  - https://www.briancoords.com/local-wordpress-with-herd-dbngin-and-wp-cli/
  - https://github.com/bacoords
- **Riza** created an initial script that served as the starting point:
  - https://github.com/rizaardiyanto1412/rizaardiyanto1412/blob/main/installwp.sh
- **Roman Mahr** tested the workflow extensively and contributed requirements/improvements; further iterations followed.

Contributions/forks (e.g. Windows/Linux ports) are welcome.

## License

This project is licensed under the MIT License.  
See the LICENSE file for details.
