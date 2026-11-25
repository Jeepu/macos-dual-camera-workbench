#!/bin/bash
set -euo pipefail
umask 077

source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$HOME/Library/Application Support/CameraCollector"
app="$root/CameraCollector.app"
label=local.dataset.dual-camera-collector
domain="gui/$(id -u)"
agent_dir="$HOME/Library/LaunchAgents"
plist="$agent_dir/$label.plist"
temp_file=
trap 'if [ -n "$temp_file" ]; then /bin/rm -f -- "$temp_file"; fi' EXIT

run_camera() {
    local mode="$1"
    temp_file="$(mktemp /private/tmp/camera-result.XXXXXXXX)"
    local selected_app="$app"
    local selected_args=("$mode" "$root" "$temp_file")
    if [[ -f "$root/capture-runtime.json" ]]; then
        local preview_app
        preview_app="$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["appPath"] if d.get("runtime") == "preview" else "")' "$root/capture-runtime.json")"
        if [[ -d "$preview_app" ]]; then
            selected_app="$preview_app"
            selected_args=("--camera-collector" "$mode" "$root" "$temp_file")
        fi
    fi
    if ! /usr/bin/open -n -g -W -a "$selected_app" --args "${selected_args[@]}"; then
        echo "无法通过 macOS 启动 Camera Collector。" >&2
        return 1
    fi
    if [[ ! -s "$temp_file" ]]; then
        echo "Camera Collector 退出时没有写入检查结果。" >&2
        return 1
    fi
    if [[ "$(head -n 1 "$temp_file")" != OK ]]; then
        tail -n +2 "$temp_file" >&2
        return 1
    fi
    tail -n +2 "$temp_file"
    /bin/rm -f -- "$temp_file"
    temp_file=
}

archive_dataset() {
    /usr/bin/python3 "$root/organize-dataset.py" "$root" archive
}

write_agent_plist() {
    /usr/bin/plutil -create xml1 "$temp_file"
    /usr/bin/plutil -insert Label -string "$label" "$temp_file"
    /usr/bin/plutil -insert ProgramArguments -array "$temp_file"
    /usr/bin/plutil -insert ProgramArguments.0 -string /bin/bash "$temp_file"
    /usr/bin/plutil -insert ProgramArguments.1 -string "$root/camera-collector.sh" "$temp_file"
    /usr/bin/plutil -insert ProgramArguments.2 -string capture "$temp_file"
    /usr/bin/plutil -insert StartCalendarInterval -dictionary "$temp_file"
    /usr/bin/plutil -insert StartCalendarInterval.Minute -integer 0 "$temp_file"
    /usr/bin/plutil -insert StandardOutPath -string "$root/capture.log" "$temp_file"
    /usr/bin/plutil -insert StandardErrorPath -string "$root/capture.log" "$temp_file"
    /usr/bin/plutil -lint -s "$temp_file"
}

install_agent() {
    /bin/mkdir -p "$agent_dir"
    temp_file="$(mktemp "$agent_dir/.$label.XXXXXXXX")"
    write_agent_plist
    if [[ -f "$plist" ]] && ! /usr/bin/cmp -s "$temp_file" "$plist"; then
        echo "已有同名任务使用其他配置：$plist" >&2
        return 1
    fi
    if ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
        /bin/mv -f -- "$temp_file" "$plist"
        temp_file=
        if ! /bin/launchctl bootstrap "$domain" "$plist"; then
            /bin/rm -f -- "$plist"
            return 1
        fi
    fi
    /bin/launchctl print "$domain/$label" >/dev/null
    echo "定时任务已启用，每小时整点采集。"
    echo "照片目录：$root/dataset"
    echo "定时日志：$root/capture.log"
}

case "${1:-setup}" in
    probe)
        if [[ ! -d "$app" ]]; then
            app="$source_dir/CameraCollector.app"
        fi
        run_camera probe
        ;;
    setup)
        /bin/mkdir -p "$root"
        if [[ "$source_dir" != "$root" ]]; then
            /usr/bin/ditto "$source_dir/CameraCollector.app" "$app"
            /usr/bin/install -m 700 "$source_dir/camera-collector.sh" "$root/camera-collector.sh"
            /usr/bin/install -m 700 "$source_dir/organize-dataset.py" "$root/organize-dataset.py"
        fi
        if [[ -f "$root/dataset-task.json" ]]; then
            run_camera setup >/dev/null
            archive_dataset
        else
            run_camera setup
        fi
        install_agent
        ;;
    capture)
        echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S %z')] 开始双摄像头采集"
        if [[ -f "$root/dataset-task.json" ]]; then
            run_camera capture >/dev/null
            archive_dataset
        else
            run_camera capture
        fi
        ;;
    status)
        /bin/launchctl print "$domain/$label"
        ;;
    stop)
        if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
            /bin/launchctl bootout "$domain/$label"
        fi
        /bin/rm -f -- "$plist"
        echo "定时任务已停止。"
        ;;
    *)
        echo "用法：$0 {probe|setup|capture|status|stop}" >&2
        exit 64
        ;;
esac
