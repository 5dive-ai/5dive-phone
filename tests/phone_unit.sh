#!/usr/bin/env bash
# phone plugin harness (DIVE-9064): `5dive phone` against a fake adb.
# What it pins: the screen reads as refs, a Send/Pay/Delete tap is checked against
# the owner's policy BEFORE any step runs, a grant is bound to the exact steps and
# spent once, the policy file counts only when the granting uid owns it, and a
# phone that stopped answering says what to ask the owner, and text in any
# language is pasted through lib/type.dex (DIVE-9242).
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
