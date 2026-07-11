SKIPUNZIP=1
JSON_FILE="phone.json"
if [[ "$KSU" == "true" ]]; then
  ui_print "- KernelSU 用户空间版本号: $KSU_VER_CODE"
  ui_print "- KernelSU 内核空间版本号: $KSU_KERNEL_VER_CODE"
  if [ "$KSU_KERNEL_VER_CODE" -lt 11089 ]; then
    ui_print "*********************"
    ui_print "! 请安装 KernelSU 管理器 v0.6.2 或更高版本"
    abort "*********************"
  fi
elif [[ "$APATCH" == "true" ]]; then
  ui_print "- APatch 版本名: $APATCH_VER"
  ui_print "- APatch 版本号: $APATCH_VER_CODE"
else
  ui_print "- Magisk 版本名: $MAGISK_VER"
  ui_print "- Magisk 版本号: $MAGISK_VER_CODE"
  if [ "$MAGISK_VER_CODE" -lt 26000 ]; then
    ui_print "*********************"
    ui_print "! 请安装 Magisk 26.0+"
    abort "*********************"
  fi
fi

rm -rf /data/system/package_cache

TMPDIR="/data/local/tmp"
mkdir -p "$TMPDIR"

unzip -oj "$ZIPFILE" \
  module.prop \
  post-fs-data.sh \
  "$JSON_FILE" \
  -d "$MODPATH" >/dev/null 2>&1

new_xms_version="$(jq -r '.sota_version' "$MODPATH/$JSON_FILE")"
ui_print "*********************"
ui_print "- 正在更新 SOTA 版本至 $new_xms_version"
{
  echo "version=$new_xms_version"
  echo "description=更新 SOTA 版本至 $new_xms_version"
} >>"$MODPATH/module.prop"

jq -r '
.apps[]
| [
    .packageName,
    .versionCode,
    .fileName,
    .md5,
    .downloadUrls[0]
]
| @tsv
' "$MODPATH/$JSON_FILE" |
  while IFS=$'\t' read -r \
    packageName versionCode fileName md5 downloadUrls; do

    # 提取路径部分（去掉协议+域名 和 查询参数），拼接阿里云 OSS 域名
    url_path="${downloadUrls#*//*/}"    # 去掉 https://任意域名/
    url_path="${url_path%%\?*}"          # 去掉 ?t=...&s=...
    downloadUrls="https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com/${url_path}"

    apk_path="$(pm path "$packageName" 2>/dev/null)"
    apk_path="${apk_path#package:}"
    [ -n "$apk_path" ] || {
      ui_print "- $packageName 未安装，跳过检测"
      continue
    }

    current_pkg_label=$(aapt2 dump badging "$apk_path" | awk -F"'" '/application-label-zh-CN:/ {print $2; exit}')
    current_pkg_info="$(dumpsys package "$packageName")"
    current_pkg_versionCode=$(printf '%s\n' "$current_pkg_info" | grep 'versionCode=' | head -n1 | awk -F= '{print $2}' | awk '{print $1}')
    current_pkg_versionName=$(printf '%s\n' "$current_pkg_info" | grep 'versionName=' | head -n1 | awk -F= '{print $2}' | awk '{print $1}')

    need_update=$(jq -n --arg local "$current_pkg_versionCode" --arg cloud "$versionCode" '($cloud | tonumber) > ($local | tonumber)')

    if [ "$need_update" = "false" ]; then
      ui_print "- $current_pkg_label 已是最新版本"
      continue
    fi
    ui_print "*********************"
    ui_print "- 检测到 $current_pkg_label 有新版本, 正在下载..."
    aria2c -x16 -s16 --min-split-size=1M --continue=true --check-certificate=false --retry-wait=2 --max-tries=3 -d "$TMPDIR" -o "$fileName" "$downloadUrls" >/dev/null 2>&1
    [ -f "$TMPDIR/$fileName" ] || {
      ui_print "! 下载 $current_pkg_label 新版本失败!"
      continue
    }

    md5_actual=$(md5sum "$TMPDIR/$fileName" | awk '{print $1}')
    [ "$md5_actual" = "$md5" ] || {
      ui_print "! MD5 校验失败"
      rm -f "$TMPDIR/$fileName"
      continue
    }

    pkg_versionName=$(aapt2 dump badging "$TMPDIR/$fileName" | awk -F"'" '/versionName=/{print $6; exit}')
    ui_print "- 正在更新 $current_pkg_label $current_pkg_versionName -> $pkg_versionName, 请稍等"
    pm install -r -i com.android.updater "$TMPDIR/$fileName" >/dev/null 2>&1
    rm -f "$TMPDIR/$fileName"
    current_pkg_info="$(dumpsys package "$packageName")"
    current_pkg_versionCode=$(printf '%s\n' "$current_pkg_info" | grep 'versionCode=' | head -n1 | awk -F= '{print $2}' | awk '{print $1}')
    if [ "$current_pkg_versionCode" = "$versionCode" ]; then
      ui_print "- $current_pkg_label $pkg_versionName 更新成功"
    else
      ui_print "! $current_pkg_label $pkg_versionName 更新失败"
    fi
    ui_print "*********************"
  done

rm -rf "$TMPDIR" "$MODPATH/$JSON_FILE"

settings put secure xota_update 1
settings put secure xota_version "$new_xms_version"
setprop persist.sys.xms.version "$new_xms_version"
