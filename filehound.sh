#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# FileHound — OSINT File Finder + Host Discovery + Per-File Analysis + HTML Report
# Creator: Taissocout (github.com/taissocout | linkedin.com/in/taissocout_cybersecurity)
# =========================================================

VERSION="2.2"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

CREATOR_NAME="Taissocout"
GITHUB_USER="taissocout"
LINKEDIN_USER="taissocout_cybersecurity"

# --- Automatic defaults ---
DEFAULT_ENGINES="all"
DEFAULT_FILETYPES="pdf,doc,docx,xls,xlsx,ppt,pptx,odt,ods,odp,rtf,txt,csv,json,xml,yml,yaml,zip,rar,7z,sql,log,conf,ini,env,bak,old,tar,gz,tgz"

MAX_BYTES_DEFAULT=$((50*1024*1024))   # 50MB per file
MAX_FILES_DEFAULT=250                 # stop after N successful downloads
HTTP_TIMEOUT=5

# --- Noise / blocking avoidance ---
# Random sleep between requests: (min..max)
SLEEP_MIN_MS_DEFAULT=1200
SLEEP_MAX_MS_DEFAULT=3800

# Simple request budget (per minute) to reduce blocks
REQ_PER_MIN_DEFAULT=25

# Global recon timeout (seconds) - prevents tool from running forever
RECON_TIMEOUT_DEFAULT=$((20*60)) # 20 min

# AXFR safety (limited tries + backoff)
AXFR_MAX_TRIES=3
AXFR_BACKOFF=(2 5 10)

# --- Per-file analysis ---
STRINGS_LINES_DEFAULT=20   # show top N interesting strings per file
STRINGS_MINLEN_DEFAULT=6

# ---------------- Banner (terminal) ----------------
banner_term() {
cat <<'EOF'
  ______ _ _      _   _                       _
 |  ____(_) |    | | | |                     | |
 | |__   _| | ___| |_| | ___  _   _ _ __   __| |
 |  __| | | |/ _ \  _  |/ _ \| | | | '_ \ / _` |
 | |    | | |  __/ | | | (_) | |_| | | | | (_| |
 |_|    |_|_|\___\_| |_/\___/ \__,_|_| |_|\__,_|

   FileHound — OSINT File Finder + Host Discovery + HTML Report (ExifTool)
EOF
echo "   v$VERSION"
echo
}

# ---------------- Tutorial (terminal) ----------------
tutorial_block() {
cat <<'EOF'
==================== COMO USAR (AUTOMÁTICO) ====================

Você só informa:
  1) TARGET (domínio)  -> exemplo: example.com ou empresa.com.br
  2) NOME do relatório -> exemplo: relatorio_empresa (o .html é adicionado sozinho)

A ferramenta automaticamente:
  A) Descobre hosts (subdomínios) por DNS/OSINT:
     - pega NS do domínio
     - tenta AXFR com limite/backoff (não insiste infinito)
     - fallback: Certificate Transparency (crt.sh)

  B) Resolve IP e testa HTTP/HTTPS (status)
  C) Busca arquivos públicos (vários tipos) no domínio raiz E em cada host encontrado
     - usa curl/wget + parsing HTML
     - se tiver LYNX instalado, usa lynx --dump (muitas vezes passa onde HTML trava)

  D) Baixa arquivos (com validação) + extrai metadados (exiftool)
  E) Gera relatório HTML com análise por arquivo e mostra link file:// para abrir no navegador

EXECUÇÃO DIRETA (sem perguntas):
  ./filehound.sh -t example.com -r relatorio

OPCIONAIS ÚTEIS:
  --max-mb 100         (aumenta limite por arquivo)
  --max-files 120      (limita quantidade de downloads)
  --recon-timeout 900  (limita recon a 15 min)
  --req-per-min 15     (menos ruído)
  --sleep-ms 900 2500  (ajusta atraso random entre requests)

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

log() { echo "[$(date '+%H:%M:%S')] $*"; }

normalize_domain() {
  local t="$1"
  t="${t#http://}"
  t="${t#https://}"
  t="${t%%/*}"
  t="${t,,}"
  echo "$t"
}

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

# ---------- Throttle / anti-block ----------
NOW_EPOCH() { date +%s; }

RANDOM_SLEEP_MS() {
  local min_ms="$1" max_ms="$2"
  if have_cmd python3; then
    python3 - <<PY
import random
print(random.randint($min_ms, $max_ms))
PY
  else
    # fallback: bash $RANDOM (0..32767)
    local range=$((max_ms - min_ms + 1))
    echo $((min_ms + (RANDOM % range)))
  fi
}

sleep_ms() {
  local ms="$1"
  # convert ms to seconds (float) using awk
  awk -v m="$ms" 'BEGIN { printf "%.3f\n", m/1000 }' | xargs -I{} sleep "{}"
}

# simple request budget per minute
REQ_WINDOW_START=0
REQ_COUNT=0

throttle_req() {
  local now
  now="$(NOW_EPOCH)"

  if [[ "$REQ_WINDOW_START" -eq 0 ]]; then
    REQ_WINDOW_START="$now"
    REQ_COUNT=0
  fi

  # if more than 60s passed, reset
  if (( now - REQ_WINDOW_START >= 60 )); then
    REQ_WINDOW_START="$now"
    REQ_COUNT=0
  fi

  if (( REQ_COUNT >= REQ_PER_MIN )); then
    local wait_s=$((60 - (now - REQ_WINDOW_START)))
    (( wait_s < 1 )) && wait_s=1
    log "[i] Rate-limit: atingiu ${REQ_PER_MIN}/min. Aguardando ${wait_s}s..."
    sleep "$wait_s"
    REQ_WINDOW_START="$(NOW_EPOCH)"
    REQ_COUNT=0
  fi

  REQ_COUNT=$((REQ_COUNT+1))

  local ms
  ms="$(RANDOM_SLEEP_MS "$SLEEP_MIN_MS" "$SLEEP_MAX_MS")"
  sleep_ms "$ms"
}

# global recon timeout
RECON_START=0
check_recon_timeout() {
  local now
  now="$(NOW_EPOCH)"
  if [[ "$RECON_START" -eq 0 ]]; then RECON_START="$now"; fi
  if (( now - RECON_START > RECON_TIMEOUT )); then
    log "[!] Recon timeout atingido (${RECON_TIMEOUT}s). Parando a fase de busca."
    return 1
  fi
  return 0
}

# ---------- Fetchers ----------
fetch_curl() {
  local url="$1"
  throttle_req
  curl -sL --max-time 25 -A "$UA" "$url" || true
}

fetch_wget() {
  local url="$1"
  throttle_req
  wget -qO- --timeout=25 --tries=1 --user-agent="$UA" "$url" 2>/dev/null || true
}

fetch_lynx_dump() {
  local url="$1"
  throttle_req
  lynx -useragent="$UA" --dump --nolist "$url" 2>/dev/null || true
}

# Chooses best fetch method (lynx if available helps bypass some blocks)
fetch_best() {
  local url="$1"
  if have_cmd lynx; then
    fetch_lynx_dump "$url"
  else
    # curl is default; fallback to wget if empty
    local out
    out="$(fetch_curl "$url")"
    [[ -n "$out" ]] && { echo "$out"; return 0; }
    fetch_wget "$url"
  fi
}

# ---------------- Engines (search URLs) ----------------
engine_brave_url()   { echo "https://search.brave.com/search?q=$1"; }
engine_bing_url()    { echo "https://www.bing.com/search?q=$1"; }
engine_ddg_url()     { echo "https://duckduckgo.com/html/?q=$1"; }
engine_yandex_url()  { echo "https://yandex.com/search/?text=$1"; }
engine_ecosia_url()  { echo "https://www.ecosia.org/search?q=$1"; }
engine_qwant_url()   { echo "https://www.qwant.com/?q=$1"; }
engine_swisscows_url(){ echo "https://swisscows.com/web?query=$1"; }
engine_mojeek_url()  { echo "https://www.mojeek.com/search?q=$1"; }

run_engines() {
  local engines_csv="$1"
  local encoded_q="$2"
  local raw_dir="$3"
  mkdir -p "$raw_dir"

  IFS=',' read -r -a engines <<< "$engines_csv"
  for e in "${engines[@]}"; do
    check_recon_timeout || return 0
    e="$(echo "$e" | tr '[:upper:]' '[:lower:]' | xargs)"
    local url=""
    case "$e" in
      brave) url="$(engine_brave_url "$encoded_q")" ;;
      bing) url="$(engine_bing_url "$encoded_q")" ;;
      ddg|duckduckgo) url="$(engine_ddg_url "$encoded_q")" ;;
      yandex) url="$(engine_yandex_url "$encoded_q")" ;;
      ecosia) url="$(engine_ecosia_url "$encoded_q")" ;;
      qwant) url="$(engine_qwant_url "$encoded_q")" ;;
      swisscows) url="$(engine_swisscows_url "$encoded_q")" ;;
      mojeek) url="$(engine_mojeek_url "$encoded_q")" ;;
      all)
        # handled below
        ;;
      *)
        log "[!] Engine desconhecido: $e (ignorando)"
        continue
        ;;
    esac

    if [[ "$e" == "all" ]]; then
      for eng in brave bing ddg yandex ecosia qwant swisscows mojeek; do
        check_recon_timeout || return 0
        local u=""
        case "$eng" in
          brave) u="$(engine_brave_url "$encoded_q")" ;;
          bing) u="$(engine_bing_url "$encoded_q")" ;;
          ddg) u="$(engine_ddg_url "$encoded_q")" ;;
          yandex) u="$(engine_yandex_url "$encoded_q")" ;;
          ecosia) u="$(engine_ecosia_url "$encoded_q")" ;;
          qwant) u="$(engine_qwant_url "$encoded_q")" ;;
          swisscows) u="$(engine_swisscows_url "$encoded_q")" ;;
          mojeek) u="$(engine_mojeek_url "$encoded_q")" ;;
        esac
        fetch_best "$u" > "$raw_dir/${eng}.txt" || true
      done
    else
      fetch_best "$url" > "$raw_dir/${e}.txt" || true
    fi
  done
}

# ---------------- DNS / Host discovery ----------------
get_nameservers() {
  local domain="$1"
  dig NS "$domain" +short 2>/dev/null | sed 's/\.$//' | awk 'NF' | sort -u || true
}

axfr_try_one_ns() {
  local domain="$1"
  local ns="$2"
  dig AXFR "$domain" @"$ns" +time=5 +tries=1 2>/dev/null || true
}

axfr_attempt() {
  local domain="$1"
  local ns_list_file="$2"
  local out_zone_file="$3"
  : > "$out_zone_file"
  local any_success="no"

  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    log "[*] AXFR: $domain @ $ns (tries: $AXFR_MAX_TRIES)"

    local i=1
    while [[ $i -le $AXFR_MAX_TRIES ]]; do
      local z
      z="$(axfr_try_one_ns "$domain" "$ns")"

      if echo "$z" | grep -Eq '\s+SOA\s+' && [[ "$(echo "$z" | wc -l | tr -d ' ')" -ge 5 ]]; then
        echo "$z" >> "$out_zone_file"
        any_success="yes"
        log "    [+] AXFR SUCCESS em $ns"
        break
      fi

      local sleep_s="${AXFR_BACKOFF[$((i-1))]:-10}"
      log "    [!] AXFR falhou (REFUSED/timeout provável). Backoff ${sleep_s}s"
      sleep "$sleep_s"
      i=$((i+1))
    done
  done < "$ns_list_file"

  [[ "$any_success" == "yes" ]] && return 0
  return 1
}

hosts_from_zonefile() {
  local domain="$1"
  local zonefile="$2"
  awk -v d="$domain" '$1 ~ d"$" { print $1 }' "$zonefile" 2>/dev/null \
    | sed 's/\.$//' | sort -u || true
}

hosts_from_crtsh() {
  local domain="$1"
  local url="https://crt.sh/?q=%25.${domain}&output=json"
  local json
  json="$(curl -sL --max-time 25 -A "$UA" "$url" || true)"
  [[ -z "$json" ]] && return 0

  if have_cmd python3; then
    python3 - <<PY 2>/dev/null || true
import json, sys, re
data = sys.stdin.read()
try:
    arr = json.loads(data)
except Exception:
    sys.exit(0)
out=set()
dom="${domain}".lower()
for o in arr:
    v = o.get("name_value","")
    for line in str(v).splitlines():
        h=line.strip().lower()
        h=h.lstrip("*.")  # remove wildcard
        if h and h.endswith(dom):
            out.add(h)
for h in sorted(out):
    print(h)
PY <<<"$json"
    return 0
  fi

  echo "$json" | grep -Eo "\"name_value\":\"[^\"]+\"" \
    | sed -E 's/^"name_value":"//; s/"$//' \
    | sed 's/\\n/\n/g' \
    | sed -E 's/^\*\.\s*//; s/^\*\.//g' \
    | awk -v d="$domain" 'tolower($0) ~ (tolower(d)"$") { print tolower($0) }' \
    | sort -u || true
}

# ---------------- Resolve + HTTP checks ----------------
resolve_ips() {
  local host="$1"
  local a aaaa
  a="$(dig A "$host" +short 2>/dev/null | head -n1 || true)"
  aaaa="$(dig AAAA "$host" +short 2>/dev/null | head -n1 || true)"
  echo "${a:-},${aaaa:-}"
}

http_status() {
  local url="$1"
  curl -sI --max-time "$HTTP_TIMEOUT" -A "$UA" "$url" \
    | head -n1 | awk '{print $2}' 2>/dev/null || true
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
  if [[ -n "${cl:-}" && "$cl" =~ ^[0-9]+$ && "$cl" -gt "${MAX_BYTES}" ]]; then
    return 1
  fi

  if [[ -n "$ct" ]] && echo "$ct" | grep -Eq \
    "application/pdf|application/msword|application/vnd\.openxmlformats-officedocument|application/vnd\.ms|text/plain|text/csv|application/zip|application/x-7z-compressed|application/x-rar|application/octet-stream|application/xml|text/xml|application/json|text/json|application/gzip|application/x-tar"; then
    echo "$final"; return 0
  fi

  # unknown CT: allow; validate with `file` after download
  [[ -z "$ct" ]] && { echo "$final"; return 0; }
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

  if file -b "$out" | grep -qi "html"; then
    rm -f "$out"; return 1
  fi

  local sz
  sz="$(stat -c%s "$out" 2>/dev/null || echo 0)"
  if [[ "$sz" -gt "${MAX_BYTES}" ]]; then
    rm -f "$out"; return 1
  fi

  echo "$out"
}

# ---------------- Per-file analysis helpers ----------------
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

 FileHound — OSINT File Finder + Host Discovery + Metadata Report
</pre>
EOF
}

top_kv_from_exif() {
  local file_txt="$1"
  grep -E '^(File Name|File Type|MIME Type|File Size|Create Date|Modify Date|PDF Producer|Producer|Creator Tool|Creator|Author|Last Modified By|Company|Manager|Department|Title|Subject|Keywords|Language|Template|Revision Number|Document ID|Instance ID|XMP Toolkit|Generator|Application|Software|Converting Tool|Page Count|Host Name|User Name|Hyperlinks)\s*:' \
    "$file_txt" 2>/dev/null || true
}

strings_interesting() {
  local f="$1"
  local minlen="$2"
  local maxlines="$3"

  # Prefer `strings` if available; otherwise skip
  have_cmd strings || return 0

  # Filter: emails, paths, share, usernames, domains, common secrets keywords
  # Keep it safe and short, avoid dumping tons of content
  strings -n "$minlen" "$f" 2>/dev/null \
    | grep -E -i \
      '([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})|([A-Z]:\\Users\\)|(/home/)|(/Users/)|(\\\\\\\\[^\\ ]+\\\\)|(\bpassword\b|\bpasswd\b|\btoken\b|\bapi[_-]?key\b|\bsecret\b|\busuario\b|\blogin\b)' \
    | head -n "$maxlines" || true
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
  $0 -t empresa.com.br -r report_empresa --max-mb 100 --max-files 150

Opções:
  -t, --target        Domínio alvo (ex: example.com)
  -r, --report        Nome do relatório (sem .html) -> ex: relatorio
  -o, --out           Pasta base de output (opcional)
  -e, --engines       Engines (default: all)
  -f, --filetypes     Extensões (default: lista grande)
  --max-mb            Limite máximo por arquivo (default: 50)
  --max-files         Máximo de downloads válidos (default: 250)
  --recon-timeout     Timeout global de recon (segundos) (default: 1200)
  --req-per-min       Limite de requests por minuto (default: 25)
  --sleep-ms          Intervalo sleep random: --sleep-ms MIN MAX (ms)
  --strings-lines     Linhas de strings úteis por arquivo (default: 20)
  --strings-minlen    Tamanho mínimo do strings (default: 6)
  --no-tutorial       Não mostrar tutorial no início
EOF
}

TARGET=""
REPORT_BASE=""
OUTDIR=""
ENGINES="$DEFAULT_ENGINES"
FILETYPES="$DEFAULT_FILETYPES"
MAX_BYTES="$MAX_BYTES_DEFAULT"
MAX_FILES="$MAX_FILES_DEFAULT"
RECON_TIMEOUT="$RECON_TIMEOUT_DEFAULT"
REQ_PER_MIN="$REQ_PER_MIN_DEFAULT"
SLEEP_MIN_MS="$SLEEP_MIN_MS_DEFAULT"
SLEEP_MAX_MS="$SLEEP_MAX_MS_DEFAULT"
STRINGS_LINES="$STRINGS_LINES_DEFAULT"
STRINGS_MINLEN="$STRINGS_MINLEN_DEFAULT"
SHOW_TUTORIAL="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET="$2"; shift 2 ;;
    -r|--report) REPORT_BASE="$2"; shift 2 ;;
    -o|--out) OUTDIR="$2"; shift 2 ;;
    -e|--engines) ENGINES="$2"; shift 2 ;;
    -f|--filetypes) FILETYPES="$2"; shift 2 ;;
    --max-mb) MAX_BYTES=$(( "$2" * 1024 * 1024 )); shift 2 ;;
    --max-files) MAX_FILES="$2"; shift 2 ;;
    --recon-timeout) RECON_TIMEOUT="$2"; shift 2 ;;
    --req-per-min) REQ_PER_MIN="$2"; shift 2 ;;
    --sleep-ms) SLEEP_MIN_MS="$2"; SLEEP_MAX_MS="$3"; shift 3 ;;
    --strings-lines) STRINGS_LINES="$2"; shift 2 ;;
    --strings-minlen) STRINGS_MINLEN="$2"; shift 2 ;;
    --no-tutorial) SHOW_TUTORIAL="no"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[!] Argumento inválido: $1"; usage; exit 1 ;;
  esac
done

banner_term
[[ "$SHOW_TUTORIAL" == "yes" ]] && tutorial_block

need_cmd curl
need_cmd dig
need_cmd exiftool
need_cmd file
need_cmd sha256sum
need_cmd awk
need_cmd sed
need_cmd sort
need_cmd grep
need_cmd stat
need_cmd readlink

# strings optional
if ! have_cmd strings; then
  log "[i] Dica: instale 'binutils' para habilitar análise de strings (opcional): sudo apt-get install -y binutils"
fi
if ! have_cmd lynx; then
  log "[i] Dica: instale 'lynx' para melhorar coleta quando buscadores bloqueiam HTML: sudo apt-get install -y lynx"
fi

if [[ -z "${TARGET}" ]]; then
  read -rp "Target (ex: example.com ou empresa.com.br): " TARGET
fi
TARGET="$(normalize_domain "$TARGET")"

if [[ -z "${REPORT_BASE}" ]]; then
  read -rp "Nome do relatório (ex: relatorio_empresa): " REPORT_BASE
fi
REPORT_BASE="${REPORT_BASE//[^a-zA-Z0-9._-]/_}"
[[ -z "$REPORT_BASE" ]] && REPORT_BASE="REPORT"
REPORT_NAME="${REPORT_BASE}.html"

if [[ -z "${OUTDIR}" ]]; then
  TS="$(date +%Y%m%d_%H%M%S)"
  OUTDIR="filehound_${TARGET}_${TS}"
fi

mkdir -p "$OUTDIR"/{raw,urls,downloads,metadata,report,data,logs}

ALL_URLS_FILE="$OUTDIR/urls/all_urls.txt"
DOWNLOADED_LIST="$OUTDIR/report/downloaded_files.txt"
REPORT_HTML="$OUTDIR/report/$REPORT_NAME"
DOWN_DIR="$OUTDIR/downloads"
META_DIR="$OUTDIR/metadata"

NS_FILE="$OUTDIR/data/nameservers.txt"
ZONE_FILE="$OUTDIR/data/zone_axfr.txt"
HOSTS_FILE="$OUTDIR/data/hosts.txt"
HOSTS_RESOLVED_CSV="$OUTDIR/data/hosts_resolved.csv"

URLS_BY_HOST_DIR="$OUTDIR/urls/by_host"
mkdir -p "$URLS_BY_HOST_DIR"

LOG_MAIN="$OUTDIR/logs/run.log"
LOG_AXFR="$OUTDIR/logs/axfr.log"
: > "$LOG_MAIN"
: > "$LOG_AXFR"

# redirect stdout+stderr to console + log file
exec > >(tee -a "$LOG_MAIN") 2>&1

echo
echo "==================== EXECUÇÃO AUTOMÁTICA ===================="
echo "Target:            $TARGET"
echo "Engines:           $ENGINES"
echo "Filetypes:         $FILETYPES"
echo "Max size:          $((MAX_BYTES/1024/1024)) MB"
echo "Max files:         $MAX_FILES"
echo "Recon timeout:     $RECON_TIMEOUT s"
echo "Req/min:           $REQ_PER_MIN"
echo "Sleep random:      ${SLEEP_MIN_MS}-${SLEEP_MAX_MS} ms"
echo "Strings per file:  $STRINGS_LINES (minlen: $STRINGS_MINLEN)"
echo "Output dir:        $OUTDIR"
echo "Report file:       report/$REPORT_NAME"
echo "============================================================"
echo

# init files
: > "$ALL_URLS_FILE"
: > "$DOWNLOADED_LIST"
: > "$NS_FILE"
: > "$ZONE_FILE"
: > "$HOSTS_FILE"
: > "$HOSTS_RESOLVED_CSV"

# ---------------- Step 1: Host discovery ----------------
log "[1/6] Descobrindo Nameservers (NS)..."
get_nameservers "$TARGET" | tee "$NS_FILE" >/dev/null
NS_COUNT="$(wc -l < "$NS_FILE" | tr -d ' ')"
log "    -> NS encontrados: $NS_COUNT"

log "[2/6] Tentando AXFR (limitado/backoff)..."
{
  echo "AXFR attempts for $TARGET at $(date)"
  echo "Nameservers:"
  cat "$NS_FILE"
  echo
} >> "$LOG_AXFR"

AXFR_OK="no"
if [[ "$NS_COUNT" -gt 0 ]]; then
  if axfr_attempt "$TARGET" "$NS_FILE" "$ZONE_FILE"; then
    AXFR_OK="yes"
  fi
fi
log "    -> AXFR sucesso? $AXFR_OK"

log "[3/6] Coletando hosts via crt.sh..."
CRT_HOSTS="$OUTDIR/data/hosts_crtsh.txt"
: > "$CRT_HOSTS"
hosts_from_crtsh "$TARGET" | tee "$CRT_HOSTS" >/dev/null || true

log "[3/6] Montando hosts finais..."
{
  echo "$TARGET"
  [[ "$AXFR_OK" == "yes" ]] && hosts_from_zonefile "$TARGET" "$ZONE_FILE"
  cat "$CRT_HOSTS" 2>/dev/null || true
} | awk 'NF' | sed 's/\.$//' | sort -u > "$HOSTS_FILE"

HOSTS_COUNT="$(wc -l < "$HOSTS_FILE" | tr -d ' ')"
log "    -> Hosts únicos: $HOSTS_COUNT"
log "    -> Hosts file:   $HOSTS_FILE"

# ---------------- Step 2: Resolve + HTTP checks ----------------
log "[4/6] Resolvendo IP + checando HTTP/HTTPS..."
echo "host,ipv4,ipv6,http_status,https_status" > "$HOSTS_RESOLVED_CSV"

while IFS= read -r h; do
  [[ -z "$h" ]] && continue
  ips="$(resolve_ips "$h")"
  ipv4="${ips%%,*}"
  ipv6="${ips##*,}"
  hs="$(http_status "http://$h" || true)"
  hss="$(http_status "https://$h" || true)"
  echo "$h,${ipv4:-},${ipv6:-},${hs:-},${hss:-}" >> "$HOSTS_RESOLVED_CSV"
done < "$HOSTS_FILE"

log "    -> CSV: $HOSTS_RESOLVED_CSV"

# ---------------- Step 3: Search URLs (root + each host) ----------------
log "[5/6] Buscando URLs de arquivos (raiz + hosts)..."
IFS=',' read -r -a exts <<< "$FILETYPES"

for ext in "${exts[@]}"; do
  check_recon_timeout || break
  ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ -z "$ext" ]] && continue

  log "    -> ext: .$ext"

  # root domain search
  RAW_ROOT="$OUTDIR/raw/root_${ext}"
  DORK_ROOT="site:${TARGET} ext:${ext}"
  ENC_Q_ROOT="$(printf "%s" "$DORK_ROOT" | urlencode)"
  run_engines "$ENGINES" "$ENC_Q_ROOT" "$RAW_ROOT"

  URLS_EXT_FILE="$OUTDIR/urls/${ext}.txt"
  : > "$URLS_EXT_FILE"

  # Extract from txt dumps (lynx/curl/wget)
  cat "$RAW_ROOT"/*.txt 2>/dev/null | extract_urls_by_ext "$ext" >> "$URLS_EXT_FILE" || true
  sanitize_urls < "$URLS_EXT_FILE" > "$URLS_EXT_FILE.tmp" && mv "$URLS_EXT_FILE.tmp" "$URLS_EXT_FILE"

  # per-host search
  while IFS= read -r h; do
    check_recon_timeout || break
    [[ -z "$h" ]] && continue

    RAW_H="$OUTDIR/raw/${h}_${ext}"
    DORK_H="site:${h} ext:${ext}"
    ENC_Q_H="$(printf "%s" "$DORK_H" | urlencode)"
    run_engines "$ENGINES" "$ENC_Q_H" "$RAW_H"

    HOST_URLS="$URLS_BY_HOST_DIR/${h}.txt"
    touch "$HOST_URLS" 2>/dev/null || true
    cat "$RAW_H"/*.txt 2>/dev/null | extract_urls_by_ext "$ext" >> "$HOST_URLS" || true
    sanitize_urls < "$HOST_URLS" > "$HOST_URLS.tmp" && mv "$HOST_URLS.tmp" "$HOST_URLS"
  done < "$HOSTS_FILE"

  cat "$URLS_EXT_FILE" >> "$ALL_URLS_FILE" || true
done

cat "$URLS_BY_HOST_DIR"/*.txt 2>/dev/null >> "$ALL_URLS_FILE" || true
sanitize_urls < "$ALL_URLS_FILE" > "$ALL_URLS_FILE.tmp" && mv "$ALL_URLS_FILE.tmp" "$ALL_URLS_FILE"

TOTAL_URLS="$(wc -l < "$ALL_URLS_FILE" | tr -d ' ')"
log "    -> URLs únicas: $TOTAL_URLS"
log "    -> URL list:    $ALL_URLS_FILE"

# ---------------- Step 4: Download + metadata ----------------
log "[6/6] Baixando + metadados + análise por arquivo..."
DL_OK=0

URL_ORIGIN_MAP="$OUTDIR/data/url_origin_map.tsv"
: > "$URL_ORIGIN_MAP"

if [[ "$TOTAL_URLS" -gt 0 ]]; then
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    if [[ "$DL_OK" -ge "$MAX_FILES" ]]; then
      log "    [!] MAX_FILES atingido ($MAX_FILES). Parando downloads."
      break
    fi

    if out="$(download_one "$u" "$DOWN_DIR" 2>/dev/null)"; then
      echo "$out" >> "$DOWNLOADED_LIST"
      echo -e "$(basename "$out")\t$u" >> "$URL_ORIGIN_MAP"
      DL_OK=$((DL_OK+1))
      log "    [+] OK ($DL_OK): $(basename "$out")"

      bn="$(basename "$out")"
      safe="${bn//[^a-zA-Z0-9._-]/_}"
      exiftool "$out" > "$META_DIR/${safe}.exif.txt" 2>/dev/null || true
      exiftool -json "$out" > "$META_DIR/${safe}.exif.json" 2>/dev/null || true
    else
      log "    [-] SKIP: $u"
    fi

    throttle_req
  done < "$ALL_URLS_FILE"
  sort -u "$DOWNLOADED_LIST" -o "$DOWNLOADED_LIST"
fi

DL_COUNT="$(wc -l < "$DOWNLOADED_LIST" 2>/dev/null | tr -d ' ' || echo 0)"
log "    -> Downloads válidos: $DL_COUNT"
log "    -> Downloads list:    $DOWNLOADED_LIST"

# ---------------- HTML report ----------------
log "[*] Gerando relatório HTML (com análise por arquivo)..."
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
    .wrap { max-width: 1160px; margin: 0 auto; padding: 24px; }
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
    details { border: 1px solid #1f2a37; border-radius: 12px; padding: 10px 12px; margin-top: 10px; background:#0b1220; }
    summary { cursor: pointer; font-weight: 700; }
    .tiny { font-size: 12px; opacity: .85; }
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
        <div class="pill"><b>Hosts</b> <span class="muted">${HOSTS_COUNT}</span></div>
        <div class="pill"><b>URLs</b> <span class="muted">${TOTAL_URLS}</span></div>
        <div class="pill"><b>Downloads</b> <span class="muted">${DL_COUNT}</span></div>
        <div class="pill"><b>Max</b> <span class="muted">$((MAX_BYTES/1024/1024))MB</span></div>
        <div class="pill"><b>Req/min</b> <span class="muted">${REQ_PER_MIN}</span></div>
        <div class="pill"><b>Sleep</b> <span class="muted">${SLEEP_MIN_MS}-${SLEEP_MAX_MS}ms</span></div>
      </div>
      <div class="hr"></div>
      <div class="footer">
        <span><b>Creator:</b> ${CREATOR_NAME}</span>
        <span>•</span>
        <span><b>GitHub:</b> <a href="https://github.com/${GITHUB_USER}" target="_blank" rel="noreferrer">github.com/${GITHUB_USER}</a></span>
        <span>•</span>
        <span><b>LinkedIn:</b> <a href="https://www.linkedin.com/in/${LINKEDIN_USER}/" target="_blank" rel="noreferrer">linkedin.com/in/${LINKEDIN_USER}</a></span>
      </div>
      <div class="hr"></div>
      <div class="tiny muted">
        Arquivos gerados nesta execução: <code>data/hosts.txt</code>, <code>urls/all_urls.txt</code>, <code>report/downloaded_files.txt</code>, <code>metadata/*.exif.*</code>, <code>logs/run.log</code>.
      </div>
    </div>

    <div class="card">
      <h2>1) Host Discovery</h2>
      <p class="muted">Fonte: NS + tentativa AXFR (limitada) + crt.sh. Lista: <code>data/hosts.txt</code></p>
      <p class="muted">AXFR success: <code>${AXFR_OK}</code> (log em <code>logs/axfr.log</code>)</p>
      <table>
        <thead><tr><th>#</th><th>Host</th><th>IPv4</th><th>IPv6</th><th>HTTP</th><th>HTTPS</th></tr></thead>
        <tbody>
EOF

# hosts table
n=0
tail -n +2 "$HOSTS_RESOLVED_CSV" 2>/dev/null | while IFS=',' read -r host ipv4 ipv6 hs hss; do
  [[ -z "$host" ]] && continue
  n=$((n+1))
  he="$(printf "%s" "$host" | html_escape)"
  printf '          <tr><td>%d</td><td><a href="https://%s" target="_blank" rel="noreferrer">%s</a></td><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td></tr>\n' \
    "$n" "$he" "$he" "$(printf "%s" "${ipv4:-}" | html_escape)" "$(printf "%s" "${ipv6:-}" | html_escape)" "$(printf "%s" "${hs:-}" | html_escape)" "$(printf "%s" "${hss:-}" | html_escape)"
done

cat <<EOF
        </tbody>
      </table>
    </div>

    <div class="card">
      <h2>2) URLs Encontradas</h2>
      <p class="muted">Lista completa: <code>urls/all_urls.txt</code></p>
      <table>
        <thead><tr><th>#</th><th>URL</th></tr></thead>
        <tbody>
EOF

# urls table (limit display if huge)
URL_SHOW_LIMIT=800
i=0
while IFS= read -r u; do
  [[ -z "$u" ]] && continue
  i=$((i+1))
  if (( i > URL_SHOW_LIMIT )); then
    break
  fi
  ue="$(printf "%s" "$u" | html_escape)"
  printf '          <tr><td>%d</td><td><a href="%s" target="_blank" rel="noreferrer">%s</a></td></tr>\n' "$i" "$ue" "$ue"
done < "$ALL_URLS_FILE"

if (( TOTAL_URLS > URL_SHOW_LIMIT )); then
  cat <<EOF
          <tr><td colspan="2" class="muted">Mostrando apenas as primeiras ${URL_SHOW_LIMIT} URLs no HTML. Veja tudo em <code>urls/all_urls.txt</code>.</td></tr>
EOF
fi

cat <<EOF
        </tbody>
      </table>
    </div>
EOF

# Download + per-file analysis
if [[ -s "$DOWNLOADED_LIST" ]]; then
  cat <<EOF
    <div class="card">
      <h2>3) Arquivos Baixados</h2>
      <p class="muted">Arquivos: <code>report/downloaded_files.txt</code> • Pasta: <code>downloads/</code></p>
      <table>
        <thead><tr><th>#</th><th>Arquivo</th><th>SHA256</th><th>Tamanho</th><th>Tipo (file)</th><th>URL origem</th></tr></thead>
        <tbody>
EOF

  n=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n=$((n+1))
    bn="$(basename "$f")"
    sha="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    sz="$(stat -c%s "$f" 2>/dev/null || echo "?")"
    ft="$(file -b "$f" 2>/dev/null | head -c 90)"
    origin="$(awk -F'\t' -v b="$bn" '$1==b{print $2; exit}' "$URL_ORIGIN_MAP" 2>/dev/null || true)"

    bne="$(printf "%s" "$bn" | html_escape)"
    fte="$(printf "%s" "$ft" | html_escape)"
    oe="$(printf "%s" "${origin:-}" | html_escape)"

    if [[ -n "${origin:-}" ]]; then
      printf '          <tr><td>%d</td><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td><a href="%s" target="_blank" rel="noreferrer">link</a></td></tr>\n' \
        "$n" "$bne" "$sha" "$sz" "$fte" "$oe"
    else
      printf '          <tr><td>%d</td><td><code>%s</code></td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td class="muted">—</td></tr>\n' \
        "$n" "$bne" "$sha" "$sz" "$fte"
    fi
  done < "$DOWNLOADED_LIST"

  cat <<EOF
        </tbody>
      </table>
    </div>

    <div class="card">
      <h2>4) Metadados + Análise por Arquivo</h2>
      <p class="muted">Metadados via <code>exiftool</code> + strings úteis (limitadas) para evitar dumping excessivo.</p>
EOF

  # Top software/tools
  cat <<EOF
      <h3>4.1) Top softwares / ferramentas (aprox.)</h3>
      <pre>
EOF
  count_software_from_txts "$META_DIR" | html_escape
  cat <<EOF
      </pre>
EOF

  # Per file detailed analysis (collapsible)
  cat <<EOF
      <h3>4.2) Arquivo por arquivo</h3>
EOF

  idx=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    idx=$((idx+1))

    bn="$(basename "$f")"
    safe="${bn//[^a-zA-Z0-9._-]/_}"
    txt="$META_DIR/${safe}.exif.txt"

    sha="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
    sz="$(stat -c%s "$f" 2>/dev/null || echo "?")"
    ft="$(file -b "$f" 2>/dev/null | head -c 110)"
    origin="$(awk -F'\t' -v b="$bn" '$1==b{print $2; exit}' "$URL_ORIGIN_MAP" 2>/dev/null || true)"

    bne="$(printf "%s" "$bn" | html_escape)"
    fte="$(printf "%s" "$ft" | html_escape)"
    oe="$(printf "%s" "${origin:-}" | html_escape)"

    cat <<EOF
      <details>
        <summary>${idx}) ${bne} <span class="muted">(${sz} bytes)</span></summary>
        <div class="tiny muted" style="margin-top:8px;">
          <b>SHA256:</b> <code>${sha}</code><br/>
          <b>Tipo:</b> ${fte}<br/>
          <b>Origem:</b> $( [[ -n "${origin:-}" ]] && echo "<a href=\"${oe}\" target=\"_blank\" rel=\"noreferrer\">${oe}</a>" || echo "<span class=\"muted\">—</span>" )
        </div>
        <div class="hr"></div>
        <h3>Metadados (highlights)</h3>
        <pre>
EOF
    if [[ -f "$txt" ]]; then
      top_kv_from_exif "$txt" | html_escape
    else
      echo "Sem exiftool output (arquivo pode não suportar metadados)." | html_escape
    fi
    cat <<EOF
        </pre>

        <h3>Strings úteis (limitadas)</h3>
        <pre>
EOF
    strings_interesting "$f" "$STRINGS_MINLEN" "$STRINGS_LINES" | html_escape
    cat <<EOF
        </pre>
      </details>
EOF
  done < "$DOWNLOADED_LIST"

  cat <<EOF
    </div>
EOF
else
  cat <<EOF
    <div class="card">
      <h2>3) Downloads / Metadados</h2>
      <p class="muted">Nenhum arquivo foi baixado. Possíveis causas: bloqueio, links não-diretos, consent pages, rate-limit.</p>
      <p class="muted">Dicas:</p>
      <ul>
        <li>Instale <code>lynx</code> para melhorar coleta: <code>sudo apt-get install -y lynx</code></li>
        <li>Reduza requests: <code>--req-per-min 10</code> e aumente sleep: <code>--sleep-ms 2000 6000</code></li>
      </ul>
    </div>
EOF
fi

cat <<EOF
    <div class="card">
      <h2>5) Próximos passos (OSINT)</h2>
      <ul>
        <li>Priorize documentos por <b>Author/Company</b> e <b>CreatorTool/Producer</b> incomuns.</li>
        <li>Procure vazamentos de paths/usuários: <code>C:\\Users\\</code>, <code>/home/</code>, <code>\\\\server\\share</code>.</li>
        <li>Correlacione achados com OSINT apenas com autorização.</li>
      </ul>
      <div class="hr"></div>
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
echo "[✓] Concluído!"
echo "    - Hosts:        $HOSTS_FILE"
echo "    - URLs:         $ALL_URLS_FILE"
echo "    - Downloads:    $DOWN_DIR"
echo "    - Metadados:    $META_DIR"
echo "    - HTML Report:  $REPORT_HTML"
echo
echo "[LINK] file://$ABS_REPORT"
echo
echo "[i] Abrir no navegador:"
echo "    xdg-open \"$ABS_REPORT\""
echo
echo "[i] Log completo:"
echo "    $LOG_MAIN"
