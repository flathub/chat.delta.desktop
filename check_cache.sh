#!/bin/bash
# Prueft den generierten Offline-Cache gegen die Fehlerklassen, die den Build
# bisher haben scheitern lassen: Manifest <-> Platte inkonsistent (404 im Build)
# und Groesse ueber dem 25-MB-Linter-Limit. Vom flatpak-desktop-Verzeichnis aus
# ausfuehren, nach generate.sh und commit.
set -u
IDX=generated/proxy-registry-cache-indices
MAN=generated/proxy-registry-cache-manifest.json
ok=1

# 1) pnpm: was die Sandbox installiert vs. was desktop deklariert
sandbox=$(jq -r .url generated/pnpm.json | grep -oE 'pnpm-[0-9.]+\.tgz' | sed 's/pnpm-//;s/.tgz//')
declared=$(jq -r '(.packageManager//"")|split("+")[0]|sub("^pnpm@";"")' ../deltachat-desktop/package.json)
if [ "$sandbox" = "$declared" ]; then echo "OK  pnpm-Version stimmt ($sandbox)"
else echo "FEHLER pnpm: Sandbox $sandbox != desktop $declared"; ok=0; fi

# 2) jede im Manifest referenzierte Index-Datei existiert auf der Platte
missing=$(jq -r '.[]|select(.path)|.path' "$MAN" | sort -u | while read -r p; do [ -f "$p" ] || echo "$p"; done)
if [ -z "$missing" ]; then echo "OK  alle Manifest-Indizes liegen auf der Platte"
else echo "FEHLER fehlende Dateien:"; echo "$missing"; ok=0; fi

# 3) jede Index-Datei auf der Platte ist auch im Manifest (sonst toter Ballast)
jq -r '.[]|select(.path)|.path' "$MAN" | sed "s|^$IDX/||" | sort -u > /tmp/_man.txt
(cd "$IDX" && find . -name index.json | sed 's|^\./||' | sort) > /tmp/_disk.txt
orphan=$(comm -13 /tmp/_man.txt /tmp/_disk.txt)
if [ -z "$orphan" ]; then echo "OK  keine verwaisten Index-Dateien"
else echo "WARNUNG $(echo "$orphan"|wc -l) Dateien auf Platte, nicht im Manifest (Ballast, kein 404):"; echo "$orphan"|head; fi

# 3b) link_local.sh-Aufnahme: pnpm add fragt in der Sandbox die Metadaten ALLER
# Plattform-Pakete an (auch nie heruntergeladene wie @esbuild/aix-ppc64) -
# fehlt deren Index, bricht der Build dort mit 404 ab
if [ -f "$IDX/@esbuild/aix-ppc64/index.json" ] && grep -q '@esbuild/aix-ppc64' "$MAN"; then
  echo "OK  link_local-Metadaten aufgenommen (@esbuild/aix-ppc64 vorhanden)"
else
  echo "FEHLER link_local-Metadaten fehlen (kein @esbuild/aix-ppc64-Index) - generate.sh neu laufen lassen"; ok=0
fi

# 3c) kodierte Verzeichnisse (%2F) kann replay.mjs nie ausliefern (es dekodiert
# die Anfrage vor dem Dateizugriff) - record.mjs legt deshalb dekodiert ab
enc=$(ls "$IDX" | grep -c '%2F' || true)
if [ "$enc" = 0 ]; then echo "OK  keine %2F-kodierten Verzeichnisse"
else echo "FEHLER $enc %2F-kodierte Verzeichnisse - record.mjs-Stand pruefen"; ok=0; fi

# 3d) uebergrosse Indizes deuten auf ein Paket ohne Strip-Eintrag hin
big=$(find "$IDX" -name index.json -size +200k | sort)
if [ -z "$big" ]; then echo "OK  kein Index ueber 200 KB"
else echo "WARNUNG ungestrippte Indizes (nur Groesse/Ballast, kein Buildfehler):"; echo "$big" | head; fi

# 4) jede Tarball-Quelle hat sha512 + dest
bad=$(jq -r '.[]|select(.url)|select((.sha512|not) or (.dest|not))|.url' "$MAN")
if [ -z "$bad" ]; then echo "OK  alle Tarball-Eintraege haben sha512+dest"
else echo "FEHLER unvollstaendige Tarball-Eintraege:"; echo "$bad"; ok=0; fi

# 5) Groesse gegen das 25-MB-Linter-Limit (git tree size, nur committet)
git ls-tree -r -l HEAD | awk -v ok="$ok" '
  {s+=$4} END {
    mb=s/1000000
    if (s<25000000) printf "OK  git tree: %d bytes (%.1f MB) / Limit 25 MB\n", s, mb
    else            printf "FEHLER git tree: %d bytes (%.1f MB) ueber 25 MB\n", s, mb
  }'
[ "$(git ls-tree -r -l HEAD | awk '{s+=$4} END{print (s<25000000)}')" = 1 ] || ok=0

# 6) uncommittete Aenderungen? (Linter prueft HEAD, nicht den working tree)
if git diff --quiet && git diff --cached --quiet; then echo "OK  keine uncommitteten Aenderungen"
else echo "WARNUNG working tree weicht von HEAD ab - committe vor dem Build"; fi

echo "-----"
[ "$ok" = 1 ] && echo "==> alle harten Checks bestanden" || { echo "==> es gibt Fehler (siehe oben)"; exit 1; }
