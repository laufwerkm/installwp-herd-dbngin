# installwp (macOS) — Herd + DBngin + WP-CLI

Dieses Repository enthält ein interaktives Bash-Skript, das eine lokale WordPress-Installation **unter macOS** automatisiert – optimiert für **Herd** (Web/PHP) und **DBngin** (Datenbank-Services).

## Für wen ist das?

Für WordPress-Developer:innen, die schnell wiederholbare lokale Test-Installationen erstellen möchten (z.B. Theme-/Plugin-Entwicklung, WooCommerce-Tests, Symlink-Workflows).

## Voraussetzungen

- macOS
- [Herd](https://herd.laravel.com/) installiert
- [DBngin](https://dbngin.com/download) installiert und **MySQL** oder **MariaDB** läuft
- `wp` (WP-CLI) im PATH (Herd liefert häufig ein `wp` mit)
- `curl`, `unzip` (standardmäßig auf macOS vorhanden)

## Dateien

- `installwp-de.sh` — deutsche Version (Prompts/Logs/Kommentare)
- `installwp-en.sh` — englische Version (Prompts/Logs/Kommentare)
- `LICENSE` — MIT

## Nutzung

```bash
chmod +x installwp-de.sh
./installwp-de.sh
```

### Dry Run

Dry Run führt alle Abfragen aus, zeigt die geplanten Schritte (Plan/Summary) und beendet dann, **ohne** Dateien/Datenbanken zu verändern:

```bash
./installwp-de.sh --dry-run
```

## Haftungsausschluss

Dieses Projekt wird **„AS IS“** bereitgestellt, ohne Gewährleistung. Nutzung auf eigene Verantwortung.

## Credits / Geschichte

Die Arbeit ist aus mehreren unabhängigen Strängen entstanden:

- **Brian Coords** veröffentlichte die Idee/Anleitung für ein lokales Setup mit Herd, DBngin und WP-CLI:
  - https://www.briancoords.com/local-wordpress-with-herd-dbngin-and-wp-cli/
  - https://github.com/bacoords
- **Riza** entwickelte daraus ein Script als Ausgangsbasis:
  - https://github.com/rizaardiyanto1412/rizaardiyanto1412/blob/main/installwp.sh
- **Roman Mahr** hat den Workflow umfangreich getestet und Anforderungen/Verbesserungen eingebracht; daraus entstanden weitere Iterationen.

Beiträge/Weiterentwicklungen (z.B. Windows/Linux-Port) sind willkommen.

## License

This project is licensed under the MIT License.  
See the LICENSE file for details.
