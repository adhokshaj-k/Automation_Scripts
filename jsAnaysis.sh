#!/usr/bin/env bash
# jsrecon.sh - find, download and analyze JS files from a list of subdomains
# usage: ./jsrecon.sh -l subdomains.txt [options]      (./jsrecon.sh -h for all options)
# Only run against targets you are authorized to test.

# ---------- defaults (change them with the flags) ----------
RATE=10; THREADS=5; JOBS=5; TIMEOUT=3600
HEADER=""; UA=""; LIST=""; NAME=""; ARCHIVE=0; FORCE=0; VERIFY=0
JSRE='\.m?js([?#].*)?$'
NOTJS='\.(m?js|css|png|jpe?g|gif|svg|woff2?|ttf|ico|map|pdf|zip)([?#].*)?$'

usage() { cat <<EOF
usage: $0 -l subdomains.txt [options]
  -l FILE    subdomain list (required)
  -n NAME    folder name under jsAnalysis/ (default: shortest host in the list)
  -r N       max requests/sec sent to the target: httpx, katana, downloads (default $RATE)
  -t N       concurrency for httpx, katana, subjs                          (default $THREADS)
  -j N       parallel JS downloads                                         (default $JOBS)
  -H "K: V"  custom header sent to the target
  -u UA      custom user agent
  -a         also fetch old Wayback versions of JS files (slow)
  -f         force: redo stages that already have output
  -V         let trufflehog verify found keys with their providers (network)
  -T SEC     max seconds per external tool                                 (default $TIMEOUT)
EOF
exit 1; }

while getopts "l:n:r:t:j:H:u:afVT:h" o; do
  case $o in
    l) LIST=$OPTARG ;;  n) NAME=$OPTARG ;;  r) RATE=$OPTARG ;;    t) THREADS=$OPTARG ;;
    j) JOBS=$OPTARG ;;  H) HEADER=$OPTARG ;; u) UA=$OPTARG ;;     a) ARCHIVE=1 ;;
    f) FORCE=1 ;;       V) VERIFY=1 ;;       T) TIMEOUT=$OPTARG ;; *) usage ;;
  esac
done
[ -s "$LIST" ] || usage
for v in RATE THREADS JOBS TIMEOUT; do
  [[ ${!v} =~ ^[1-9][0-9]*$ ]] || { echo "$v must be a whole number >= 1"; exit 1; }
done
# every request we control is spaced so the total never exceeds RATE per second
DELAY=$(awk -v j="$JOBS" -v r="$RATE" 'BEGIN{printf "%.3f", j/r}')   # per download worker
MAPDELAY=$(awk -v r="$RATE" 'BEGIN{printf "%.3f", 1/r}')              # source-map fetches (1 at a time)

# ---------- setup ----------
IN=$(realpath "$LIST")
clean() { tr -d '\r' | sed -E 's|^[a-zA-Z]+://||; s|[/:?#].*||; s|^\*\.||; s|\.$||' | tr 'A-Z' 'a-z' \
          | grep -E '^[a-z0-9][a-z0-9.-]*$' | sort -u; }
NAME=${NAME:-$(clean < "$IN" | awk '{print length, $0}' | sort -n | head -1 | cut -d' ' -f2)}
[ -n "$NAME" ] || { echo "no valid hostnames in $LIST"; exit 1; }
WORK="$PWD/jsAnalysis/$NAME"
mkdir -p "$WORK"/{raw,js,maps,src,analysis,tmp} && cd "$WORK" || exit 1
clean < "$IN" > raw/subdomains.txt
trap 'rm -rf tmp/*' EXIT

# ---------- helpers ----------
log()  { echo "$(date +%T) $*" | tee -a run.log >&2; }              # stderr: never mixes into tool output
have() { command -v "$1" >/dev/null || { log "WARN: $1 not installed, skipping it"; return 1; }; }
run()  { timeout "$TIMEOUT" "$@" 2>>tools.err; local rc=$?
         [ $rc = 124 ] && log "WARN: $1 hit the ${TIMEOUT}s limit (partial output kept, raise -T)"; return $rc; }
cnt()  { [ -f "$1" ] && wc -l < "$1" || echo 0; }
skip() { [ -s "$1" ] && [ "$FORCE" != 1 ] && { log "skip: $1 exists (-f to redo)"; return 0; }; return 1; }

# add_flag ARRAY TOOL FLAG [VALUE]: append the flag only if the tool's -h lists it (1 or 2 dashes)
add_flag() {
  local -n arr=$1; local tool=$2 flag=$3; shift 3
  command -v "$tool" >/dev/null || return
  if "$tool" -h </dev/null 2>&1 | grep -qE -- "(^|[[:space:],])-{1,2}${flag#-}([[:space:],=]|\$)"; then arr+=("$flag" "$@")
  else log "WARN: $(basename "$tool") has no $flag option, skipped"; fi
}

# scope = the URL's host must be listed in subdomains.txt
scope_in()  { awk 'NR==FNR{h[$1]=1;next}{u=$0;sub(/^[a-zA-Z]+:\/\//,"",u);sub(/[\/:?#].*/,"",u);if(tolower(u) in h)print}' raw/subdomains.txt -; }
scope_out() { awk 'NR==FNR{h[$1]=1;next}{u=$0;sub(/^[a-zA-Z]+:\/\//,"",u);sub(/[\/:?#].*/,"",u);if(!(tolower(u) in h))print}' raw/subdomains.txt -; }

# fetch URL OUTFILE -> prints the HTTP code (sends your header/UA, never retries)
fetch() {
  local h=(); [ -n "$HEADER" ] && h+=(-H "$HEADER"); [ -n "$UA" ] && h+=(-A "$UA")
  curl -skL --compressed -m 20 "${h[@]}" -w '%{http_code}' "$1" -o "$2"
}
# store FILE LABEL: name the file by its content hash, remember which URL it came from
store() {
  local h; h=$(sha256sum "$1" | cut -d' ' -f1)
  if [ -e "js/$h.js" ]; then rm -f "$1"; else mv "$1" "js/$h.js"; fi
  echo "$h $2" >> hash_map.txt
}
dl() {
  local f code; f=$(mktemp -p tmp) || return 0
  code=$(fetch "$1" "$f")
  if [ "$code" = 200 ] && [ -s "$f" ] && ! head -c 50 "$f" | grep -qiE '<!doctype|<html'; then
    store "$f" "$1"
  else
    [ "$code" = 200 ] && code=soft404                     # HTML served on a .js URL = fake 404, rejected
    rm -f "$f"; echo "$code $1" >> raw/download_failed.txt
  fi
  sleep "$DELAY"
}
dl_archive() {                                            # old versions of a JS file from Wayback
  local ts f
  curl -sG "https://web.archive.org/cdx/search/cdx" --data-urlencode "url=$1" -d output=txt \
       -d fl=timestamp -d 'filter=statuscode:200' -d collapse=digest -d limit=5 | grep -E '^[0-9]{14}$' |
  while read -r ts; do
    f=$(mktemp -p tmp)
    curl -skLf -m 30 "https://web.archive.org/web/${ts}id_/$1" -o "$f" && [ -s "$f" ] && store "$f" "$1@$ts" || rm -f "$f"
    sleep 2
  done
}
export HEADER UA DELAY; export -f fetch store dl dl_archive

# ---------- per-tool options (only flags the installed version supports) ----------
SJ=();  add_flag SJ subjs -c "$THREADS";  [ -n "$UA" ] && add_flag SJ subjs -ua "$UA"   # subjs cannot send headers
GJ=();  add_flag GJ getJS -complete
[ -n "$HEADER" ] && add_flag GJ getJS -header "$HEADER"
[ -n "$UA" ]     && add_flag GJ getJS -header "User-Agent: $UA"
GAU=(); add_flag GAU gau --threads 2                      # gau only talks to archives, not your target
KT=(-silent -jc -d 2); add_flag KT katana -rl "$RATE"; add_flag KT katana -c "$THREADS"
[ -n "$HEADER" ] && add_flag KT katana -H "$HEADER"
[ -n "$UA" ]     && add_flag KT katana -H "User-Agent: $UA"
TH=(--json --no-update); [ "$VERIFY" = 1 ] || TH+=(--no-verification)

log "folder=$NAME rate=$RATE/s threads=$THREADS jobs=$JOBS header=${HEADER:-none} ua=${UA:-default}"

# ---------- 0. which hosts are alive? ----------
echo "== 0 probe =="
HTTPX=""
for c in $(type -aP httpx-toolkit httpx 2>/dev/null) "$HOME/go/bin/httpx"; do   # skip the python "httpx"
  [ -x "$c" ] && "$c" -version 2>&1 | grep -qiE 'current version|projectdiscovery' && { HTTPX=$c; break; }
done
if ! skip raw/alive.txt; then
  if [ -n "$HTTPX" ]; then
    HX=(-l raw/subdomains.txt -silent -timeout 10)
    add_flag HX "$HTTPX" -t "$THREADS"; add_flag HX "$HTTPX" -rl "$RATE"
    [ -n "$HEADER" ] && add_flag HX "$HTTPX" -H "$HEADER"
    [ -n "$UA" ]     && add_flag HX "$HTTPX" -H "User-Agent: $UA"
    run "$HTTPX" "${HX[@]}" | sort -u > raw/alive.txt
  else
    log "WARN: ProjectDiscovery httpx not found, assuming every host is live"
    sed 's|^|https://|' raw/subdomains.txt > raw/alive.txt
  fi
fi
[ -s raw/alive.txt ] || { log "no live hosts, stopping"; exit 1; }
log "live: $(wc -l < raw/alive.txt) of $(wc -l < raw/subdomains.txt) hosts"

# ---------- 1. JS from live hosts ----------
echo "== 1 live JS =="
if ! skip raw/live_js.txt; then
  have subjs  && run subjs "${SJ[@]}"  < raw/alive.txt > raw/live_subjs.txt
  have getJS  && run getJS "${GJ[@]}"  < raw/alive.txt > raw/live_getjs.txt
  have katana && run katana "${KT[@]}" -list raw/alive.txt | grep -Ei "$JSRE" > raw/live_katana.txt
  cat raw/live_subjs.txt raw/live_getjs.txt raw/live_katana.txt 2>/dev/null | sort -u > raw/live_js.txt
fi

# ---------- 2. JS from archives ----------
echo "== 2 archive JS =="
if ! skip raw/archive_js.txt; then
  { have gau && run gau "${GAU[@]}" < raw/subdomains.txt; have waybackurls && run waybackurls < raw/subdomains.txt; } \
    | sort -u > raw/archive_all.txt
  grep -Ei "$JSRE" raw/archive_all.txt > raw/archive_js.txt
  # subjs reads HTML pages, so give it archived pages (not .js files)
  have subjs && grep -Eiv "$NOTJS" raw/archive_all.txt | scope_in | head -n 1000 \
    | run subjs "${SJ[@]}" > raw/archive_subjs.txt
fi

# ---------- 3. merge + scope ----------
echo "== 3 merge + scope =="
cat raw/live_js.txt raw/archive_js.txt raw/archive_subjs.txt 2>/dev/null | grep -E '^https?://' | sort -u > all_js.txt
scope_in  < all_js.txt > in_scope.txt
scope_out < all_js.txt > out_of_scope.txt                 # first-party CDN bundles may hide here
log "JS URLs in scope: $(wc -l < in_scope.txt)   out of scope: $(wc -l < out_of_scope.txt)"
[ -s in_scope.txt ] || { log "no in-scope JS found, stopping (check out_of_scope.txt)"; exit 1; }

# ---------- 4. download ----------
echo "== 4 download =="
touch hash_map.txt; : > raw/download_failed.txt
if [ "$FORCE" = 1 ]; then cp in_scope.txt tmp/todo.txt                    # else: only URLs not fetched before
else grep -vFxf <(cut -d' ' -f2- hash_map.txt) in_scope.txt > tmp/todo.txt; fi
shuf tmp/todo.txt | tr '\n' '\0' | xargs -r0 -P "$JOBS" -n 1 bash -c 'dl "$1"' _   # shuffled = spread across hosts
if [ "$ARCHIVE" = 1 ]; then
  scope_in < raw/archive_js.txt | tr '\n' '\0' | xargs -r0 -P 2 -n 1 bash -c 'dl_archive "$1"' _
fi
log "unique JS files: $(find js -type f | wc -l)   failed downloads: $(wc -l < raw/download_failed.txt) (raw/download_failed.txt)"

# ---------- 5. source maps ----------
echo "== 5 source maps =="
if have jq; then
  for f in js/*.js; do
    [ -e "$f" ] || break
    h=$(basename "$f" .js); [ -e "maps/$h.map" ] || [ -e "maps/$h.none" ] && continue
    url=$(grep -m1 "^$h " hash_map.txt | cut -d' ' -f2-)
    [[ -z $url || $url =~ @[0-9]{14}$ ]] && continue                      # skip archive snapshots
    m=$(tail -c 600 "$f" | grep -o 'sourceMappingURL=[^ *]*' | tail -1 | cut -d= -f2-)
    case "$m" in
      data:*) continue ;;
      http*)  mu=$m ;;
      /*)     mu="$(grep -oE '^https?://[^/]+' <<<"$url")$m" ;;
      "")     mu="${url%%[?#]*}.map" ;;                                   # guess even without the comment
      *)      mu="${url%%[?#]*}"; mu="${mu%/*}/$m" ;;
    esac
    code=$(fetch "$mu" "maps/$h.map"); sleep "$MAPDELAY"
    if [ "$code" != 200 ] || ! jq -e '.sources' "maps/$h.map" >/dev/null 2>&1; then rm -f "maps/$h.map"; touch "maps/$h.none"; continue; fi
    mkdir -p "src/$h"
    jq -r '. as $m | range(0; ($m.sources|length)) as $i
           | select($m.sourcesContent[$i] != null and ($m.sources[$i]|test("node_modules")|not))
           | "\($i)\t\($m.sources[$i]|gsub("[^A-Za-z0-9._-]";"_")|.[-100:])\t\($m.sourcesContent[$i]|@base64)"' \
        "maps/$h.map" | while IFS=$'\t' read -r i name b64; do echo "$b64" | base64 -d > "src/$h/${i}_$name"; done
  done
fi
log "source maps recovered: $(find maps -name '*.map' | wc -l)"

# ---------- 6. analysis (local files only, no requests to the target) ----------
echo "== 6 analysis =="
if have jsluice; then
  find js src -type f -print0 | run xargs -r0 -n 200 jsluice urls    > analysis/jsluice_urls.jsonl
  find js src -type f -print0 | run xargs -r0 -n 200 jsluice secrets > analysis/jsluice_secrets.jsonl
  have jq && jq -r '.url? // empty' analysis/jsluice_urls.jsonl | sort | uniq -c | sort -rn > analysis/endpoints_ranked.txt
fi
have trufflehog && run trufflehog filesystem js src "${TH[@]}" > analysis/trufflehog.jsonl
grep -rHoE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|dangerouslySetInnerHTML|postMessage\(|eval\(|new Function\(' js src \
  | sort | uniq -c | sort -rn > analysis/sinks.txt

echo "== summary =="
{ echo "hosts alive:       $(wc -l < raw/alive.txt) / $(wc -l < raw/subdomains.txt)"
  echo "JS urls in scope:  $(wc -l < in_scope.txt)   (out of scope: $(wc -l < out_of_scope.txt))"
  echo "unique JS files:   $(find js -type f | wc -l)   failed: $(wc -l < raw/download_failed.txt)"
  echo "source maps:       $(find maps -name '*.map' | wc -l)"
  echo "endpoints:         $(cnt analysis/endpoints_ranked.txt)"
  echo "jsluice secrets:   $(cnt analysis/jsluice_secrets.jsonl)"
  th=$(grep -c '"DetectorName"' analysis/trufflehog.jsonl 2>/dev/null); echo "trufflehog hits:   ${th:-0}"
  echo "results in: $WORK/analysis/   (hash -> URL: grep HASH hash_map.txt)"; } | tee analysis/SUMMARY.txt
