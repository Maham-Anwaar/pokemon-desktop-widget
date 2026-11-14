#!/bin/zsh
# Downloads Gen 1-3 (#1-386) sprites for the Pokemon widget.
#   bw/<dex>.gif          animated Black/White front sprite (PokeAPI sprite mirror)
#   walk/<dex>.png        8-direction walk-cycle sheet (PMDCollab SpriteCollab)
#   walk/<dex>.xml        frame sizes/timings for that sheet
#   shiny/bw/<dex>.gif    shiny animated Black/White sprite
#   shiny/walk/<dex>.png  shiny walk sheet (+ .xml), where the community has drawn one
#   anim/<Name>/<dex>.png extra animation sheets used when you play with the walkers
#   shiny/anim/<Name>/<dex>.png  the same, shiny (where drawn)
#   names.json            dex number -> name
set -uo pipefail
OUT="${1:-$HOME/Documents/Pokemon Widget/sprites}"
ANIMS=(Idle Hop Attack Hurt Charge Rotate)
mkdir -p "$OUT/bw" "$OUT/walk" "$OUT/shiny/bw" "$OUT/shiny/walk"
for a in $ANIMS; do mkdir -p "$OUT/anim/$a" "$OUT/shiny/anim/$a"; done

curl -sf --max-time 30 "https://pokeapi.co/api/v2/pokemon-species?limit=386" \
  | /usr/bin/python3 -I -c '
import json,sys,re
d=json.load(sys.stdin)["results"]
print(json.dumps({re.search(r"/(\d+)/$",r["url"]).group(1): r["name"] for r in d}, indent=1))' > "$OUT/names.json"

CFG=$(mktemp)
for n in {1..386}; do
  p=$(printf "%04d" $n)
  add() { [[ -s "$1" ]] || printf 'url = "%s"\noutput = "%s"\n' "$2" "$1" >> "$CFG"; }
  add "$OUT/bw/$n.gif"   "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/$n.gif"
  add "$OUT/walk/$n.png" "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite/$p/Walk-Anim.png"
  add "$OUT/walk/$n.xml" "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite/$p/AnimData.xml"
  add "$OUT/shiny/bw/$n.gif"   "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/shiny/$n.gif"
  add "$OUT/shiny/walk/$n.png" "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite/$p/0000/0001/Walk-Anim.png"
  add "$OUT/shiny/walk/$n.xml" "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite/$p/0000/0001/AnimData.xml"
  for a in $ANIMS; do
    add "$OUT/anim/$a/$n.png"       "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite/$p/$a-Anim.png"
    add "$OUT/shiny/anim/$a/$n.png" "https://raw.githubusercontent.com/PMDCollab/SpriteCollab/master/sprite/$p/0000/0001/$a-Anim.png"
  done
done

curl -s --fail --remove-on-error --retry 2 --max-time 30 --parallel --parallel-max 6 -K "$CFG" \
  -w '%{http_code} %{url}\n' | grep -v '^200 ' || true
rm -f "$CFG"
echo DONE
