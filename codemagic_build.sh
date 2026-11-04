#!/usr/bin/env bash
# codemagic_build.sh —— 用 Codemagic 免费 Mac mini M2 出未签名 IPA
#
# 用法:
#   COD_APITOKEN=xxx ./codemagic_build.sh            # 触发构建 + 等 + 下载
#   ./codemagic_build.sh apps                        # 只列出账号下的 app（拿 appId）
#
# token 存放: /home/user/.secrets/codemagic.env  →  COD_APITOKEN=xxxxx
set -uo pipefail

API=https://api.codemagic.io
WORKFLOW=ios-unsigned
BRANCH=main
APPNAME_MATCH=${APPNAME_MATCH:-VoiceRecite}
OUT=/home/user/recite-ios/out

[ -f /home/user/.secrets/codemagic.env ] && . /home/user/.secrets/codemagic.env
: "${COD_APITOKEN:?缺少 token：写 /home/user/.secrets/codemagic.env 里 COD_APITOKEN=xxx 或直接环境变量传入}"
H=(-H "Content-Type: application/json" -H "x-auth-token: $COD_APITOKEN")
mkdir -p "$OUT"

# ---------- 列 app ----------
list_apps() {
  curl -s "${H[@]}" "$API/apps" -o /tmp/cm_apps.json
  python3 - "$APPNAME_MATCH" <<'PY'
import json, sys
m = sys.argv[1].lower()
d = json.load(open('/tmp/cm_apps.json'))
apps = d.get('applications') or d.get('apps') or []
if not apps:
    print("账号下没有 app 或返回为空：", json.dumps(d)[:300]); raise SystemExit(3)
for a in apps:
    _id = a.get('_id') or a.get('id')
    name = a.get('appStoreName') or a.get('name') or ''
    repo = json.dumps(a.get('repository') or {}, ensure_ascii=False)
    flag = "  <== 匹配" if m in (name + repo).lower() else ""
    print(f"{_id}\t{name}\t{repo[:80]}{flag}")
PY
}

if [ "${1:-}" = "apps" ]; then list_apps; exit $?; fi

# ---------- 取 appId ----------
curl -s "${H[@]}" "$API/apps" -o /tmp/cm_apps.json
APPID=$(python3 - "$APPNAME_MATCH" <<'PY'
import json, sys
m = sys.argv[1].lower()
d = json.load(open('/tmp/cm_apps.json'))
apps = d.get('applications') or d.get('apps') or []
for a in apps:
    _id = a.get('_id') or a.get('id')
    hay = ((a.get('appStoreName') or a.get('name') or '') + json.dumps(a.get('repository') or {})).lower()
    if m in hay:
        print(_id); break
PY
)
[ -n "$APPID" ] || { echo "在 Codemagic 账号里找不到包含「$APPNAME_MATCH」的 app。先跑：$0 apps"; exit 3; }
echo "appId=$APPID"

# ---------- 触发构建 ----------
curl -s "${H[@]}" -X POST "$API/builds" \
  -d "{\"appId\":\"$APPID\",\"workflowId\":\"$WORKFLOW\",\"branch\":\"$BRANCH\",\"instanceType\":\"mac_mini_m2\"}" \
  -o /tmp/cm_build.json
BUILDID=$(python3 -c "import json;print(json.load(open('/tmp/cm_build.json')).get('buildId',''))")
[ -n "$BUILDID" ] || { echo "触发失败："; cat /tmp/cm_build.json; exit 4; }
echo "buildId=$BUILDID"
echo "网页: https://codemagic.io/app/$APPID/build/$BUILDID"

# ---------- 轮询 ----------
for i in $(seq 1 90); do
  curl -s "${H[@]}" "$API/builds/$BUILDID" -o /tmp/cm_one.json
  read -r st fin < <(python3 - <<'PY'
import json
d = json.load(open('/tmp/cm_one.json'))
b = d.get('build') or d
print(b.get('status','?'), b.get('finishedAt') or '-')
PY
)
  echo "[$(date +%H:%M:%S)] status=$st"
  case "$st" in
    finished)
      curl -s "${H[@]}" "$API/builds/$BUILDID" -o /tmp/cm_one.json
      python3 - <<'PY'
import json
d = json.load(open('/tmp/cm_one.json')); b = d.get('build') or d
print("buildStatus:", b.get('buildStatus') or b.get('status'))
for a in (b.get('artifacts') or []):
    print("ART", a.get('name'), a.get('size'), a.get('url'))
PY
      break ;;
    failed|timeout|canceled)
      echo "构建失败，日志尾部："
      python3 - <<'PY'
import json
d = json.load(open('/tmp/cm_one.json')); b = d.get('build') or d
for act in (b.get('buildActions') or []):
    print('  step:', act.get('name'), act.get('status'))
print('  log url:', (b.get('buildActions') or [{}])[-1].get('logUrl') if b.get('buildActions') else '')
PY
      exit 5 ;;
  esac
  sleep 20
done

# ---------- 下载 artifact ----------
URL=$(python3 - <<'PY'
import json
d = json.load(open('/tmp/cm_one.json')); b = d.get('build') or d
for a in (b.get('artifacts') or []):
    if (a.get('name') or '').endswith('.ipa'):
        print(a.get('url') or a.get('secureUrl') or ''); break
PY
)
[ -n "$URL" ] || { echo "没找到 ipa 产物"; exit 6; }
echo "下载: $URL"
curl -sL -H "x-auth-token: $COD_APITOKEN" "$URL" -o "$OUT/VoiceRecite-unsigned.ipa"
ls -lh "$OUT/VoiceRecite-unsigned.ipa"
file "$OUT/VoiceRecite-unsigned.ipa"
echo "下一步：/home/user/ios-ota/ios-ota2.sh $OUT/VoiceRecite-unsigned.ipa 朗读闯关"
