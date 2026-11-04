#!/usr/bin/env bash
# 轮询 VoiceRecite 的 Actions 运行，完成后把 artifact 下载到 /home/user/recite-ios/out/
set -uo pipefail
. /home/user/.secrets/github.env
API=https://api.github.com/repos/cn888/VoiceRecite
OUT=/home/user/recite-ios/out
mkdir -p "$OUT"
H=(-H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")

for i in $(seq 1 60); do
  curl -s "${H[@]}" "$API/actions/runs?per_page=1" -o /tmp/runs.json
  read -r id status concl < <(python3 - <<'PY'
import json
d=json.load(open('/tmp/runs.json'))
r=(d.get('workflow_runs') or [{}])[0]
print(r.get('id',0), r.get('status','none'), r.get('conclusion') or 'none')
PY
)
  echo "[$(date +%H:%M:%S)] run=$id status=$status conclusion=$concl"
  if [ "$status" = "completed" ]; then
    if [ "$concl" != "success" ]; then
      echo "构建失败，取日志："
      curl -s "${H[@]}" "$API/actions/runs/$id/jobs" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for j in d.get('jobs',[]):
    for s in j.get('steps',[]):
        print(s.get('number'), s.get('name'), s.get('conclusion'))
"
      exit 2
    fi
    break
  fi
  sleep 20
done

echo "== 下载 artifact =="
curl -s "${H[@]}" "$API/actions/runs/$id/artifacts" -o /tmp/arts.json
url=$(python3 -c "
import json
d=json.load(open('/tmp/arts.json'))
for a in d.get('artifacts',[]):
    if a['name']=='VoiceRecite-ipa':
        print(a['archive_download_url']); break
")
echo "artifact_url_ok=$([ -n "$url" ] && echo yes || echo no)"
curl -sL "${H[@]}" "$url" -o "$OUT/ipa.zip"
cd "$OUT" && rm -rf VoiceRecite-unsigned.ipa && unzip -o -q ipa.zip && ls -lh "$OUT"
