#!/usr/bin/env python3
import argparse
from contextlib import suppress
from datetime import datetime, timedelta
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile

BATCH_FORMAT = "%Y-%m-%d_%H-%M-%S-%f_%z"


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_json(path, value):
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=".pending-", delete=False
    ) as temporary:
        saved = Path(temporary.name)
        try:
            json.dump(value, temporary, ensure_ascii=False, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
            os.replace(saved, path)
        finally:
            saved.unlink(missing_ok=True)


def batches(dataset):
    for folder in dataset.iterdir():
        if not folder.is_dir() or folder.is_symlink():
            continue
        timestamp, separator, batch_id = folder.name.rpartition("_")
        if not separator or not re.fullmatch(r"[0-9A-Fa-f]{8}", batch_id):
            continue
        try:
            moment = datetime.strptime(timestamp, BATCH_FORMAT)
        except ValueError:
            continue
        yield moment, folder


def source_images(folder):
    return [folder / f"camera-{camera}.jpg" for camera in (1, 2)]


def adjusted_images(folder):
    return [folder / f"camera-{camera}-adjusted.jpg" for camera in (1, 2)]


def linked(source, target):
    return not target.is_symlink() and target.is_file() and source.samefile(target)


def retire_sources(folder, destinations, adjusted_destinations=(), *, archived_focus=False):
    sources = source_images(folder) + (adjusted_images(folder) if adjusted_destinations else [])
    destinations = [*destinations, *adjusted_destinations]
    if not all(path.is_file() and not path.is_symlink() for path in destinations):
        raise ValueError(f"采集归档有缺失，请检查：{folder.name}")
    for source, destination in zip(sources, destinations):
        if source.exists() and not linked(source, destination):
            raise ValueError(f"归档照片与原文件不一致：{source}")
    for source in sources:
        source.unlink(missing_ok=True)
    if archived_focus:
        (folder / "capture-focus.json").unlink(missing_ok=True)
    with suppress(OSError):
        folder.rmdir()


def task_directory(dataset, task):
    start = datetime.fromisoformat(task["startedAt"])
    return dataset / f"{start:%Y-%m-%d_%H-%M-%S}-{task['id']}"


def archive(dataset, task):
    task_id = task["id"]
    start = datetime.fromisoformat(task["startedAt"])
    first_hour = start.replace(minute=0, second=0, microsecond=0)
    task_folder = task_directory(dataset, task)
    task_folder.mkdir(exist_ok=True)
    index_path = task_folder / ".captures.json"
    index = read_json(index_path, {"taskID": task_id, "startedAt": task["startedAt"], "batches": []})
    if (index["taskID"], index["startedAt"]) != (task_id, task["startedAt"]):
        raise ValueError(f"已存在同名但起始时间不同的任务：{task_folder.name}")
    entries = {batch["legacyFolder"]: batch for batch in index["batches"]}
    used_names = {name for batch in index["batches"] for name in batch["files"] + batch.get("adjustedFiles", [])}

    for moment, folder in sorted(batches(dataset)):
        if folder.name in entries:
            entry = entries[folder.name]
            retire_sources(folder, [task_folder / name for name in entry["files"]],
                           [task_folder / name for name in entry.get("adjustedFiles", [])],
                           archived_focus="focus" in entry)
            continue
        if moment < start:
            continue
        sources = source_images(folder)
        if not all(path.is_file() and not path.is_symlink() for path in sources):
            continue
        adjusted_sources = adjusted_images(folder)
        has_adjusted = all(path.is_file() and not path.is_symlink() for path in adjusted_sources)

        capture_hour = moment.astimezone(start.tzinfo).replace(minute=0, second=0, microsecond=0)
        hour = (capture_hour - first_hour) // timedelta(hours=1)
        take = 1
        while True:
            suffix = "" if take == 1 else f"-{take}"
            names = [f"{task_id}-{camera}-{hour}{suffix}.jpg" for camera in (1, 2)]
            targets = [task_folder / name for name in names]
            adjusted_names = [f"{Path(name).stem}-adjusted.jpg" for name in names] if has_adjusted else []
            adjusted_targets = [task_folder / name for name in adjusted_names]
            image_pairs = list(zip(sources, targets)) + list(zip(adjusted_sources, adjusted_targets))
            if not used_names.intersection(names + adjusted_names) and all(
                not os.path.lexists(target) or linked(source, target)
                for source, target in image_pairs
            ):
                break
            take += 1

        for source, target in image_pairs:
            if not linked(source, target):
                os.link(source, target)
        record = {
            "legacyFolder": folder.name,
            "timestamp": moment.isoformat(timespec="milliseconds"),
            "hour": hour,
            "files": names,
        }
        if adjusted_names:
            record["adjustedFiles"] = adjusted_names
        focus_path = folder / "capture-focus.json"
        if focus_path.is_file():
            with suppress(OSError, ValueError):
                focus = json.loads(focus_path.read_text())
                if isinstance(focus, dict):
                    record["focus"] = focus
        index["batches"].append(record)
        write_json(index_path, index)
        used_names.update(names + adjusted_names)
        retire_sources(folder, targets, adjusted_targets, archived_focus="focus" in record)
        print(f"已归档：{'、'.join(names)} → {task_folder}", flush=True)


def start_next_batch(dataset, config, current):
    dataset.mkdir(exist_ok=True)
    if current is not None:
        archive(dataset, current)

    numbers = [int(current["id"][1:])] if current is not None else []
    for folder in dataset.iterdir():
        match = re.search(r"-S([1-9][0-9]*)$", folder.name)
        if folder.is_dir() and match:
            numbers.append(int(match.group(1)))
    task = {
        "id": f"S{max(numbers, default=0) + 1}",
        "startedAt": datetime.now().astimezone().isoformat(timespec="milliseconds"),
    }
    folder = task_directory(dataset, task)
    folder.mkdir()
    write_json(folder / ".captures.json", {
        "taskID": task["id"], "startedAt": task["startedAt"], "batches": [],
    })
    write_json(config, task)
    print(task["id"], flush=True)


def main():
    parser = argparse.ArgumentParser(description="按任务编号和整点小时整理双摄像头采集结果。")
    parser.add_argument("root", type=Path)
    parser.add_argument("action", choices=("start", "archive", "new-batch"))
    parser.add_argument("task_id", nargs="?")
    arguments = parser.parse_args()
    if arguments.action == "start" and not re.fullmatch(r"S[1-9][0-9]*", arguments.task_id or ""):
        parser.error("任务编号需要形如 S1、S2。")
    if arguments.action != "start" and arguments.task_id is not None:
        parser.error("仅 start 接受任务编号。")

    dataset = arguments.root / "dataset"
    config = arguments.root / "dataset-task.json"
    with (arguments.root / ".organize.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        task = read_json(config, None)
        if arguments.action == "new-batch":
            start_next_batch(dataset, config, task)
            return
        if arguments.action == "start":
            if task is not None and task["id"] != arguments.task_id:
                raise ValueError(f"当前已经有采集任务 {task['id']}。")
            if task is None:
                earliest = min(
                    (moment for moment, folder in batches(dataset) if all(path.is_file() for path in source_images(folder))),
                    default=None,
                )
                if earliest is None:
                    raise ValueError("找不到可作为任务起始的完整照片对。")
                task = {"id": arguments.task_id, "startedAt": earliest.isoformat(timespec="milliseconds")}
                write_json(config, task)
        if task is not None:
            archive(dataset, task)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError) as error:
        raise SystemExit(f"数据归档失败：{error}") from error
