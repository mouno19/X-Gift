#!/bin/bash
# XGift private settings helper (English prompts).
#   sudo xgift-credentials
# Adds the items only you can provide: X login cookies, the Stripe publishable key
# and payment cards. Everything is written straight into the encrypted vault
# (/var/lib/xgift/vault.db); nothing is logged or sent anywhere else.
set -uo pipefail
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

XG=/usr/local/bin/xgift
ENV=/etc/xgift/site.env
[ -e /var/lib/xgift/vault.db ] || { echo "No vault at /var/lib/xgift/vault.db - run the installer first."; exit 1; }

ask()    { local __v; read -r -p "$1: " __v; printf -v "$2" '%s' "$__v"; }
secret() { local __v; read -r -s -p "$1 (hidden): " __v; echo; printf -v "$2" '%s' "$__v"; }
ok()     { echo "  -> $*"; }

x_cookies() {
  echo
  echo "X login cookies: log in to x.com in your browser, press F12 ->"
  echo "Application -> Cookies -> https://x.com, and copy auth_token and ct0."
  local at ct
  secret "auth_token" at; secret "ct0" ct
  if [ -z "$at" ] || [ -z "$ct" ] || [[ "$at$ct" == *";"* ]]; then echo "  !! both values are required (no semicolons)"; return; fi
  AT="$at" CT="$ct" python3 -c 'import json,os;print(json.dumps({"cookies":[{"name":"auth_token","value":os.environ["AT"],"domain":".x.com"},{"name":"ct0","value":os.environ["CT"],"domain":".x.com"}]}))' \
    | $XG put --name cookies && ok "X cookies saved (auth_token ending ${at: -4})"
}

stripe_key() {
  echo
  echo "Stripe publishable key used by the X checkout page (starts with pk_live_)."
  local k; secret "pk_live_ key" k
  if [[ ! "$k" =~ ^pk_live_[A-Za-z0-9]+$ ]]; then echo "  !! must look like pk_live_ followed by letters/digits"; return; fi
  printf '%s' "$k" | $XG put --name stripe-key && ok "Stripe key saved (ending ${k: -4})"
}

add_card() {
  echo
  echo "Payment card - use the exact details registered with your bank."
  echo "(Billing fields can be left empty for a 2nd+ card; they are copied from the existing card.)"
  local num m y cvc name email country postal l1 l2 city state
  secret "Card number" num; num="${num//[ -]/}"
  ask "Expiry month (01-12)" m; [[ "$m" =~ ^[1-9]$ ]] && m="0$m"
  ask "Expiry year (4 digits, e.g. 2030)" y
  secret "CVC" cvc
  ask "Cardholder name" name
  ask "Billing email" email
  ask "Billing country, 2 letters (e.g. BD)" country; country="${country^^}"
  ask "Postal code (optional)" postal
  ask "Address line 1 (optional)" l1
  ask "Address line 2 (optional)" l2
  ask "City (optional)" city
  ask "State/region (optional)" state
  NUM="$num" M="$m" Y="$y" CVC="$cvc" NAME="$name" EMAIL="$email" C="$country" P="$postal" L1="$l1" L2="$l2" CITY="$city" ST="$state" python3 -c '
import json,os
e=os.environ
d={"number":e["NUM"],"exp_month":e["M"],"exp_year":e["Y"],"cvc":e["CVC"]}
for k,v in [("billing_name","NAME"),("email","EMAIL"),("billing_country","C"),("billing_postal_code","P"),("billing_address_line1","L1"),("billing_address_line2","L2"),("billing_city","CITY"),("billing_state","ST")]:
    if e[v].strip(): d[k]=e[v].strip()
print(json.dumps(d))' | $XG cards add && ok "card ending ${num: -4} saved"
}

payments() {
  local cur; cur=$(grep '^XGIFT_PAYMENTS_ENABLED=' "$ENV" | cut -d= -f2)
  echo
  echo "Public payments are currently: ${cur:-false}"
  if [ "$cur" = "true" ]; then
    local a; ask "Turn payments OFF? (yes/no)" a
    [ "$a" = "yes" ] || return
    sed -i 's/^XGIFT_PAYMENTS_ENABLED=.*/XGIFT_PAYMENTS_ENABLED=false/' "$ENV"
  else
    echo "Turning payments ON lets customers' redemptions charge your saved card(s) for real."
    echo "Check 'Show status' first: every record should be verified."
    local a; ask "Type ENABLE to turn payments ON" a
    [ "$a" = "ENABLE" ] || { echo "  unchanged"; return; }
    sed -i 's/^XGIFT_PAYMENTS_ENABLED=.*/XGIFT_PAYMENTS_ENABLED=true/' "$ENV"
  fi
  systemctl restart xgift && sleep 2 && curl -fsS http://127.0.0.1:8787/healthz && echo
}

status() {
  echo
  $XG status 2>&1 | sed 's/^/  /'
  echo "  -- cards --"
  $XG cards list 2>&1 | sed 's/^/  /' | head -20
  echo "  -- service: $(systemctl is-active xgift), $(curl -s http://127.0.0.1:8787/healthz)"
}

while true; do
  echo
  echo "=== XGift private settings ==="
  echo " 1) X login cookies (auth_token + ct0)"
  echo " 2) Stripe publishable key (pk_live_...)"
  echo " 3) Add a payment card"
  echo " 4) Show status"
  echo " 5) Turn public payments ON/OFF"
  echo " q) Quit"
  read -r -p "Choose: " c || exit 0
  case "$c" in
    1) x_cookies ;; 2) stripe_key ;; 3) add_card ;; 4) status ;; 5) payments ;;
    q|Q) exit 0 ;; *) echo "  ?" ;;
  esac
done
