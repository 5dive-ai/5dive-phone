#!/usr/bin/env bash
# phone plugin harness (DIVE-9064): `5dive phone` against a fake adb.
# What it pins: the screen reads as refs, a Send/Pay/Delete tap is checked against
# the owner's policy BEFORE any step runs, a grant is bound to the exact steps and
# spent once, the policy file counts only when the granting uid owns it, and a
# phone that stopped answering says what to ask the owner, and text in any
# language is pasted through lib/type.dex (DIVE-9242), and a routine is kept by
# control name, approved on save, replayed with no model, and stopped on a wrong
# screen (DIVE-9347).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHONE="$ROOT/phone/bin/phone"
UI="$ROOT/phone/lib/ui.py"
FIX="$ROOT/tests/fixtures/phone"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2" | head -20; return 0; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

export FIVEDIVE_PHONE_ADB="$FIX/fake-adb" FAKE_ADB_UI="$FIX/chat.xml" FAKE_ADB_LOG="$T/input.log" FAKE_ADB_CALLS="$T/calls.log"
export FIVEDIVE_PHONE_HOME="$T/home" FIVEDIVE_PHONE_APPROVAL_DIR="$T/approvals" FIVEDIVE_PHONE_APPROVAL_POLICY="$T/policy.json"
export FIVEDIVE_PHONE_GRANT_UID="$(id -u)" FIVEDIVE_PHONE_STEP_GAP=0 FIVEDIVE_PHONE_OPEN_WAIT=0 FIVEDIVE_PHONE_TCPIP_WAIT=0
# The port search after a restart really scans: keep it to a few ports and a short wait.
export FIVEDIVE_PHONE_PORTS=40000-40010 FIVEDIVE_PHONE_SCAN_WAIT=0.3
# No `5dive` on PATH: the owner-ask relay is not reachable here, so the fallback text shows.
mkdir -p "$T/bin"; for b in bash jq python3 sha256sum timeout stat head od tr cut sed grep awk sort tail cat mkdir chmod mv rm date sleep seq id getent mktemp basename dirname printf env ls wc base64 cat kill; do
  p="$(command -v "$b")" && ln -sf "$p" "$T/bin/$b"; done
export PATH="$T/bin"
policy() { printf '%s\n' "$1" > "$T/policy.json"; }
reset_log() { : > "$T/input.log"; }

# ---- classification ----
for c in "send:Send" "send:com.app:id/btn_send" "send:sendButton" "send:Отправить" "pay:Buy now" "pay:Place order" \
         "delete:Delete chat" "publish:Post" ":Posts" ":Reply" ":Share" ":Allow" \
         "pay:Send money" "pay:Send payment" "pay:Send \$50" "pay:Send 12,50 €" "pay:Request money" "pay:Withdraw" \
         "send:Send message" \
         "pay:Geld senden" "pay:Geld überweisen" "pay:Überweisen" "pay:Überweisung" "pay:Отправить деньги" "pay:Перевод" \
         "pay:Enviar dinero" "pay:Transferir" "pay:Transferencia" "pay:Envoyer de l'argent" "pay:Envoyer de l’argent" "pay:Virement" \
         "pay:Send 50 USD" "pay:Send USD 50" "pay:Send 12,50 eur" "pay:Send 50 RUB" "pay:Отправить 500 ₽" \
         "send:Send 2 photos" "send:Senden" "send:Enviar"; do
  want="${c%%:*}" label="${c#*:}"
  got="$(python3 "$UI" classify "$label")"
  check "classify \"$label\" -> ${want:-nothing}" [ "$got" == "$want" ]
done

# ---- connect ----
out="$("$PHONE" connect 192.0.2.7:41235 --pair=192.0.2.7:37011 --code=123456 2>&1)"; rc=$?
check "connect pairs, then pins the fixed port 5555" [ $rc -eq 0 -a "$(cat "$T/home/device")" == "192.0.2.7:5555" ]
check "connect names the phone" grep -q 'connected: Pixel Test, Android 14' <<<"$out"
out="$("$PHONE" connect 192.0.2.7:41235 --pair=192.0.2.7:37011 --code=999999 2>&1)"; rc=$?
check "a wrong pairing code fails and asks for fresh ones" bash -c '[ "$1" -ne 0 ] && grep -q fresh <<<"$2"' _ "$rc" "$out"
out="$(FAKE_ADB_STATE=offline "$PHONE" snapshot 2>&1)"; rc=$?
check "a phone that stopped answering exits 69" [ $rc -eq 69 ]
check "  and says what to ask the owner (Wireless debugging, new port)" grep -q 'Wireless debugging' <<<"$out"
out="$(FAKE_ADB_STATE=unauthorized "$PHONE" snapshot 2>&1)"; rc=$?
check "an unallowed server asks the owner to tap Allow" grep -q 'tap Allow' <<<"$out"

# ---- after a restart the new port is found, nobody reads it off the screen (DIVE-9242) ----
# A real listener on 127.0.0.1 stands in for the phone's Wireless debugging port.
python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8); print(s.getsockname()[1], flush=True); time.sleep(120)' > "$T/lport" &
LPID=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/lport" ]] && break; sleep 0.2; done
LP="$(cat "$T/lport")"; RANGE="$((LP - 20))-$((LP + 20))"
out="$(python3 "$ROOT/phone/lib/ports.py" 127.0.0.1 "$RANGE")"; rc=$?
check "ports.py finds the open port (exit 0)" bash -c '[ "$1" -eq 0 ] && grep -qx "$2" <<<"$3"' _ "$rc" "$LP" "$out"
out="$(FIVEDIVE_PHONE_SCAN_WAIT=0.3 python3 "$ROOT/phone/lib/ports.py" 192.0.2.1 40000-40010)"; rc=$?
check "ports.py says a host that never answers is silent (exit 3)" [ $rc -eq 3 ]
echo 127.0.0.1:5555 > "$T/home/device"; : > "$T/listen"
out="$(FAKE_ADB_LISTEN="$LP" FAKE_ADB_LISTEN_FILE="$T/listen" FIVEDIVE_PHONE_PORTS="$RANGE" "$PHONE" snapshot 2>&1)"; rc=$?
check "restarted phone, Wireless debugging back on: the command goes ahead (exit 0)" [ $rc -eq 0 ]
check "  it says it found the phone again" grep -q 'found it again at 127.0.0.1:5555' <<<"$out"
check "  connected on the found port, then pinned 5555 again" bash -c 'grep -qx "connect 127.0.0.1:$2" "$1" && grep -qx "tcpip 5555" "$1" && [ "$(cat "$3")" == 127.0.0.1:5555 ]' _ "$T/calls.log" "$LP" "$T/home/device"
: > "$T/listen"
out="$(FAKE_ADB_LISTEN=1 FAKE_ADB_LISTEN_FILE="$T/listen" FIVEDIVE_PHONE_PORTS="$RANGE" "$PHONE" snapshot 2>&1)"; rc=$?
check "restarted phone, Wireless debugging still off: exit 69" [ $rc -eq 69 ]
check "  asks the owner only to turn it on, no port to send" bash -c 'grep -q "turn it on, then tell me" <<<"$1" && grep -q "found on its own" <<<"$1" && ! grep -q "tell me the port" <<<"$1"' _ "$out"
out="$(FAKE_ADB_LISTEN="$LP" FAKE_ADB_LISTEN_FILE="$T/listen" FIVEDIVE_PHONE_PORTS="$RANGE" "$PHONE" connect 127.0.0.1 2>&1)"; rc=$?
check "connect <ip> with no port finds it and pins 5555" bash -c '[ "$1" -eq 0 ] && grep -q "at 127.0.0.1:5555" <<<"$2"' _ "$rc" "$out"
kill "$LPID" 2>/dev/null
echo 192.0.2.7:5555 > "$T/home/device"
out="$(FAKE_ADB_STATE=offline "$PHONE" snapshot 2>&1)"; rc=$?
check "a phone that does not answer at all: exit 69, is it on and on Tailscale" bash -c '[ "$1" -eq 69 ] && grep -q "does not answer at all" <<<"$2"' _ "$rc" "$out"

# ---- snapshot ----
snap="$("$PHONE" snapshot)"
check "snapshot names the app" grep -q '^app: com.example.chat' <<<"$snap"
check "the Send button is a ref flagged send" grep -qE '^\[e[0-9]+\] button "Send"  ⚠ send$' <<<"$snap"
check "an unlabelled button reads its id: delete chat, flagged delete" grep -qE 'button "delete chat"  ⚠ delete' <<<"$snap"
check "the text box shows its name and what is in it" grep -qE 'textbox "entry" = "Message"' <<<"$snap"
check "a row borrowing \"send you notifications\" is NOT flagged" bash -c '! grep -E "notifications.*⚠" <<<"$1"' _ "$snap"
check "a Posts tab is not a post" bash -c '! grep -E "Posts.*⚠" <<<"$1"' _ "$snap"
send_full="$(grep -oE '^\[e[0-9]+\] button "Send"' <<<"$snap" | grep -oE 'e[0-9]+')"
snap_i="$("$PHONE" snapshot --interactive)"
send_i="$(grep -oE '^\[e[0-9]+\] button "Send"' <<<"$snap_i" | grep -oE 'e[0-9]+')"
check "--interactive hides text but keeps the same refs" [ -n "$send_full" -a "$send_full" == "$send_i" ]
check "--interactive hides plain text" bash -c '! grep -q "free for lunch" <<<"$1"' _ "$snap_i"
entry="$(grep -oE '^\[e[0-9]+\] textbox' <<<"$snap" | grep -oE 'e[0-9]+')"

STEPS="[{\"op\":\"type\",\"ref\":\"$entry\",\"text\":\"hello Ada\"},{\"op\":\"tap\",\"ref\":\"$send_full\"}]"

# ---- standard: send runs and is logged ----
rm -f "$T/policy.json"; reset_log
out="$("$PHONE" act --steps="$STEPS" 2>&1)"; rc=$?
check "standard: a send runs (exit 0)" [ $rc -eq 0 ]
check "  types with %s for spaces" grep -q "input text 'hello%sAda'" "$T/input.log"
check "  taps the Send button's centre" grep -q 'input tap 990 2160' "$T/input.log"
check "  says it was allowed by the default" grep -q 'ALLOWED (default standard): send' <<<"$out"
check "  logs the tap with kind send" bash -c 'tail -1 "$1" | jq -e ".op == \"tap\" and .kind == \"send\" and .allowed_by == \"default standard\"" >/dev/null' _ "$T/home/actions.jsonl"
check "  the log is private (0600)" [ "$(stat -c %a "$T/home/actions.jsonl")" == 600 ]

# ---- careful: send stops before ANY step ----
policy '{"pay":"ask","publish":"ask","send":"ask","delete":"ask"}'; reset_log
out="$("$PHONE" act --steps="$STEPS" 2>&1)"; rc=$?
check "careful: a send stops with exit 73" [ $rc -eq 73 ]
check "  nothing was typed or tapped (the stop comes first)" [ ! -s "$T/input.log" ]
req="$(ls "$T/approvals"/*.json 2>/dev/null | head -1)"
check "  the ask is written in the browser's format" bash -c 'jq -e ".class == \"send\" and .label == \"Send\" and .payload.text == \"hello Ada\" and (.hash | length) == 64 and .source == \"phone\"" "$1" >/dev/null' _ "$req"
check "  the ask names the approve command" grep -q 'sudo 5dive browser approve' <<<"$out"
check "  with no relay it says how to put it on the row" grep -q -- '--browser-ask=' <<<"$out"
id="$(basename "$req" .json)"
check "  the ask id is <seat>-<12 hex>" bash -c '[[ "$1" =~ ^[a-z0-9._-]+-[0-9a-f]{12}$ ]]' _ "$id"

grant() { jq -n --arg id "$1" --arg h "$2" --argjson exp "$3" '{id:$id, hash:$h, expires_at:$exp, approved_by:"owner"}' > "$T/approvals/$1.granted"; }
h="$(jq -r .hash "$req")"
grant "$id" "$h" $(( $(date +%s) - 5 ))
out="$("$PHONE" act --steps="$STEPS" --approved="$id" 2>&1)"; rc=$?
check "an expired grant is refused (73)" bash -c '[ "$1" -eq 73 ] && grep -q expired <<<"$2"' _ "$rc" "$out"
grant "$id" "$h" $(( $(date +%s) + 600 ))
out="$("$PHONE" act --steps="[{\"op\":\"tap\",\"ref\":\"$send_full\"}]" --approved="$id" 2>&1)"; rc=$?
check "a grant for other steps is refused (73)" bash -c '[ "$1" -eq 73 ] && grep -q "different steps" <<<"$2"' _ "$rc" "$out"
reset_log
out="$("$PHONE" act --steps="$STEPS" --approved="$id" 2>&1)"; rc=$?
check "the exact approved steps run, Send tapped" bash -c '[ "$1" -eq 0 ] && grep -q "input tap 990 2160" "$2"' _ "$rc" "$T/input.log"
check "  the grant is spent" [ ! -e "$T/approvals/$id.granted" ]
check "  the log says who allowed it" bash -c 'tail -1 "$1" | jq -e ".allowed_by == \"approved $2\"" >/dev/null' _ "$T/home/actions.jsonl" "$id"
out="$("$PHONE" act --steps="$STEPS" --approved="$id" 2>&1)"; rc=$?
check "  and cannot be used twice (73)" [ $rc -eq 73 ]

# ---- by name, by position, by label ----
reset_log
out="$("$PHONE" act --steps='[{"op":"tap","ref":"button/Send"}]' 2>&1)"; rc=$?
check "careful: a name ref button/Send stops too" bash -c '[ "$1" -eq 73 ] && [ ! -s "$2" ]' _ "$rc" "$T/input.log"
reset_log
out="$("$PHONE" act --steps='[{"op":"key","key":"back"},{"op":"tap","x":990,"y":2160}]' 2>&1)"; rc=$?
check "careful: a tap by position on Send stops at run time, no tap sent" bash -c '[ "$1" -eq 73 ] && ! grep -q "input tap" "$2"' _ "$rc" "$T/input.log"
reset_log
out="$("$PHONE" act --steps='[{"op":"key","key":"enter","kind":"send"}]' 2>&1)"; rc=$?
check "careful: a step the agent labels send stops" bash -c '[ "$1" -eq 73 ] && [ ! -s "$2" ]' _ "$rc" "$T/input.log"
reset_log
out="$("$PHONE" act --steps="[{\"op\":\"type\",\"ref\":\"$entry\",\"text\":\"draft only\"}]" 2>&1)"; rc=$?
check "careful: typing alone does not stop" bash -c '[ "$1" -eq 0 ] && grep -q "draft%sonly" "$2"' _ "$rc" "$T/input.log"
out="$("$PHONE" act --steps='[{"op":"tap","ref":"button/Nowhere"}]' 2>&1)"; rc=$?
check "a name ref that is not on screen says so" bash -c '[ "$1" -eq 2 ] && grep -q "no button \"Nowhere\"" <<<"$2"' _ "$rc" "$out"

# ---- the policy file counts only when the granting uid owns it ----
policy '{"pay":"ask","publish":"ask","send":"ask","delete":"ask"}'
check "careful reads as careful" [ "$("$PHONE" approvals policy --json | jq -r .mode)" == careful ]
if [[ "$(id -u)" != 0 ]]; then
  out="$(FIVEDIVE_PHONE_GRANT_UID=0 "$PHONE" approvals policy --json)"
  check "a policy file the granting uid does not own is ignored (standard)" [ "$(jq -r .mode <<<"$out")" == standard ]
fi
: > "$T/policy.json"
check "an empty policy file is the default, not an error" [ "$("$PHONE" approvals policy --json | jq -r .mode)" == standard ]

# ---- standard: a money button is a payment and asks; a plain Send still runs ----
rm -f "$T/policy.json"
for b in "Send money" "Send payment" "Geld senden"; do
  reset_log
  out="$(FAKE_ADB_UI="$FIX/wallet.xml" "$PHONE" act --steps="[{\"op\":\"type\",\"text\":\"50\"},{\"op\":\"tap\",\"ref\":\"button/$b\"}]" 2>&1)"; rc=$?
  check "standard: button/$b stops with exit 73, nothing typed" bash -c '[ "$1" -eq 73 ] && [ ! -s "$2" ]' _ "$rc" "$T/input.log"
done
wsnap="$(FAKE_ADB_UI="$FIX/wallet.xml" "$PHONE" snapshot)"
check "the wallet's Send money button is flagged pay" grep -qE '^\[e[0-9]+\] button "Send money"  ⚠ pay$' <<<"$wsnap"
check "  and its plain Send button is flagged send" grep -qE '^\[e[0-9]+\] button "Send"  ⚠ send$' <<<"$wsnap"
wref="$(grep -oE '^\[e[0-9]+\] button "Send money"' <<<"$wsnap" | grep -oE 'e[0-9]+')"
reset_log
out="$(FAKE_ADB_UI="$FIX/wallet.xml" "$PHONE" act --steps="[{\"op\":\"tap\",\"ref\":\"$wref\"}]" 2>&1)"; rc=$?
check "standard: a snapshot ref on Send money stops too (73), no tap" bash -c '[ "$1" -eq 73 ] && [ ! -s "$2" ]' _ "$rc" "$T/input.log"
reset_log
out="$(FAKE_ADB_UI="$FIX/wallet.xml" "$PHONE" act --steps='[{"op":"tap","x":280,"y":460}]' 2>&1)"; rc=$?
check "standard: a tap by position on Send money stops at run time, no tap" bash -c '[ "$1" -eq 73 ] && ! grep -q "input tap" "$2"' _ "$rc" "$T/input.log"
reset_log
out="$("$PHONE" act --steps='[{"op":"tap","ref":"button/Send"}]' 2>&1)"; rc=$?
check "standard: plain button/Send still runs (exit 0, tapped)" bash -c '[ "$1" -eq 0 ] && grep -q "input tap 990 2160" "$2"' _ "$rc" "$T/input.log"

# ---- refusals and the rest ----
# ---- typing beyond plain English letters is pasted (DIVE-9242) ----
check "lib/type.dex is the build of android/src (its recorded sha256)" bash -c 'cd "$1/phone/lib" && sha256sum -c --quiet type.dex.sha256' _ "$ROOT"
rm -f "$T/policy.json"
for t in "Привет, как дела?" "café ¡olé!" "On my way 👋" "Zeile eins
Zeile zwei" "50%sale"; do
  reset_log
  js="$(jq -nc --arg e "$entry" --arg t "$t" '[{op:"type",ref:$e,text:$t}]')"
  out="$("$PHONE" act --steps="$js" 2>&1)"; rc=$?
  check "type \"${t//$'\n'/\\n}\" pastes it whole (exit 0)" bash -c '[ "$1" -eq 0 ] && [ "$(grep -c "^clip " "$2")" -eq 1 ] && [ "$(sed -n "/^clip /,\$p" "$2" | sed -n "1,/input keyevent 279/p" | sed "1s/^clip //;\$d")" == "$3" ]' _ "$rc" "$T/input.log" "$t"
  check "  helper copied first, PASTE key after the clip, clipboard emptied and helper deleted last" bash -c '
    l="$(grep -nE "^(push|clip |input keyevent 279|clip-clear)" "$1" | cut -d: -f2- | cut -c1-14 | tr "\n" "|")"
    [[ "$l" == "push /data/loc|clip "*"|input keyevent|clip-clear /da|" ]] && ! grep -q "input text" "$1"' _ "$T/input.log"
done
reset_log
out="$(FAKE_ADB_CLIP=refuse "$PHONE" act --steps="[{\"op\":\"type\",\"ref\":\"$entry\",\"text\":\"Привет\"}]" 2>&1)"; rc=$?
check "a phone that refuses the clipboard fails the step (exit 1), says why, no PASTE" bash -c '[ "$1" -eq 1 ] && grep -q "refused the clipboard" <<<"$2" && ! grep -q "keyevent 279" "$3"' _ "$rc" "$out" "$T/input.log"
check "  and still deletes the helper" grep -q '^clip-clear /data/local/tmp/.5dive-type.dex' "$T/input.log"
long="$(head -c 4001 /dev/zero | tr '\0' 'a')"
out="$("$PHONE" act --steps="[{\"op\":\"type\",\"text\":\"$long\"}]" 2>&1)"; rc=$?
check "a type step over 4000 characters is refused with exit 2" [ $rc -eq 2 ]
out="$("$PHONE" act --steps='[{"op":"fly"}]' 2>&1)"; rc=$?
check "an unknown op is refused" [ $rc -eq 2 ]
reset_log
out="$("$PHONE" act --steps='[{"op":"open","app":"com.example.chat"}]' 2>&1)"; rc=$?
check "open app starts its launcher activity" bash -c '[ "$1" -eq 0 ] && grep -q "am start -n com.example.chat/.Main" "$2"' _ "$rc" "$T/input.log"
out="$("$PHONE" act --steps='[{"op":"open","app":"com.nope"}]' 2>&1)"; rc=$?
check "open of an app that is not there fails clearly" bash -c '[ "$1" -ne 0 ] && grep -q "not installed" <<<"$2"' _ "$rc" "$out"
out="$("$PHONE" act --steps='[{"op":"wait","ms":1}]' --expect='free for lunch' 2>&1)"; rc=$?
check "--expect passes on text the screen shows" [ $rc -eq 0 ]
out="$("$PHONE" act --steps='[{"op":"wait","ms":1}]' --expect='never here' 2>&1)"; rc=$?
check "--expect fails on text it does not" [ $rc -eq 1 ]
check "the screenshot is a PNG kept private" bash -c 'f="$("$1" screenshot)" && [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " ")" == 89504e47 ] && [ "$(stat -c %a "$f")" == 600 ]' _ "$PHONE"

# ---- routines: recorded once, replayed with no model, approved on save (DIVE-9347) ----
export FIVEDIVE_PHONE_RETRY_WAIT=0
rm -f "$T/policy.json"; rm -f "$T/approvals"/*.json "$T/approvals"/*.granted
"$PHONE" snapshot >/dev/null
RSTEPS="[{\"op\":\"open\",\"app\":\"com.example.chat\"},{\"op\":\"type\",\"ref\":\"$entry\",\"text\":\"good morning\"},{\"op\":\"tap\",\"ref\":\"$send_full\"}]"
reset_log
out="$("$PHONE" act --steps="$RSTEPS" --record=morning 2>&1)"; rc=$?
RF="$T/home/routines/morning.json"
check "record: a 3-step act with --record runs (exit 0) and saves the routine" bash -c '[ "$1" -eq 0 ] && [ -s "$2" ]' _ "$rc" "$RF"
check "  the routine file is private (0600, folder 0700)" bash -c '[ "$(stat -c %a "$1")" == 600 ] && [ "$(stat -c %a "$(dirname "$1")")" == 700 ]' _ "$RF"
check "  steps are kept by control NAME, not by snapshot number" bash -c 'jq -e ".steps[1].ref == \"textbox/entry\" and .steps[2].ref == \"button/Send\"" "$1" >/dev/null' _ "$RF"
check "  each step after the open keeps the app it ran on (the checkpoint)" bash -c 'jq -e "(.steps[0].check == null) and .steps[1].check.app == \"com.example.chat\" and .steps[2].check.app == \"com.example.chat\"" "$1" >/dev/null' _ "$RF"
out="$("$PHONE" act --steps='[{"op":"key","key":"home"},{"op":"open","app":"com.example.chat"},{"op":"key","key":"back"}]' --record=fromhome 2>&1)"
check "  a step before the first open (home) keeps no app: it runs from any screen" bash -c 'jq -e "(.steps[0].check == null) and .steps[2].check.app == \"com.example.chat\"" "$1" >/dev/null' _ "$T/home/routines/fromhome.json"
"$PHONE" routine forget fromhome >/dev/null
check "  plain text typed is kept; the Send keeps its kind" bash -c 'jq -e ".steps[1].text == \"good morning\" and .steps[2].kind == \"send\"" "$1" >/dev/null' _ "$RF"
ask="$(jq -r .ask "$RF")"
check "  the save writes an owner ask in the browser's format, bound to the routine" bash -c '
  r="$2/$1.json"; [ -f "$r" ] && jq -e ".source == \"phone-routine\" and .class == \"save a routine\" and (.hash|length) == 64 and .payload[\"step 3\"] == \"tap \\\"Send\\\" (send)\"" "$r" >/dev/null' _ "$ask" "$T/approvals"
check "  the ask id is <seat>-<12 hex> (what browser approve accepts)" bash -c '[[ "$1" =~ ^[a-z0-9._-]+-[0-9a-f]{12}$ ]]' _ "$ask"
check "  it says the routine waits for the owner" grep -q 'does not run until your owner approves it' <<<"$out"
check "routine ls: waiting for the owner's yes" bash -c '"$1" routine ls | grep -q "^morning	3 steps	waiting for your owner"' _ "$PHONE"

reset_log
out="$("$PHONE" replay morning 2>&1)"; rc=$?
check "replay before the owner's yes: exit 73, nothing sent to the phone" bash -c '[ "$1" -eq 73 ] && [ ! -s "$2" ] && grep -q "waiting for your owner" <<<"$3"' _ "$rc" "$T/input.log" "$out"
# The owner's yes, as `sudo 5dive browser approve <id>` writes it: the request's hash, 30 minutes.
rh="$(jq -r .hash "$T/approvals/$ask.json")"
grant "$ask" "$rh" $(( $(date +%s) + 1800 ))
out="$(FIVEDIVE_PHONE_GRANT_UID=99999 "$PHONE" replay morning 2>&1)"; rc=$?
check "a grant not owned by the granting uid does not approve (73)" [ $rc -eq 73 ]
# ZERO MODEL CALLS: tripwires named like every way to reach a model sit first on
# PATH (BASH_ENV unset, so nothing re-adds the real ones); each logs if it runs.
mkdir -p "$T/trip"; : > "$T/trip.log"
for b in claude codex gemini 5dive curl wget node npx bun ssh nc; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/trip.log"\nexit 1\n' "$b" "$T" > "$T/trip/$b"; chmod +x "$T/trip/$b"; done
reset_log; : > "$T/calls.log"
out="$(env -u BASH_ENV PATH="$T/trip:$PATH" "$PHONE" replay morning 2>&1)"; rc=$?
check "replay after the yes: exit 0, every step sent" bash -c '[ "$1" -eq 0 ] && grep -q "am start -n com.example.chat/.Main" "$2" && grep -q "input text '"'"'good%smorning'"'"'" "$2" && grep -q "input tap 990 2160" "$2"' _ "$rc" "$T/input.log"
check "  it says no AI was used" grep -q 'no AI used' <<<"$out"
check "  zero model calls: no tripwire (claude, codex, 5dive, curl, node, ssh…) ran" [ ! -s "$T/trip.log" ]
check "  the only thing it drove was adb" bash -c 'grep -q "input tap" "$1" && [ -s "$2" ]' _ "$T/input.log" "$T/calls.log"
check "  the log ties each step to the routine" bash -c 'tail -1 "$1" | jq -e ".routine == \"morning\" and .op == \"tap\" and (.allowed_by | startswith(\"default\"))" >/dev/null' _ "$T/home/actions.jsonl"
check "  the yes is kept for the next run (not spent)" [ -f "$T/approvals/$ask.granted" ]
grant "$ask" "$rh" $(( $(date +%s) - 3600 ))
reset_log
out="$("$PHONE" replay morning --json 2>/dev/null)"; rc=$?
check "the next day (grant past its 30 minutes) it still runs: the yes is for the steps" bash -c '[ "$1" -eq 0 ] && jq -e ".ok and .model_calls == 0 and .steps == 3" <<<"$2" >/dev/null' _ "$rc" "$out"
policy '{"pay":"ask","publish":"ask","send":"ask","delete":"ask"}'; reset_log
out="$("$PHONE" replay morning 2>&1)"; rc=$?
check "careful: the approved routine's Send runs, allowed by the routine's yes" bash -c '[ "$1" -eq 0 ] && grep -q "input tap 990 2160" "$2" && tail -1 "$3" | jq -e ".allowed_by | startswith(\"routine morning\")" >/dev/null' _ "$rc" "$T/input.log" "$T/home/actions.jsonl"
rm -f "$T/policy.json"

# ---- checkpoints: a wrong screen STOPS the replay and names the step ----
reset_log
out="$(FAKE_ADB_APP=com.other.app "$PHONE" replay morning 2>&1)"; rc=$?
check "wrong app: exit 65" [ $rc -eq 65 ]
check "  names the step and what is wrong" grep -q 'STOPPED routine "morning" at step 2 of 3 (type "good morning" in entry): wrong screen, the phone shows com.other.app instead of com.example.chat' <<<"$out"
check "  the step before it ran, nothing after it did" bash -c 'grep -q "am start" "$1" && ! grep -q "input text" "$1" && ! grep -q "input tap" "$1"' _ "$T/input.log"
check "  gives the line to tell the owner and a screenshot" bash -c 'grep -q "Tell your owner: \"My phone routine" <<<"$1" && grep -q "screenshot: .*/shots/stop-morning-" <<<"$1"' _ "$out"
check "  routine ls shows the stop" bash -c '"$1" routine ls | grep -q "stopped at step 2"' _ "$PHONE"
sed 's/content-desc="Send"/content-desc="Archive"/' "$FIX/chat.xml" > "$T/nosend.xml"
reset_log
out="$(FAKE_ADB_UI="$T/nosend.xml" "$PHONE" replay morning 2>&1)"; rc=$?
check "same app, the Send button gone: exit 65 at step 3, it says which button" bash -c '[ "$1" -eq 65 ] && grep -q "at step 3 of 3 (tap \"Send\" (send)): wrong screen, there is no button \"Send\" on the screen" <<<"$2"' _ "$rc" "$out"
check "  the text was typed, the tap never sent" bash -c 'grep -q "input text" "$1" && ! grep -q "input tap 990" "$1"' _ "$T/input.log"
sed 's/content-desc="Send"/content-desc="Send money"/' "$FIX/chat.xml" > "$T/money.xml"
reset_log
out="$(FAKE_ADB_UI="$T/money.xml" "$PHONE" replay morning 2>&1)"; rc=$?
check "the button now reads Send money: exit 65, it would now pay" bash -c '[ "$1" -eq 65 ] && grep -q "would now pay or place an order, which the approved routine did not" <<<"$2" && ! grep -q "input tap 990" "$3"' _ "$rc" "$out" "$T/input.log"
out="$(FAKE_ADB_APP=com.other.app "$PHONE" replay morning --json 2>/dev/null)"; rc=$?
check "--json stop: ok false, stopped_at, tell_owner" bash -c '[ "$1" -eq 65 ] && jq -e ".ok == false and .stopped_at == 2 and (.tell_owner | test(\"stopped at step 2\"))" <<<"$2" >/dev/null' _ "$rc" "$out"
mkdir -p "$T/wake"; printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/wake/calls"\n' "$T" > "$T/wake/5dive"; chmod +x "$T/wake/5dive"
out="$(PATH="$T/wake:$PATH" FAKE_ADB_APP=com.other.app "$PHONE" replay morning --wake-on-stop 2>&1)"; rc=$?
check "--wake-on-stop (cron): the stop wakes this seat's agent to tell the owner" bash -c '[ "$1" -eq 65 ] && grep -q "^agent send .* --message=5dive phone: My phone routine \"morning\" stopped at step 2" "$2"' _ "$rc" "$T/wake/calls"

# ---- an edit asks again ----
cat "$RF" > "$T/morning.bak"
jq '.steps[1].text = "buy crypto"' "$T/morning.bak" > "$RF"
reset_log
out="$("$PHONE" replay morning 2>&1)"; rc=$?
check "a hand edit of the steps: exit 73, nothing ran" bash -c '[ "$1" -eq 73 ] && [ ! -s "$2" ] && grep -q "changed since your owner approved it" <<<"$3"' _ "$rc" "$T/input.log" "$out"
check "  routine ls says so" bash -c '"$1" routine ls | grep -q "changed since approved"' _ "$PHONE"
cat "$T/morning.bak" > "$RF"
"$PHONE" snapshot >/dev/null
out="$("$PHONE" act --steps="[{\"op\":\"type\",\"ref\":\"$entry\",\"text\":\"good evening\"},{\"op\":\"wait\",\"ms\":1},{\"op\":\"tap\",\"ref\":\"$send_full\"}]" --record=morning 2>&1)"; rc=$?
ask2="$(jq -r .ask "$RF")"
check "re-recording the same name is an edit: a new ask, the old yes removed" bash -c '[ "$1" -eq 0 ] && [ "$2" != "$3" ] && [ ! -e "$4/$2.granted" ] && [ ! -e "$4/$2.json" ] && [ -f "$4/$3.json" ]' _ "$rc" "$ask" "$ask2" "$T/approvals"
out="$("$PHONE" replay morning 2>&1)"; rc=$?
check "  and the edited routine waits for a new yes (73)" [ $rc -eq 73 ]
out="$("$PHONE" routine show morning)"
check "routine show lists the steps in plain words" bash -c 'grep -q "^routine morning: waiting" <<<"$1" && grep -q "1. type \"good evening\" in entry" <<<"$1" && grep -q "3. tap \"Send\" (send)" <<<"$1"' _ "$out"

# ---- sign-in boxes: never kept, given at each run ----
lsnap="$(FAKE_ADB_UI="$FIX/login.xml" "$PHONE" snapshot)"
user="$(grep -oE '^\[e[0-9]+\] textbox "Email"' <<<"$lsnap" | grep -oE 'e[0-9]+')"
pw="$(grep -oE '^\[e[0-9]+\] textbox "pw"' <<<"$lsnap" | grep -oE 'e[0-9]+')"
reset_log
out="$(FAKE_ADB_UI="$FIX/login.xml" "$PHONE" act --steps="[{\"op\":\"type\",\"ref\":\"$user\",\"text\":\"ada@example.com\"},{\"op\":\"type\",\"ref\":\"$pw\",\"text\":\"Hunter2pass\"},{\"op\":\"tap\",\"ref\":\"button/Sign in\"}]" --record=signin 2>&1)"; rc=$?
SF="$T/home/routines/signin.json"
check "record on a sign-in screen: the run types both (exit 0)" bash -c '[ "$1" -eq 0 ] && grep -q "Hunter2pass" "$2"' _ "$rc" "$T/input.log"
check "  the routine keeps neither the password nor the user name" bash -c '! grep -q "Hunter2pass" "$1" && ! grep -q "ada@example.com" "$1" && jq -e "[.steps[] | select(.secret == true)] | length == 2" "$1" >/dev/null' _ "$SF"
check "  nor does the owner's ask or the step log" bash -c '! grep -rq "Hunter2pass" "$1" "$2" && ! grep -q "ada@example.com" "$2"' _ "$T/approvals" "$T/home/actions.jsonl"
sa="$(jq -r .ask "$SF")"; grant "$sa" "$(jq -r .hash "$T/approvals/$sa.json")" $(( $(date +%s) + 600 ))
reset_log
out="$(FAKE_ADB_UI="$FIX/login.xml" "$PHONE" replay signin 2>&1)"; rc=$?
check "replay without the sign-in values: exit 2, nothing ran" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ] && grep -q "2 sign-in box" <<<"$3"' _ "$rc" "$T/input.log" "$out"
out="$(FAKE_ADB_UI="$FIX/login.xml" "$PHONE" replay signin --values='["bob@example.com","S3cretpass"]' 2>&1)"; rc=$?
check "  with --values they are typed in order (exit 0)" bash -c '[ "$1" -eq 0 ] && grep -q "bob@example.com" "$2" && grep -q "S3cretpass" "$2"' _ "$rc" "$T/input.log"
check "  and never logged" bash -c '! grep -q "S3cretpass" "$1"' _ "$T/home/actions.jsonl"

out="$("$PHONE" routine forget signin)"; rc=$?
check "routine forget removes it and its yes" bash -c '[ "$1" -eq 0 ] && [ ! -e "$2" ] && [ ! -e "$3/$4.granted" ]' _ "$rc" "$SF" "$T/approvals" "$sa"
out="$("$PHONE" act --steps='[{"op":"wait","ms":1}]' --record='bad name' 2>&1)"; rc=$?
check "a routine name with a space is refused (exit 2)" [ $rc -eq 2 ]
out="$("$PHONE" replay nosuch 2>&1)"; rc=$?
check "replay of a routine that does not exist: exit 2, says how to save one" bash -c '[ "$1" -eq 2 ] && grep -q -- "--record=nosuch" <<<"$2"' _ "$rc" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
