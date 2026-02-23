#!/usr/bin/env bash
set -euo pipefail

VERSION="1.9"

# =========================
# FileHound — OSINT File Finder + DNS(AXFR optional) + ExifTool + HTML Report
# =========================

# ---------------- Defaults ----------------
MAX_BYTES_DEFAULT=$((50*1024*1024))  # 50MB
MAX_BYTES="$MAX_BYTES_DEFAULT"

# Automatic filetypes (common)
FILETYPES_DEFAULT="pdf,doc,docx,xls,xlsx,ppt,pptx,txt,csv,json,xml,zip,rar,7z,sql,log"
FILETYPES="$FILETYPES_DEFAULT"

# Engines default
ENGINES="all"  # brave,bing,ddg,yandex,ecosia,qwant,swisscows,mojeek,all

# Mode default
MODE="full" # urls|download|full

# Safe timing defaults
DELAY_MS=1200        # base delay between requests
JITTER_MS=800        # extra random (0..JITTER_MS)
DOWNLOAD_DELAY_MS=900
DOWNLOAD_JITTER_MS=700

# DNS / AXFR module (OFF by default)
DNS_DISCOVERY="off"  # on|off
AXFR_RETRIES=2
AXFR_TIMEOUT=4       # seconds
AXFR_BACKOFF="2,6"   # seconds, comma list
MAX_HOSTS=120        # cap to avoid explosion

# User-Agent rotation (DEFAULT = rotate)
UA_MODE="rotate"     # fixed|phase|rotate
UA_FIXED="FileHound/${VERSION} (Authorized security test)"
UA_FILE=""           # optional file with 1 UA per line
UA_PHASE=""          # search|download

# Optional: use lynx dump and/or wget dump as fallback (if installed)
FETCH_FALLBACK="auto"  # auto|off|on

# Identity in HTML
CREATOR_NAME="Taissocout"
GITHUB_USER="taissocout"
LINKEDIN_USER="taissocout_cybersecurity"

# ---------------- UA list (known) ----------------
UA_LIST_DEFAULT=(
  # Chrome Windows
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  # Chrome Linux
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  # Chrome macOS
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 12_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  # Firefox
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0"
  "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13.6; rv:123.0) Gecko/20100101 Firefox/123.0"

  # Edge
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"

  # Safari macOS
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 12_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

  # iPhone Safari
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Mobile/15E148 Safari/604.1"
  "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

  # Android Chrome
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"
  "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
)

UA_LIST=()

# ---------------- Terminal banner + tutorial ----------------
banner_term() {
cat <<'EOF'
  ______ _ _      _   _                       _
 |  ____(_) |    | | | |                     | |
 | |__   _| | ___| |_| | ___  _   _ _ __   __| |
 |  __| | | |/ _ \  _  |/ _ \| | | | '_ \ / _` |
 | |    | | |  __/ | | | (_) | |_| | | | | (_| |
 |_|    |_|_|\___\_| |_/\___/ \__,_|_| |_|\__,_|

   FileHound — OSINT File Finder + DNS(AXFR optional) + HTML Report (ExifTool)
EOF
echo "   v$VERSION"
echo
}

tutorial() {
cat <<EOF
==================== COMO USAR (AUTOMÁTICO) ====================

Este FileHound (v${VERSION}) faz tudo automaticamente:
  1) Busca URLs de arquivos públicos no TARGET (em vários buscadores)
  2) Baixa os arquivos (valida tipo/tamanho; evita baixar HTML)
  3) Extrai metadados (exiftool)
  4) Gera relatório HTML em: report/<nome>.html
  5) Imprime um link file:// para abrir no navegador

O que você vai digitar quando ele pedir:

1) TARGET (domínio)
   Exemplos:
     example.com
     businesscorp.com.br
     www.exemplo.com
   (sem https://)

2) REPORT NAME (nome do relatório)
   Exemplos (SEM .html):
     relatorio
     report_empresa_2026
   Saída:
     report/<nome>.html

OPCIONAL (avançado):
- DNS discovery (AXFR) para tentar listar hosts (somente se autorizado):
    --dns on

EXEMPLOS:
  Rodar padrão (FULL):
    ./filehound.sh -t example.com --report-name relatorio

  Com DNS discovery (AXFR opcional + host expansion):
    ./filehound.sh -t example.com --report-name relatorio --dns on

  Só URLs (sem baixar e sem HTML):
    ./filehound.sh -t example.com --mode urls --report-name lista

===============================================================

EOF
}

usage() {
cat <<EOF
Uso:
  $0 -t TARGET --report-name NAME [opções]

Opções:
  --mode urls|download|full        (default: full)
  -e, --engines LIST              (default: all)
  -f, --filetypes LIST            (default: ${FILETYPES_DEFAULT})
  --max-mb N                      (default: 50)
  --delay-ms N                    (default: ${DELAY_MS})
  --jitter-ms N                   (default: ${JITTER_MS})
  --download-delay-ms N           (default: ${DOWNLOAD_DELAY_MS})
  --download-jitter-ms N          (default: ${DOWNLOAD_JITTER_MS})

  --dns on|off                    (default: off)
  --axfr-retries N                (default: ${AXFR_RETRIES})
  --axfr-timeout N                (default: ${AXFR_TIMEOUT})
  --axfr-backoff "2,6,10"         (default: ${AXFR_BACKOFF})
  --max-hosts N                   (default: ${MAX_HOSTS})

  --ua-mode fixed|phase|rotate    (default: rotate)
  --ua "UA string"                (for ua-mode fixed)
  --ua-file uas.txt               (1 UA per line)

  --fetch-fallback auto|on|off    (default: auto) use lynx/wget text dump if installed

Exemplos:
  $0 -t example.com --report-name relatorio
  $0 -t example.com --report-name relatorio --dns on
  $0 -t example.com --mode urls --report-name lista
EOF
}

# ---------------- helpers ----------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Missing dependency: $1"
    echo "    Install: sudo apt-get update && sudo apt-get install -y $1"
    exit 1
  }
}
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

sleep_ms() {
  local ms="$1"
  python3 - <<PY 2>/dev/null || sleep 1
import time
time.sleep(${ms}/1000.0)
PY
}

jitter_sleep() {
  local base_ms="$1"
  local jitter_ms="$2"
  local extra=$(( RANDOM % (jitter_ms + 1) ))
  local total=$(( base_ms + extra ))
  sleep_ms "$total"
}

urlencode() {
  if have_cmd python3; then
    python3 - <<'PY'
import urllib.parse, sys
print(urllib.parse.quote(sys.stdin.read().strip()))
PY
  else
    sed -e 's/ /%20/g' -e 's/:/%3A/g' -e 's/\//%2F/g' -e 's/?/%3F/g' -e 's/&/%26/g'
  fi
}

load_ua_list() {
  UA_LIST=()
  if [[ -n "${UA_FILE:-}" ]]; then
    [[ -f "$UA_FILE" ]] || { echo "[!] UA file not found: $UA_FILE"; exit 1; }
    while IFS= read -r line; do
      line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^# ]] && continue
      UA_LIST+=("$line")
    done < "$UA_FILE"
  fi
  if [[ "${#UA_LIST[@]}" -eq 0 ]]; then
    UA_LIST=("${UA_LIST_DEFAULT[@]}")
  fi
}

pick_ua() {
  case "${UA_MODE}" in
    fixed) echo "$UA_FIXED" ;;
    phase)
      case "${UA_PHASE}" in
        search) echo "${UA_LIST[0]}" ;;
        download) echo "${UA_LIST[1]:-${UA_LIST[0]}}" ;;
        *) echo "$UA_FIXED" ;;
      esac
      ;;
    rotate)
      local idx=$((RANDOM % ${#UA_LIST[@]}))
      echo "${UA_LIST[$idx]}"
      ;;
    *) echo "$UA_FIXED" ;;
  esac
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

# ---------------- HTTP fetchers ----------------
fetch_curl() {
  local url="$1"
  UA_PHASE="search"
  curl -sL --max-time 25 -A "$(pick_ua)" "$url" || true
}

fetch_lynx_dump() {
  local url="$1"
  # text dump; useful when HTML parsing gets messy
  lynx --dump -nolist "$url" 2>/dev/null || true
}

fetch_wget() {
  local url="$1"
  wget -qO- --timeout=25 --tries=1 "$url" 2>/dev/null || true
}

# ---------------- Engines (URLs) ----------------
engine_url() {
  local engine="$1"
  local q="$2"
  case "$engine" in
    brave) echo "https://search.brave.com/search?q=${q}" ;;
    bing) echo "https://www.bing.com/search?q=${q}" ;;
    ddg) echo "https://duckduckgo.com/html/?q=${q}" ;;
    yandex) echo "https://yandex.com/search/?text=${q}" ;;
    ecosia) echo "https://www.ecosia.org/search?q=${q}" ;;
    qwant) echo "https://www.qwant.com/?q=${q}" ;;
    swisscows) echo "https://swisscows.com/web?query=${q}" ;;
    mojeek) echo "https://www.mojeek.com/search?q=${q}" ;;
    *) return 1 ;;
  esac
}

run_engines() {
  local engines_csv="$1"
  local encoded_q="$2"
  local raw_dir="$3"

  UA_PHASE="search"

  IFS=',' read -r -a engines <<< "$engines_csv"
  for e in "${engines[@]}"; do
    e="$(echo "$e" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$e" ]] && continue

    if [[ "$e" == "all" ]]; then
      run_engines "brave,bing,ddg,yandex,ecosia,qwant,swisscows,mojeek" "$encoded_q" "$raw_dir"
      return 0
    fi

    local url
    url="$(engine_url "$e" "$encoded_q" 2>/dev/null || true)"
    [[ -z "$url" ]] && { echo "[!] Unknown engine: $e" >&2; continue; }

    # HTML capture
    fetch_curl "$url" > "$raw_dir/${e}.html" || true

    # fallback text dump (optional)
    if [[ "$FETCH_FALLBACK" != "off" ]]; then
      if have_cmd lynx; then
        fetch_lynx_dump "$url" > "$raw_dir/${e}.dump.txt" || true
      elif [[ "$FETCH_FALLBACK" == "on" && have_cmd wget ]]; then
        fetch_wget "$url" > "$raw_dir/${e}.wget.html" || true
      fi
    fi

    jitter_sleep "$DELAY_MS" "$JITTER_MS"
  done
}

# ---------------- Download validation ----------------
is_probably_file() {
  local url="$1"
  [[ "$url" =~ \.(pdf|doc|docx|xls|xlsx|ppt|pptx|txt|csv|json|xml|zip|rar|7z|sql|log)($|\?) ]]
}

head_info() {
  local url="$1"
  UA_PHASE="download"
  curl -sIL --max-time 20 -A "$(pick_ua)" "$url" \
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
  if [[ -n "${cl:-}" && "$cl" =~ ^[0-9]+$ && "$cl" -gt "$MAX_BYTES" ]]; then
    return 1
  fi

  if [[ -z "$ct" ]]; then
    is_probably_file "$url" && { echo "$final"; return 0; }
    return 1
  fi

  if echo "$ct" | grep -Eq \
    "application/pdf|application/msword|application/vnd\.openxmlformats-officedocument|application/vnd\.ms|text/plain|text/csv|application/zip|application/x-7z-compressed|application/x-rar|application/octet-stream|application/xml|text/xml|application/json|text/json"; then
    echo "$final"
    return 0
  fi

  is_probably_file "$url" && { echo "$final"; return 0; }
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

  UA_PHASE="download"
  curl -sL --max-time 90 -A "$(pick_ua)" "$final" -o "$out" || return 1

  # if became HTML, drop it
  if file -b "$out" | grep -qi "html"; then
    rm -f "$out"
    return 1
  fi

  echo "$out"
}

# ---------------- Metadata extraction (important fields) ----------------
top_kv_from_exif_full() {
  local file_txt="$1"
  grep -E '^(File Name|File Type|MIME Type|File Size|Create Date|Modify Date|PDF Producer|Producer|Creator Tool|Creator|Author|Last Modified By|Company|Manager|Department|Title|Subject|Keywords|Language|Template|Revision Number|Document ID|Instance ID|XMP Toolkit|Generator|Application|Software|Converting Tool|Page Count|Host Name|User Name)\s*:' \
    "$file_txt" 2>/dev/null || true
}

# ---------------- DNS: NS + AXFR optional ----------------
dns_get_ns() {
  local target="$1"
  dig +short NS "$target" 2>/dev/null | sed 's/\.$//' | awk 'NF' | sort -u
}

dns_try_axfr_once() {
  local target="$1"
  local ns="$2"
  # returns zone output or empty
  dig @"$ns" AXFR "$target" +time="$AXFR_TIMEOUT" +tries=1 2>/dev/null || true
}

dns_extract_hosts_from_axfr() {
  # parse hostnames from AXFR output lines like: host IN A ip
  awk '
    $4 ~ /A|AAAA|CNAME/ {
      gsub(/\.$/,"",$1);
      print $1
    }
  ' | awk 'NF' | sort -u
}

dns_discovery() {
  local target="$1"
  local out_hosts_file="$2"
  : > "$out_hosts_file"

  echo "[*] DNS discovery enabled: getting NS..."
  local ns_list
  ns_list="$(dns_get_ns "$target" || true)"
  if [[ -z "$ns_list" ]]; then
    echo "    [-] No NS found (dig failed?)"
    return 0
  fi
  echo "$ns_list" | sed 's/^/    [+] NS: /'

  echo "[*] Trying AXFR (zone transfer) with limits..."
  local found="no"
  local retries="$AXFR_RETRIES"
  local backoff_arr
  IFS=',' read -r -a backoff_arr <<< "$AXFR_BACKOFF"

  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    echo "    [*] NS: $ns"

    for ((i=1; i<=retries; i++)); do
      echo "       - AXFR attempt $i/$retries ..."
      local out
      out="$(dns_try_axfr_once "$target" "$ns")"

      # If successful, AXFR output contains many records and usually "Transfer failed." is absent
      if echo "$out" | grep -qiE "Transfer failed|connection timed out|refused|notauth|SERVFAIL"; then
        :
      else
        # Heuristic: output has IN SOA and multiple lines
        if echo "$out" | grep -qE "IN[[:space:]]+SOA" && [[ "$(echo "$out" | wc -l | tr -d ' ')" -gt 10 ]]; then
          echo "       [+] AXFR seems SUCCESSFUL on $ns"
          echo "$out" | dns_extract_hosts_from_axfr >> "$out_hosts_file"
          found="yes"
          break
        fi
      fi

      # Backoff sleep
      local s="${backoff_arr[$((i-1))]:-${backoff_arr[-1]:-5}}"
      echo "       - backoff ${s}s"
      sleep "$s"
    done

    [[ "$found" == "yes" ]] && break
  done <<< "$ns_list"

  if [[ -s "$out_hosts_file" ]]; then
    sort -u "$out_hosts_file" -o "$out_hosts_file"

    # Keep only hosts within target (basic scope safety)
    grep -E "(^|[.])$(echo "$target" | sed 's/\./\\./g')$" "$out_hosts_file" > "$out_hosts_file.tmp" || true
    mv -f "$out_hosts_file.tmp" "$out_hosts_file"

    # Cap host count
    local hc
    hc="$(wc -l < "$out_hosts_file" | tr -d ' ')"
    if [[ "$hc" -gt "$MAX_HOSTS" ]]; then
      head -n "$MAX_HOSTS" "$out_hosts_file" > "$out_hosts_file.tmp"
      mv -f "$out_hosts_file.tmp" "$out_hosts_file"
      echo "    [!] Host list capped to MAX_HOSTS=$MAX_HOSTS"
    fi

    echo "    [+] Hosts discovered: $(wc -l < "$out_hosts_file" | tr -d ' ')"
  else
    echo "    [-] AXFR not available (normal/expected)."
  fi
}

# ---------------- CLI args ----------------
TARGET=""
OUTDIR=""
REPORT_BASENAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET="$2"; shift 2 ;;
    -o|--out) OUTDIR="$2"; shift 2 ;;
    --report-name) REPORT_BASENAME="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    -e|--engines) ENGINES="$2"; shift 2 ;;
    -f|--filetypes) FILETYPES="$2"; shift 2 ;;
    --max-mb) MAX_BYTES=$(( "$2" * 1024 * 1024 )); shift 2 ;;

    --delay-ms) DELAY_MS="$2"; shift 2 ;;
    --jitter-ms) JITTER_MS="$2"; shift 2 ;;
    --download-delay-ms) DOWNLOAD_DELAY_MS="$2"; shift 2 ;;
    --download-jitter-ms) DOWNLOAD_JITTER_MS="$2"; shift 2 ;;

    --dns) DNS_DISCOVERY="$2"; shift 2 ;;
    --axfr-retries) AXFR_RETRIES="$2"; shift 2 ;;
    --axfr-timeout) AXFR_TIMEOUT="$2"; shift 2 ;;
    --axfr-backoff) AXFR_BACKOFF="$2"; shift 2 ;;
    --max-hosts) MAX_HOSTS="$2"; shift 2 ;;

    --ua-mode) UA_MODE="$2"; shift 2 ;;
    --ua) UA_FIXED="$2"; shift 2 ;;
    --ua-file) UA_FILE="$2"; shift 2 ;;

    --fetch-fallback) FETCH_FALLBACK="$2"; shift 2 ;;

    -h|--help|--ajuda) usage; exit 0 ;;
    *) echo "[!] Argumento inválido: $1"; usage; exit 1 ;;
  esac
done

banner_term
tutorial

# ---------------- Dependencies ----------------
need_cmd curl
need_cmd exiftool
need_cmd file
need_cmd sha256sum
need_cmd dig
need_cmd python3

load_ua_list

# ---------------- Ask only what matters ----------------
if [[ -z "${TARGET}" ]]; then
  read -rp "Target (ex: example.com ou www.exemplo.com): " TARGET
fi

if [[ -z "${REPORT_BASENAME}" ]]; then
  read -rp "Report name (SEM .html) (ex: relatorio | ENTER=REPORT): " rn
  REPORT_BASENAME="${rn:-REPORT}"
fi
REPORT_BASENAME="${REPORT_BASENAME%.html}"
REPORT_NAME="${REPORT_BASENAME}.html"

if [[ -z "${OUTDIR}" ]]; then
  TS="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="filehound_${TARGET}_${TS}"
fi

mkdir -p "$OUTDIR"/{raw,urls,downloads,metadata,report,logs}

# ---------------- Optional DNS discovery ----------------
HOSTS_FILE="$OUTDIR/report/hosts.txt"
: > "$HOSTS_FILE"
if [[ "$DNS_DISCOVERY" == "on" ]]; then
  dns_discovery "$TARGET" "$HOSTS_FILE" || true
fi

# Prepare list of "site:" scopes: base target + discovered hosts
SITES_FILE="$OUTDIR/report/sites.txt"
: > "$SITES_FILE"
echo "$TARGET" >> "$SITES_FILE"
if [[ -s "$HOSTS_FILE" ]]; then
  cat "$HOSTS_FILE" >> "$SITES_FILE"
fi
sort -u "$SITES_FILE" -o "$SITES_FILE"

echo
echo "==================== RESUMO DA EXECUÇÃO ===================="
echo "Target:          $TARGET"
echo "Mode:            $MODE"
echo "Engines:         $ENGINES"
echo "Filetypes:       $FILETYPES (auto)"
echo "DNS discovery:   $DNS_DISCOVERY"
echo "Hosts (AXFR):    $(wc -l < "$HOSTS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
echo "Max size:        $((MAX_BYTES/1024/1024)) MB"
echo "UA mode:         $UA_MODE"
echo "Report:          report/$REPORT_NAME"
echo "Output dir:      $OUTDIR"
echo "============================================================"
echo

# ---------------- Search URLs (base + hosts) ----------------
ALL_URLS_FILE="$OUTDIR/urls/all_urls.txt"
: > "$ALL_URLS_FILE"

IFS=',' read -r -a exts <<< "$FILETYPES"

while IFS= read -r site; do
  [[ -z "$site" ]] && continue

  echo "[*] Scope site:$site"

  for ext in "${exts[@]}"; do
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$ext" ]] && continue

    echo "    [*] Searching .${ext} ..."
    DORK="site:${site} ext:${ext}"
    ENC_Q="$(printf "%s" "$DORK" | urlencode)"

    RAW_DIR="$OUTDIR/raw/${site}/${ext}"
    mkdir -p "$RAW_DIR"

    run_engines "$ENGINES" "$ENC_Q" "$RAW_DIR"

    URLS_EXT_FILE="$OUTDIR/urls/${site}_${ext}.txt"
    : > "$URLS_EXT_FILE"

    # Extract from HTML + optional dumps
    cat "$RAW_DIR"/*.html 2>/dev/null | extract_urls_by_ext "$ext" >> "$URLS_EXT_FILE" || true
    cat "$RAW_DIR"/*.dump.txt 2>/dev/null | extract_urls_by_ext "$ext" >> "$URLS_EXT_FILE" || true
    cat "$RAW_DIR"/*.wget.html 2>/dev/null | extract_urls_by_ext "$ext" >> "$URLS_EXT_FILE" || true

    sanitize_urls < "$URLS_EXT_FILE" > "$URLS_EXT_FILE.tmp" && mv "$URLS_EXT_FILE.tmp" "$URLS_EXT_FILE"

    local_count="$(wc -l < "$URLS_EXT_FILE" | tr -d ' ')"
    echo "        -> ${local_count} URLs"

    cat "$URLS_EXT_FILE" >> "$ALL_URLS_FILE"
  done
done < "$SITES_FILE"

sanitize_urls < "$ALL_URLS_FILE" > "$ALL_URLS_FILE.tmp" && mv "$ALL_URLS_FILE.tmp" "$ALL_URLS_FILE"
TOTAL_URLS="$(wc -l < "$ALL_URLS_FILE" | tr -d ' ')"

echo
echo "[*] Total unique URLs: $TOTAL_URLS"
echo "[*] URL list: $ALL_URLS_FILE"
echo

if [[ "$MODE" == "urls" ]]; then
  echo "[i] MODE=urls -> finalizado."
  exit 0
fi

# ---------------- Download ----------------
DOWN_DIR="$OUTDIR/downloads"
META_DIR="$OUTDIR/metadata"
REPORT_HTML="$OUTDIR/report/$REPORT_NAME"

DOWNLOADED_LIST="$OUTDIR/report/downloaded_files.txt"
DOWNLOAD_MAP="$OUTDIR/report/download_map.tsv"   # url \t saved_path
: > "$DOWNLOADED_LIST"
: > "$DOWNLOAD_MAP"

if [[ "$TOTAL_URLS" -gt 0 ]]; then
  echo "[*] Downloading (with validation + safe timing)..."
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    if out="$(download_one "$u" "$DOWN_DIR" 2>/dev/null)"; then
      echo "$out" >> "$DOWNLOADED_LIST"
      printf "%s\t%s\n" "$u" "$out" >> "$DOWNLOAD_MAP"
      echo "    [+] OK: $(basename "$out")"
    else
      echo "    [-] SKIP: $u"
    fi
    jitter_sleep "$DOWNLOAD_DELAY_MS" "$DOWNLOAD_JITTER_MS"
  done < "$ALL_URLS_FILE"

  sort -u "$DOWNLOADED_LIST" -o "$DOWNLOADED_LIST"
  sort -u "$DOWNLOAD_MAP" -o "$DOWNLOAD_MAP"

  echo "    -> $(wc -l < "$DOWNLOADED_LIST" | tr -d ' ') valid files downloaded"
else
  echo "[*] No URLs found. Skipping download."
fi

if [[ "$MODE" == "download" ]]; then
  echo "[i] MODE=download -> finalizado."
  exit 0
fi

# ---------------- Metadata ----------------
echo
echo "[*] Extracting metadata (exiftool) ..."
if [[ -s "$DOWNLOADED_LIST" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    bn="$(basename "$f")"
    safe="${bn//[^a-zA-Z0-9._-]/_}"
    exiftool "$f" > "$META_DIR/${safe}.exif.txt" 2>/dev/null || true
    exiftool -json "$f" > "$META_DIR/${safe}.exif.json" 2>/dev/null || true
  done < "$DOWNLOADED_LIST"
fi

# ---------------- HTML report ----------------
echo "[*] Writing HTML report..."
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
DL_COUNT="$(wc -l < "$DOWNLOADED_LIST" 2>/dev/null | tr -d ' ' || echo 0)"
HOST_COUNT="$(wc -l < "$HOSTS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"

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
    .small { font-size:12px; opacity:.85; }
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
        <div class="pill"><b>DNS</b> <span class="muted">${DNS_DISCOVERY} (hosts:${HOST_COUNT})</span></div>
        <div class="pill"><b>Max</b> <span class="muted">$((MAX_BYTES/1024/1024))MB</span></div>
        <div class="pill"><b>UA mode</b> <span class="muted">${UA_MODE}</span></div>
      </div>
      <div class="hr"></div>
      <div class="footer">
        <span><b>Creator:</b> ${CREATOR_NAME}</span>
        <span>•</span>
        <span><b>GitHub:</b> <a href="https://github.com/${GITHUB_USER}" target="_blank" rel="noreferrer">github.com/${GITHUB_USER}</a></span>
        <span>•</span>
        <span><b>LinkedIn:</b> <a href="https://www.linkedin.com/in/${LINKEDIN_USER}/" target="_blank" rel="noreferrer">linkedin.com/in/${LINKEDIN_USER}</a></span>
      </div>
      <p class="small muted">Arquivos locais do run: <code>urls/</code>, <code>downloads/</code>, <code>metadata/</code>, <code>report/</code></p>
    </div>

EOF

# Hosts section
if [[ "$DNS_DISCOVERY" == "on" ]]; then
  cat <<EOF
    <div class="card">
      <h2>0) Hosts discovered (AXFR if available)</h2>
      <p class="muted">Salvo em <code>report/hosts.txt</code>. Se vazio, AXFR não estava disponível (normal).</p>
      <pre>
EOF
  if [[ -s "$HOSTS_FILE" ]]; then
    cat "$HOSTS_FILE" | html_escape
  else
    echo "(no hosts discovered)" | html_escape
  fi
  cat <<EOF
      </pre>
    </div>
EOF
fi

# URLs section
cat <<EOF
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

# Downloads + per-file analysis
if [[ -s "$DOWNLOADED_LIST" ]]; then
cat <<EOF
    <div class="card">
      <h2>2) Downloaded Files</h2>
      <p class="muted">Mapa URL → arquivo salvo em <code>report/download_map.tsv</code></p>
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
  ft="$(file -b "$f" 2>/dev/null | head -c 110)"
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
      <h2>3) Metadata Analysis (file-by-file)</h2>
      <p class="muted">Extraído via <code>exiftool</code>. Campos importantes: Author/Company/CreatorTool/Producer/IDs/Paths.</p>
EOF

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  bn="$(basename "$f")"
  safe="${bn//[^a-zA-Z0-9._-]/_}"
  txt="$META_DIR/${safe}.exif.txt"
  [[ ! -f "$txt" ]] && continue

  bne="$(printf "%s" "$bn" | html_escape)"

  # try map original URL
  src_url="$(awk -v p="$f" -F'\t' '$2==p{print $1; exit}' "$DOWNLOAD_MAP" 2>/dev/null || true)"
  src_url_e="$(printf "%s" "${src_url:-}" | html_escape)"

  cat <<EOF
      <h3>${bne}</h3>
      <p class="muted">Source URL: <a href="${src_url_e}" target="_blank" rel="noreferrer">${src_url_e}</a></p>
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
      <p class="muted">Nenhum arquivo baixado. Possíveis causas: bloqueio/rate-limit/links não-diretos.</p>
      <p class="muted">Dica: tente mudar engines: <code>-e brave,bing</code> ou aumentar delays.</p>
    </div>
EOF
fi

cat <<EOF
    <div class="card">
      <h2>4) Next Steps</h2>
      <ul>
        <li>Priorize documentos por <b>Author/Company</b> e <b>CreatorTool/Producer</b> incomuns.</li>
        <li>Procure vazamentos de paths/usuários: <code>C:\\Users\\</code>, <code>/home/</code>, <code>\\\\server\\share</code>.</li>
        <li>Se DNS discovery estiver habilitado, valide hosts e repita o run em alvos específicos (com autorização).</li>
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

echo
echo "[✓] Done!"
echo "    - URLs:        $ALL_URLS_FILE"
echo "    - Downloads:   $DOWN_DIR"
echo "    - Metadata:    $META_DIR"
echo "    - HTML Report: $REPORT_HTML"
echo
echo "[LINK] file://$(readlink -f "$REPORT_HTML")"
echo
echo "[i] Abrir no navegador:"
echo "    xdg-open \"$(readlink -f "$REPORT_HTML")\""
echo

