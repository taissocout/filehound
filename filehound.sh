#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# FileHound — OSINT File Finder + Metadata + HTML Report
# Creator: Taissocout (github.com/taissocout | linkedin.com/in/taissocout_cybersecurity)
# =========================================================

VERSION="2.0"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

# Defaults (automatic mode)
DEFAULT_ENGINES="all"
DEFAULT_FILETYPES="pdf,doc,docx,xls,xlsx,ppt,pptx,odt,ods,odp,rtf,txt,csv,json,xml,yml,yaml,zip,rar,7z,sql,log,conf,ini,env,bak,old,tar,gz,tgz"
MAX_BYTES_DEFAULT=$((50*1024*1024))  # 50MB
SLEEP_BETWEEN_REQ=1

CREATOR_NAME="Taissocout"
GITHUB_USER="taissocout"
LINKEDIN_USER="taissocout_cybersecurity"

# ---------------- Banner (terminal) ----------------
banner_term() {
cat <<'EOF'
  ______ _ _      _   _                       _
 |  ____(_) |    | | | |                     | |
 | |__   _| | ___| |_| | ___  _   _ _ __   __| |
 |  __| | | |/ _ \  _  |/ _ \| | | | '_ \ / _` |
 | |    | | |  __/ | | | (_) | |_| | | | | (_| |
 |_|    |_|_|\___\_| |_/\___/ \__,_|_| |_|\__,_|

   FileHound — OSINT File Finder + HTML Report (ExifTool)
EOF
echo "   v$VERSION"
echo
}

# ---------------- Minimal tutorial (terminal) ----------------
tutorial_block() {
cat <<'EOF'
==================== COMO USAR (AUTOMÁTICO) ====================

Agora é 100% simples:

1) Você só informa:
   - TARGET (domínio)  -> exemplo: example.com ou empresa.com.br
   - NOME do relatório -> exemplo: relatorio (o .html é adicionado sozinho)

2) A ferramenta automaticamente:
   - Pesquisa em vários buscadores
   - Procura vários tipos de arquivo (pdf, docx, xlsx, zip, etc)
   - Baixa os arquivos (com validação)
   - Extrai metadados (exiftool)
   - Gera um relatório HTML e mostra o link file:// para abrir no navegador

DICA:
- Se não achar nada, tente outro domínio ou aumente --max-mb (caso arquivos grandes).

===============================================================
EOF
echo
}

# ---------------- Helpers ----------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Dependência ausente: $1"
    echo "    Instale: sudo apt-get update && sudo apt-get install -y $1"
    exit 1
  }
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

urlencode() {
  if have_cmd python3; then
    python3 - <<PY
import urllib.parse, sys
print(urllib.parse.quote(sys.stdin.read().strip()))
PY
  else
    sed -e 's/ /%20/g' -e 's/:/%3A/g' -e 's/\//%2F/g' -e 's/?/%3F/g' -e 's/&/%26/g'
  fi
}

sanitize_urls() {
  sed -E \
    -e 's/&amp;/\&/g' \
    -e 's/%3D/=/gI' \
    -e 's/%2F/\//gI' \
    -e 's/%3A/:/gI' \
    -e 's/[)\],.;]+$//g' \
  | awk 'NF' | sort -u
}

extract_urls_by_ext() {
  local ext="$1"
  grep -Eoi "https?://[^\"' <>]+\.${ext}([?][^\"' <>]+)?" | sanitize_urls
}

fetch() {
  local url="$1"
  curl -sL --max-time 25 -A "$UA" "$url" || true
}

# ---------------- Engines ----------------
engine_brave()     { fetch "https://search.brave.com/search?q=$1"; }
engine_bing()      { fetch "https://www.bing.com/search?q=$1"; }
engine_ddg()       { fetch "https://duckduckgo.com/html/?q=$1"; }
engine_yandex()    { fetch "https://yandex.com/search/?text=$1"; }
engine_ecosia()    { fetch "https://www.ecosia.org/search?q=$1"; }
engine_qwant()     { fetch "https://www.qwant.com/?q=$1"; }
engine_swisscows() { fetch "https://swisscows.com/web?query=$1"; }
engine_mojeek()    { fetch "https://www.mojeek.com/search?q=$1"; }

run_engines() {
  local engines_csv="$1"
  local encoded_q="$2"
  local raw_dir="$3"

  IFS=',' read -r -a engines <<< "$engines_csv"
  for e in "${engines[@]}"; do
    e="$(echo "$e" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$e" in
      brave)       engine_brave     "$encoded_q" > "$raw_dir/brave.html" ;;
      bing)        engine_bing      "$encoded_q" > "$raw_dir/bing.html" ;;
      ddg|duckduckgo) engine_ddg    "$encoded_q" > "$raw_dir/ddg.html" ;;
      yandex)      engine_yandex    "$encoded_q" > "$raw_dir/yandex.html" ;;
      ecosia)      engine_ecosia    "$encoded_q" > "$raw_dir/ecosia.html" ;;
      qwant)       engine_qwant     "$encoded_q" > "$raw_dir/qwant.html" ;;
      swisscows)   engine_swisscows "$encoded_q" > "$raw_dir/swisscows.html" ;;
      mojeek)      engine_mojeek    "$encoded_q" > "$raw_dir/mojeek.html" ;;
      all)
        engine_brave     "$encoded_q" > "$raw_dir/brave.html"
        engine_bing      "$encoded_q" > "$raw_dir/bing.html"
        engine_ddg       "$encoded_q" > "$raw_dir/ddg.html"
        engine_yandex    "$encoded_q" > "$raw_dir/yandex.html"
        engine_ecosia    "$encoded_q" > "$raw_dir/ecosia.html"
        engine_qwant     "$encoded_q" > "$raw_dir/qwant.html"
        engine_swisscows "$encoded_q" > "$raw_dir/swisscows.html"
        engine_mojeek    "$encoded_q" > "$raw_dir/mojeek.html"
        ;;
      *)
        echo "[!] Engine desconhecido: $e (ignorando)"
        ;;
    esac
    sleep "$SLEEP_BETWEEN_REQ"
  done
}

# ---------------- Download + validation ----------------
head_info() {
  local url="$1"
  curl -sIL --max-time 20 -A "$UA" "$url" \
    -o /dev/stdout \
    -w "\n__FINAL_URL__:%{url_effective}\n"
}

should_download() {
  local url="$1"
  local info ct cl final
  info="$(head_info "$url" || true)"
  ct="$(echo "$info" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tail -n1)"
  cl="$(echo "$info" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -n1)"
  final="$(echo "$info" | tr -d '\r' | awk -F':' '/__FINAL_URL__/{sub(/^__FINAL_URL__:/,"");print;exit}')"

  [[ -n "$ct" ]] && echo "$ct" | grep -q "text/html" && return 1
  if [[ -n "${cl:-}" && "$cl" =~ ^[0-9]+$ && "$cl" -gt "${MAX_BYTES:-$MAX_BYTES_DEFAULT}" ]]; then
    return 1
  fi

  # Accept a broad set of "file-ish" content types
  if [[ -n "$ct" ]] && echo "$ct" | grep -Eq \
    "application/pdf|application/msword|application/vnd\.openxmlformats-officedocument|application/vnd\.ms|text/plain|text/csv|application/zip|application/x-7z-compressed|application/x-rar|application/octet-stream|application/xml|text/xml|application/json|text/json|application/gzip|application/x-tar"; then
    echo "$final"
    return 0
  fi

  # If no content-type, still allow (we'll validate after download using `file`)
  if [[ -z "$ct" ]]; then
    echo "$final"
    return 0
  fi

  return 1
}

safe_filename_from_url() {
  local url="$1"
  local base
  base="$(basename "${url%%\?*}")"
  base="${base//[^a-zA-Z0-9._-]/_}"
  [[ -z "$base" || "$base" == "/" ]] && base="downloaded_file"
  echo "$base"
}

unique_path() {
  local path="$1"
  [[ ! -e "$path" ]] && { echo "$path"; return 0; }
  local dir base ext n
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  ext=""
  if [[ "$base" == *.* ]]; then
    ext=".${base##*.}"
    base="${base%.*}"
  fi
  n=2
  while [[ -e "$dir/${base}_${n}${ext}" ]]; do n=$((n+1)); done
  echo "$dir/${base}_${n}${ext}"
}

download_one() {
  local url="$1"
  local out_dir="$2"
  local final name out

  final="$(should_download "$url")" || return 1
  name="$(safe_filename_from_url "$final")"
  out="$(unique_path "$out_dir/$name")"

  curl -sL --max-time 90 -A "$UA" "$final" -o "$out" || return 1

  # Validate not HTML
  if file -b "$out" | grep -qi "html"; then
    rm -f "$out"
    return 1
  fi

  # Validate size (post-download)
  local sz
  sz="$(stat -c%s "$out" 2>/dev/null || echo 0)"
  if [[ "$sz" -gt "${MAX_BYTES:-$MAX_BYTES_DEFAULT}" ]]; then
    rm -f "$out"
    return 1
  fi

  echo "$out"
}

# ---------------- HTML helpers ----------------
html_escape() {
  sed -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&#39;/g"
}

html_banner() {
cat <<'EOF'
<pre class="banner">
  ______ _ _      _   _                       _
 |  ____(_) |    | | | |                     | |
 | |__   _| | ___| |_| | ___  _   _ _ __   __| |
 |  __| | | |/ _ \  _  |/ _ \| | | | '_ \ / _` |
 | |    | | |  __/ | | | (_) | |_| | | | | (_| |
 |_|    |_|_|\___\_| |_/\___/ \__,_|_| |_|\__,_|

 FileHound — OSINT File Finder + Metadata Report
</pre>
EOF
}

top_kv_from_exif_full() {
  local file_txt="$1"
  grep -E '^(File Name|File Type|MIME Type|File Size|Create Date|Modify Date|PDF Producer|Producer|Creator Tool|Creator|Author|Last Modified By|Company|Manager|Department|Title|Subject|Keywords|Language|Template|Revision Number|Document ID|Instance ID|XMP Toolkit|Generator|Application|Software|Converting Tool|Page Count|Host Name|User Name|Hyperlinks)\s*:' \
    "$file_txt" 2>/dev/null || true
}

count_software_from_txts() {
  local meta_dir="$1"
  grep -RhsE '^(Creator Tool|Producer|PDF Producer|Software|Application|Generator)\s*:' "$meta_dir" \
    | sed -E 's/^[^:]+:\s*//g' \
    | awk 'NF' | sort | uniq -c | sort -nr | head -n 25 || true
}

# ---------------- CLI ----------------
usage() {
  cat <<EOF
FileHound v$VERSION

Uso (automático):
  $0 -t TARGET -r REPORT_NAME

Exemplos:
  $0 -t example.com -r relatorio
  $0 -t businesscorp.com.br -r report_empresa --max-mb 100

Opções:
  -t, --target     Domínio alvo (ex: example.com)
  -r, --report     Nome do relatório (sem .html)  -> ex: relatorio
  -o, --out        Pasta base de output (opcional)
  -e, --engines    Engines (default: all)
  -f, --filetypes  Extensões (default: lista grande)
  --max-mb         Limite máximo por arquivo (default: 50)
  --no-tutorial    Não mostrar tutorial no início
EOF
}

TARGET=""
REPORT_BASE=""
OUTDIR=""
ENGINES="$DEFAULT_ENGINES"
FILETYPES="$DEFAULT_FILETYPES"
MAX_BYTES="$MAX_BYTES_DEFAULT"
SHOW_TUTORIAL="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET="$2"; shift 2 ;;
    -r|--report) REPORT_BASE="$2"; shift 2 ;;
    -o|--out) OUTDIR="$2"; shift 2 ;;
    -e|--engines) ENGINES="$2"; shift 2 ;;
    -f|--filetypes) FILETYPES="$2"; shift 2 ;;
    --max-mb) MAX_BYTES=$(( "$2" * 1024 * 1024 )); shift 2 ;;
    --no-tutorial) SHOW_TUTORIAL="no"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Argumento inválido: $1"; usage; exit 1 ;;
  esac
done

banner_term
[[ "$SHOW_TUTORIAL" == "yes" ]] && tutorial_block

need_cmd curl
need_cmd exiftool
need_cmd file
need_cmd sha256sum
need_cmd awk
need_cmd sed
need_cmd sort
need_cmd grep
need_cmd stat
need_cmd readlink

if [[ -z "${TARGET}" ]]; then
  read -rp "Target (ex: example.com ou empresa.com.br): " TARGET
fi

if [[ -z "${REPORT_BASE}" ]]; then
  read -rp "Nome do relatório (ex: relatorio ou report_empresa): " REPORT_BASE
fi

# Sanitize report base + add .html
REPORT_BASE="${REPORT_BASE//[^a-zA-Z0-9._-]/_}"
[[ -z "$REPORT_BASE" ]] && REPORT_BASE="REPORT"
REPORT_NAME="${REPORT_BASE}.html"

if [[ -z "${OUTDIR}" ]]; then
  TS="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="filehound_${TARGET}_${TS}"
fi

# Create folders (including report/)
mkdir -p "$OUTDIR"/{raw,urls,downloads,metadata,report}

ALL_URLS_FILE="$OUTDIR/urls/all_urls.txt"
DOWNLOADED_LIST="$OUTDIR/report/downloaded_files.txt"
REPORT_HTML="$OUTDIR/report/$REPORT_NAME"
DOWN_DIR="$OUTDIR/downloads"
META_DIR="$OUTDIR/metadata"

: > "$ALL_URLS_FILE"
: > "$DOWNLOADED_LIST"

echo
echo "==================== EXECUÇÃO AUTOMÁTICA ===================="
echo "Target:        $TARGET"
echo "Engines:       $ENGINES"
echo "Filetypes:     $FILETYPES"
echo "Max size:      $((MAX_BYTES/1024/1024)) MB"
echo "Output dir:    $OUTDIR"
echo "Report file:   report/$REPORT_NAME"
echo "============================================================"
echo

# Search across all filetypes
IFS=',' read -r -a exts <<< "$FILETYPES"

for ext in "${exts[@]}"; do
  ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ -z "$ext" ]] && continue

  echo "[*] Searching .${ext} ..."
  DORK="site:${TARGET} ext:${ext}"
  ENC_Q="$(printf "%s" "$DORK" | urlencode)"

  RAW_DIR="$OUTDIR/raw/${ext}"
  mkdir -p "$RAW_DIR"

  run_engines "$ENGINES" "$ENC_Q" "$RAW_DIR"

  URLS_EXT_FILE="$OUTDIR/urls/${ext}.txt"
  : > "$URLS_EXT_FILE"

  cat "$RAW_DIR"/*.html 2>/dev/null | extract_urls_by_ext "$ext" >> "$URLS_EXT_FILE" || true
  sanitize_urls < "$URLS_EXT_FILE" > "$URLS_EXT_FILE.tmp" && mv "$URLS_EXT_FILE.tmp" "$URLS_EXT_FILE"

  echo "    -> $(wc -l < "$URLS_EXT_FILE" | tr -d ' ') URLs found"
  cat "$URLS_EXT_FILE" >> "$ALL_URLS_FILE"
  sleep "$SLEEP_BETWEEN_REQ"
done

sanitize_urls < "$ALL_URLS_FILE" > "$ALL_URLS_FILE.tmp" && mv "$ALL_URLS_FILE.tmp" "$ALL_URLS_FILE"
TOTAL_URLS="$(wc -l < "$ALL_URLS_FILE" | tr -d ' ')"

echo
echo "[*] Total unique URLs: $TOTAL_URLS"
echo "[*] URL list saved:    $ALL_URLS_FILE"
echo

# Download everything (validated)
if [[ "$TOTAL_URLS" -gt 0 ]]; then
  echo "[*] Downloading (validation on)..."
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    if out="$(download_one "$u" "$DOWN_DIR" 2>/dev/null)"; then
      echo "$out" >> "$DOWNLOADED_LIST"
      echo "    [+] OK: $(basename "$out")"
    else
      echo "    [-] SKIP: $u"
    fi
    sleep "$SLEEP_BETWEEN_REQ"
  done < "$ALL_URLS_FILE"
  sort -u "$DOWNLOADED_LIST" -o "$DOWNLOADED_LIST"
fi

DL_COUNT="$(wc -l < "$DOWNLOADED_LIST" 2>/dev/null | tr -d ' ' || echo 0)"
echo
echo "[*] Downloads valid: $DL_COUNT"
echo

# Extract metadata
echo "[*] Extracting metadata (exiftool)..."
if [[ -s "$DOWNLOADED_LIST" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    bn="$(basename "$f")"
    safe="${bn//[^a-zA-Z0-9._-]/_}"
    exiftool "$f" > "$META_DIR/${safe}.exif.txt" 2>/dev/null || true
    exiftool -json "$f" > "$META_DIR/${safe}.exif.json" 2>/dev/null || true
  done < "$DOWNLOADED_LIST"
fi

# Build HTML report
echo "[*] Writing HTML report..."
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

{
  cat <<EOF
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>FileHound Report — ${TARGET}</title>
  <style>
    :root { color-scheme: dark; }
    body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, Noto Sans, Arial; background:#0b0f14; color:#e6edf3; }
    a { color:#7dd3fc; text-decoration:none; }
    a:hover { text-decoration:underline; }
    .wrap { max-width: 1100px; margin: 0 auto; padding: 24px; }
    .card { background:#0f1620; border:1px solid #1f2a37; border-radius:16px; padding:16px; margin: 14px 0; box-shadow: 0 10px 30px rgba(0,0,0,.25); }
    .banner { color:#a7f3d0; font-size: 12px; line-height: 1.15; overflow:auto; padding:14px; border-radius:12px; background:#0b1220; border:1px solid #1f2a37; }
    .meta { display:flex; gap:12px; flex-wrap:wrap; margin-top:10px; }
    .pill { display:inline-flex; gap:8px; align-items:center; padding:8px 10px; border-radius:999px; background:#0b1220; border:1px solid #1f2a37; font-size:12px; }
    h2,h3 { margin: 10px 0; }
    h2 { font-size: 16px; opacity:.95; }
    h3 { font-size: 14px; opacity:.9; }
    table { width:100%; border-collapse: collapse; margin-top:10px; }
    th, td { border-bottom: 1px solid #1f2a37; padding: 10px; vertical-align: top; font-size: 13px; }
    th { text-align:left; opacity:.9; font-size: 12px; }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
    pre { background:#0b1220; border:1px solid #1f2a37; border-radius:12px; padding:12px; overflow:auto; }
    .footer { opacity:.85; font-size: 12px; display:flex; gap:10px; flex-wrap:wrap; }
    .hr { height:1px; background:#1f2a37; margin:14px 0; }
    .muted { opacity:.75; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      $(html_banner)
      <div class="meta">
        <div class="pill"><b>Target</b> <span class="muted">${TARGET}</span></div>
        <div class="pill"><b>Gerado</b> <span class="muted">${NOW}</span></div>
        <div class="pill"><b>Engines</b> <span class="muted">${ENGINES}</span></div>
        <div class="pill"><b>Filetypes</b> <span class="muted">${FILETYPES}</span></div>
        <div class="pill"><b>URLs</b> <span class="muted">${TOTAL_URLS}</span></div>
        <div class="pill"><b>Downloads</b> <span class="muted">${DL_COUNT}</span></div>
        <div class="pill"><b>Max</b> <span class="muted">$((MAX_BYTES/1024/1024))MB</span></div>
      </div>
      <div class="hr"></div>
      <div class="footer">
        <span><b>Creator:</b> ${CREATOR_NAME}</span>
        <span>•</span>
        <span><b>GitHub:</b> <a href="https://github.com/${GITHUB_USER}" target="_blank" rel="noreferrer">github.com/${GITHUB_USER}</a></span>
        <span>•</span>
        <span><b>LinkedIn:</b> <a href="https://www.linkedin.com/in/${LINKEDIN_USER}/" target="_blank" rel="noreferrer">linkedin.com/in/${LINKEDIN_USER}</a></span>
      </div>
    </div>

    <div class="card">
      <h2>1) URLs Found</h2>
      <p class="muted">Lista completa salva em <code>urls/all_urls.txt</code></p>
      <table>
        <thead><tr><th>#</th><th>URL</th></tr></thead>
        <tbody>
EOF

  n=0
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    n=$((n+1))
    ue="$(printf "%s" "$u" | html_escape)"
    printf '          <tr><td>%d</td><td><a href="%s" target="_blank" rel="noreferrer">%s</a></td></tr>\n' "$n" "$ue" "$ue"
  done < "$ALL_URLS_FILE"

  cat <<EOF
        </tbody>
      </table>
    </div>
EOF

  if [[ -s "$DOWNLOADED_LIST" ]]; then
    cat <<EOF
    <div class="card">
      <h2>2) Downloaded Files</h2>
      <table>
        <thead><tr><th>#</th><th>Arquivo</th><th>SHA256</th><th>Tamanho (bytes)</th><th>Tipo</th></tr></thead>
        <tbody>
EOF
    n=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      n=$((n+1))
      bn="$(basename "$f")"
      sha="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
      sz="$(stat -c%s "$f" 2>/dev/null || echo "?")"
      ft="$(file -b "$f" 2>/dev/null | head -c 120)"
      bne="$(printf "%s" "$bn" | html_escape)"
      fte="$(printf "%s" "$ft" | html_escape)"
      printf '          <tr><td>%d</td><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td></tr>\n' \
        "$n" "$bne" "$sha" "$sz" "$fte"
    done < "$DOWNLOADED_LIST"

    cat <<EOF
        </tbody>
      </table>
    </div>

    <div class="card">
      <h2>3) Metadata Highlights (Important Only)</h2>
      <p class="muted">Extraído via <code>exiftool</code>. Campos importantes por arquivo abaixo.</p>
EOF

    if have_cmd jq && ls "$META_DIR"/*.exif.json >/dev/null 2>&1; then
      cat <<EOF
      <h3>3.1) Top tools/software (contagem aproximada)</h3>
      <pre>
EOF
      jq -r '.[] | (.CreatorTool // empty),
                  (.Producer // empty),
                  (."PDF Producer" // empty),
                  (.Software // empty),
                  (.Application // empty),
                  (.Generator // empty)
            ' "$META_DIR"/*.exif.json 2>/dev/null \
        | awk 'NF' | sort | uniq -c | sort -nr | head -n 25 \
        | html_escape
      cat <<EOF
      </pre>
EOF
    else
      cat <<EOF
      <h3>3.1) Top tools/software (instale jq para melhor qualidade)</h3>
      <pre>
EOF
      count_software_from_txts "$META_DIR" | html_escape
      cat <<EOF
      </pre>
EOF
    fi

    cat <<EOF
      <h3>3.2) Per-file highlights</h3>
EOF

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      bn="$(basename "$f")"
      safe="${bn//[^a-zA-Z0-9._-]/_}"
      txt="$META_DIR/${safe}.exif.txt"
      [[ ! -f "$txt" ]] && continue
      bne="$(printf "%s" "$bn" | html_escape)"
      cat <<EOF
      <h3>${bne}</h3>
      <pre>
EOF
      top_kv_from_exif_full "$txt" | html_escape
      cat <<EOF
      </pre>
EOF
    done < "$DOWNLOADED_LIST"

    cat <<EOF
    </div>
EOF
  else
    cat <<EOF
    <div class="card">
      <h2>2) Downloads / Metadata</h2>
      <p class="muted">Nenhum arquivo baixado. Possíveis causas: bloqueio, rate-limit, links indiretos.</p>
      <p class="muted">Tente outro domínio ou aguarde e rode de novo.</p>
    </div>
EOF
  fi

  cat <<EOF
    <div class="card">
      <h2>Next Steps</h2>
      <ul>
        <li>Priorize documentos por <b>Author/Company</b> e <b>CreatorTool/Producer</b> incomuns.</li>
        <li>Procure vazamentos de paths/usuários: <code>C:\\Users\\</code>, <code>/home/</code>, <code>\\\\server\\share</code>.</li>
        <li>Correlacione achados com OSINT apenas com autorização.</li>
      </ul>
    </div>

    <div class="card">
      <div class="footer">
        <span class="muted">Generated by FileHound v${VERSION}</span>
        <span>•</span>
        <span class="muted">Creator: ${CREATOR_NAME}</span>
      </div>
    </div>

  </div>
</body>
</html>
EOF
} > "$REPORT_HTML"

ABS_REPORT="$(readlink -f "$REPORT_HTML")"
echo
echo "[✓] Finalizado!"
echo "    - Pasta output: $OUTDIR"
echo "    - Relatório:    $REPORT_HTML"
echo
echo "[LINK] file://$ABS_REPORT"
echo "[i] Abrir no navegador:"
echo "    xdg-open \"$ABS_REPORT\""
echo
