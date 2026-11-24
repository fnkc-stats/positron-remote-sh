#!/usr/bin/python3
"""Unattended night runs of Claude Code for this repository; night + day usage together stay under weekCap.

  night.py run [--dry-run]   one slot (launchd calls this at each slot in config.json)
  night.py tonight           one line: what the coming night will do (no tokens spent)
  night.py status            budget, skip flag, next slots
  night.py install           write the LaunchAgent from config.json and load it
  night.py uninstall         unload and remove it

Lives in <repo>/.claude/night/ and keeps its state, reports and logs there (git-ignored). Run it from the main
checkout, not a worktree: launchd points at this file's path. See README.md next to this file.
"""
import datetime as dt
import fcntl
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

HOME = os.path.expanduser("~")
DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(DIR))   # <repo>/.claude/night -> <repo>
CONFIG = os.path.join(DIR, "config.json")
STATE = os.path.join(DIR, "state.json")
SKIP = os.path.join(DIR, "skip")
ONLY = os.path.join(DIR, "only")   # one-night command override; the last slot removes it
LAST = os.path.join(DIR, "last.md")
HISTORY = os.path.join(DIR, "history.md")
LOGS = os.path.join(DIR, "logs")
LOCK = os.path.join(DIR, ".lock")
LABEL = "local.claude-night." + os.path.basename(REPO)
PLIST = os.path.join(HOME, "Library", "LaunchAgents", LABEL + ".plist")

SKIP_MAX_AGE_H = 20      # an older skip flag is forgotten
SLOT_MATCH_MIN = 45      # a run this close to a slot time counts as that slot
MIN_RUN_BUDGET = 1.0     # % of the week; less than this is not worth starting


def now():
    return dt.datetime.now().astimezone()


def log(msg):
    os.makedirs(LOGS, exist_ok=True)
    line = "%s %s" % (now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line)
    with open(os.path.join(LOGS, "night.log"), "a") as f:
        f.write(line + "\n")


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def local(ts):
    return dt.datetime.fromtimestamp(ts).astimezone()


def fmt(ts):
    return local(ts).strftime("%a %d %b %H:%M")


# ---------- slots ----------

def slot_times(cfg, start, end):
    """Every slot datetime in [start, end)."""
    out = []
    day = start.date() - dt.timedelta(days=1)
    while day <= end.date():
        for s in cfg["slots"]:
            h, m = map(int, s.split(":"))
            t = dt.datetime(day.year, day.month, day.day, h, m).astimezone()
            if start <= t < end:
                out.append(t)
        day += dt.timedelta(days=1)
    return sorted(out)


def current_slot(cfg, t):
    """Index of the slot this run belongs to, or None for an off-schedule (manual) run."""
    for i, s in enumerate(cfg["slots"]):
        h, m = map(int, s.split(":"))
        for d in (-1, 0, 1):
            st = (t + dt.timedelta(days=d)).replace(hour=h, minute=m, second=0, microsecond=0)
            if abs((t - st).total_seconds()) <= SLOT_MATCH_MIN * 60:
                return i
    return None


# ---------- claude ----------

def claude_env(cfg):
    env = dict(os.environ)
    env.update(cfg.get("env", {}))
    return env


def claude_bin(cfg):
    return cfg.get("claude") or shutil.which("claude", path=claude_env(cfg).get("PATH")) or "claude"


def limits_from(ev):
    w = (ev.get("rate_limit_info") or {}).get("unifiedWindows") or {}
    out = {}
    for k in ("five_hour", "seven_day"):
        if k in w and "utilization" in w[k]:
            out[k] = {"pct": round(w[k]["utilization"] * 100, 1), "resetsAt": w[k].get("resetsAt")}
    return out


def write_usage(limits):
    """Keep ~/.claude/mods/glance/usage.json fresh: nobody runs the status line at night, and /audit-fix refuses
    to launch when that file is over 30 minutes old. Same shape glance writes."""
    path = os.path.join(HOME, ".claude", "mods", "glance", "usage.json")
    old = {l.get("kind"): l for l in load(path, {}).get("limits", [])}
    for k, v in limits.items():
        old[k] = {"kind": k, "percentUsed": v["pct"],
                  "resetsAt": dt.datetime.fromtimestamp(v["resetsAt"], dt.timezone.utc)
                  .strftime("%Y-%m-%dT%H:%M:%S.000Z") if v.get("resetsAt") else None}
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    try:
        save(path, {"at": stamp, "limits": [old[k] for k in ("five_hour", "seven_day") if k in old]})
    except OSError as e:
        log("could not write usage.json: %s" % e)


def run_claude(cfg, prompt, cwd, extra, logfile, timeout_s, watch=None):
    """Run `claude -p` with stream-json; returns (last limits seen, result text, exit code, killed reason)."""
    cmd = [claude_bin(cfg), "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--permission-mode", cfg["permissionMode"]] + extra
    os.makedirs(LOGS, exist_ok=True)
    out = open(logfile, "a")
    proc = subprocess.Popen(cmd, cwd=cwd, env=claude_env(cfg), stdout=subprocess.PIPE,
                            stderr=out, text=True, start_new_session=True)
    killed = []

    def kill(reason):
        if killed:
            return
        killed.append(reason)
        log("stopping claude: " + reason)
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            time.sleep(30)
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    timer = threading.Timer(timeout_s, lambda: kill("time limit"))
    timer.daemon = True
    timer.start()
    limits, result = {}, ""
    for line in proc.stdout:
        out.write(line)
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "rate_limit_event":
            got = limits_from(ev)
            if got:
                limits.update(got)
                write_usage(limits)
                reason = watch(limits) if watch else None
                if reason:
                    threading.Thread(target=kill, args=(reason,), daemon=True).start()
        elif ev.get("type") == "result":
            result = ev.get("result") or ""
    code = proc.wait()
    timer.cancel()
    out.close()
    return limits, result, code, (killed[0] if killed else None)


def probe(cfg, logfile):
    limits, _, code, _ = run_claude(cfg, "Reply with just: ok", DIR, ["--model", "haiku"], logfile, 300)
    if code != 0 or "seven_day" not in limits:
        raise RuntimeError("usage probe failed (exit %s); see %s" % (code, logfile))
    return limits


# ---------- sources ----------

def repo_of(src):
    return os.path.join(REPO, src.get("repo", "."))


def newest_plan(src):
    files = sorted(glob.glob(os.path.join(repo_of(src), src["plan"])), key=os.path.getmtime)
    return files[-1] if files else None


NIGHT_RULES = """

This is an unattended night run started by .claude/night/night.py. Nobody is at the computer and nobody can
answer. For this run these rules replace the Usage gate's questions (in CLAUDE.md and the rewrite and audit-fix
skills):
- Never use AskUserQuestion. Set aside items that need a user decision and list their questions in your final message.
- Launch nothing new once any of these is true: seven_day percentUsed in ~/.claude/mods/glance/usage.json is
  {cap7}% or more; five_hour is {cap5}% or more; usage.json is older than 30 minutes; the local time is past {until}.
  Runs already going finish their item; release the claims of items you did not launch.
- Do not schedule resumes (no CronCreate, no ScheduleWakeup): the night job decides when to run again.
- If there is no open item or task you can start (all merged, taken by another chat, waiting on a dependency that
  is not merged, or waiting on a user decision), make the first line of your final message exactly NOTHING_OPEN.
- Your final message is the morning report for the user: PRs merged, PRs left open and why, items set aside with
  their questions. Keep it short.
"""


# ---------- run ----------

def cmd_run(dry):
    cfg = load(CONFIG, None)
    if cfg is None:
        sys.exit("no config.json")
    os.makedirs(LOGS, exist_ok=True)
    lockf = open(LOCK, "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("skip: the previous night run is still going")
        return
    t = now()
    slot = current_slot(cfg, t)
    last_slot = slot is not None and slot == len(cfg["slots"]) - 1
    stamp = t.strftime("%Y-%m-%d-%H%M")
    logfile = os.path.join(LOGS, stamp + ".jsonl")
    report = ["## %s %s%s" % (t.strftime("%a %d %b %H:%M"),
                              "slot %s" % cfg["slots"][slot] if slot is not None else "manual run",
                              " (dry run)" if dry else "")]

    def finish(lines):
        report.extend(lines)
        text = "\n".join(report) + "\n"
        print(text)
        if dry:
            return
        mode = "w" if slot == 0 else "a"
        with open(LAST, mode) as f:
            f.write(text + "\n")
        with open(HISTORY, "a") as f:
            f.write(text + "\n")

    # 1. skip flag: cancels the whole night; the night's last slot clears it
    if os.path.exists(SKIP):
        age_h = (time.time() - os.path.getmtime(SKIP)) / 3600
        if age_h > SKIP_MAX_AGE_H:
            log("old skip flag (%.0f h) ignored and removed" % age_h)
            if not dry:
                os.remove(SKIP)
        else:
            if last_slot and not dry:
                os.remove(SKIP)
            log("skip: skip flag set")
            return finish(["Skipped: you set the skip flag."])

    # one-night override: .claude/night/only holds the command to run instead of each source's own
    only = None
    if os.path.exists(ONLY):
        if (time.time() - os.path.getmtime(ONLY)) / 3600 > SKIP_MAX_AGE_H:
            log("old only file ignored and removed")
            if not dry:
                os.remove(ONLY)
        else:
            only = open(ONLY).read().strip() or None
            if only:
                log("tonight only: %s" % only)
                report.append("Tonight only: `%s`" % only)
            if last_slot and not dry:
                os.remove(ONLY)

    # 2. anything to do? (no tokens spent when every source is known to be empty)
    state = load(STATE, {"week": None, "nightSpent": 0.0, "nothingOpen": {}})
    todo = []
    for src in cfg["sources"]:
        plan = newest_plan(src)
        if not plan:
            log("source %s: no plan file" % src["name"])
            continue
        if not only and state["nothingOpen"].get(src["name"]) == os.path.getmtime(plan):
            log("source %s: nothing open last time and the plan has not changed" % src["name"])
            continue
        todo.append((src, plan))
    if only:   # the override runs once in this repository, whatever the sources say
        todo = [({"name": "tonight only", "command": only}, None)]
    if not todo:
        log("skip: nothing to do")
        return finish(["Skipped: nothing open in any source (plans unchanged since the last empty run)."])

    # 3. budget
    try:
        before = probe(cfg, logfile)
    except RuntimeError as e:
        log("error: %s" % e)
        return finish(["Error: %s" % e])
    week = before["seven_day"]["resetsAt"]
    if state["week"] != week:
        log("new week (resets %s): night spending back to 0" % fmt(week))
        state["week"], state["nightSpent"] = week, 0.0
    p7, p5 = before["seven_day"]["pct"], before["five_hour"]["pct"]
    left = max(0.0, cfg["weekCap"] - p7)   # night + everything else together stay under weekCap
    slots_left = max(1, len(slot_times(cfg, t - dt.timedelta(minutes=SLOT_MATCH_MIN), local(week))))
    per_run = left / slots_left if cfg.get("pacing") == "even" else left
    cap7 = round(p7 + per_run, 1)
    cap5 = cfg["fiveHourCap"]
    budget = ("week %.0f%% used (resets %s), five-hour %.0f%%; nights stop the week at %s%%, "
              "this run may spend %.1f%% -> stop at %.1f%%; nights spent %.1f%% this week so far"
              % (p7, fmt(week), p5, cfg["weekCap"], per_run, cap7, state["nightSpent"]))
    log(budget)
    reason = None
    if p7 >= cfg["weekCap"]:
        reason = "the week is at %.0f%% (night limit %s%%)" % (p7, cfg["weekCap"])
    elif p5 >= cap5:
        reason = "the five-hour window is at %.0f%%" % p5
    elif cap7 - p7 < MIN_RUN_BUDGET:
        reason = "the night share for this week is used up"
    if reason:
        log("skip: " + reason)
        if not dry:
            save(STATE, state)
        return finish(["Skipped: %s." % reason, "", budget])
    if dry:
        return finish(["Would run: %s" % ", ".join(s["name"] for s, _ in todo), "", budget])

    # 4. run each source within this slot's budget
    until = (t + dt.timedelta(hours=cfg["noNewWorkAfterHours"])).strftime("%H:%M")
    hard_s = cfg["hardStopHours"] * 3600
    margin = cfg["killMargin"]

    def watch(lim):
        if lim.get("seven_day", {}).get("pct", 0) >= cap7 + margin:
            return "week usage passed %.1f%%" % (cap7 + margin)
        if lim.get("five_hour", {}).get("pct", 0) >= 98:
            return "five-hour window at 98%"
        return None

    lines = []
    for src, plan in todo:
        command = only or src["command"]
        prompt = command + NIGHT_RULES.format(cap7=cap7, cap5=cap5, until=until)
        log("running %s: %s" % (src["name"], command))
        lim, result, code, killed = run_claude(cfg, prompt, repo_of(src), [], logfile,
                                               max(60, hard_s - (now() - t).total_seconds()), watch)
        if only:
            pass   # an override says nothing about the source's usual work
        elif result.strip().startswith("NOTHING_OPEN"):
            state["nothingOpen"][src["name"]] = os.path.getmtime(plan)
        else:
            state["nothingOpen"].pop(src["name"], None)
        head = "### %s — exit %s%s" % (src["name"], code, ", stopped: " + killed if killed else "")
        lines += [head, "", result.strip() or "(no final message; see %s)" % logfile, ""]
        if killed:
            break

    # 5. measure what the night spent
    try:
        after = probe(cfg, logfile)
        if after["seven_day"]["resetsAt"] == week:
            spent = max(0.0, after["seven_day"]["pct"] - p7)
        else:
            spent = 0.0   # the week reset during the run; the new week starts clean
        state["nightSpent"] = round(state["nightSpent"] + spent, 1)
        tail = ("Spent %.1f%% of the week (now %.0f%%, night limit %s%%); nights spent %.1f%% this week."
                % (spent, after["seven_day"]["pct"], cfg["weekCap"], state["nightSpent"]))
    except RuntimeError as e:
        tail = "Could not measure the spend: %s" % e
    log(tail)
    save(STATE, state)
    finish(lines + [tail])


# ---------- tonight (no tokens: last usage.json reading) ----------

def iso_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def cmd_tonight():
    cfg = load(CONFIG, None)
    state = load(STATE, {"week": None, "nightSpent": 0.0, "nothingOpen": {}})
    usage = load(os.path.join(HOME, ".claude", "mods", "glance", "usage.json"), {})
    t = now()
    nxt = slot_times(cfg, t, t + dt.timedelta(days=2))[:len(cfg["slots"])]
    when = " + ".join(s.strftime("%H:%M") for s in nxt)
    loaded = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL)],
                            capture_output=True).returncode == 0
    if not loaded:
        return print("Tonight: nothing — the launchd job is not loaded (.claude/night/night.py install).")
    if os.path.exists(SKIP) and (time.time() - os.path.getmtime(SKIP)) / 3600 <= SKIP_MAX_AGE_H:
        return print("Tonight (%s): nothing — skip flag set (rm .claude/night/skip to undo)." % when)
    only = (open(ONLY).read().strip() if os.path.exists(ONLY)
            and (time.time() - os.path.getmtime(ONLY)) / 3600 <= SKIP_MAX_AGE_H else "")
    todo = ([{"name": "tonight only", "command": only}] if only else
            [s for s in cfg["sources"] if newest_plan(s)
             and state["nothingOpen"].get(s["name"]) != os.path.getmtime(newest_plan(s))])
    if not todo:
        return print("Tonight (%s): nothing — no open work (plans unchanged since the last empty run)." % when)
    lim = {l["kind"]: l for l in usage.get("limits", [])}
    if "seven_day" not in lim:
        return print("Tonight (%s): %s; budget unknown (no usage reading yet)."
                     % (when, ", ".join(s["command"] for s in todo)))
    p7 = lim["seven_day"]["percentUsed"]
    week = iso_ts(lim["seven_day"]["resetsAt"])
    if p7 >= cfg["weekCap"]:
        return print("Tonight (%s): nothing — week already at %s%% (nights stop at %s%%)." % (when, p7, cfg["weekCap"]))
    left = max(0.0, cfg["weekCap"] - p7)
    slots_left = max(1, len(slot_times(cfg, nxt[0], local(week))))
    per_run = left / slots_left if cfg.get("pacing") == "even" else left
    if per_run < MIN_RUN_BUDGET:
        return print("Tonight (%s): nothing — week at %s%%, too close to the %s%% night limit."
                     % (when, p7, cfg["weekCap"]))
    print("Tonight (%s): %s — may take the week from %s%% up to %.0f%% (night limit %s%%; reading %s)."
          % (when, "; ".join("%s in %s" % (s["command"], os.path.basename(repo_of(s))) for s in todo),
             p7, p7 + per_run, cfg["weekCap"], local(iso_ts(usage["at"])).strftime("%H:%M")))


# ---------- status / install ----------

def cmd_status():
    cfg = load(CONFIG, {})
    state = load(STATE, {})
    usage = load(os.path.join(HOME, ".claude", "mods", "glance", "usage.json"), {})
    print("slots: %s   nights stop the week at %s%%" % (", ".join(cfg.get("slots", [])), cfg.get("weekCap")))
    if state.get("week"):
        print("week resets %s; nights spent %.1f%%" % (fmt(state["week"]), state.get("nightSpent", 0)))
    for l in usage.get("limits", []):
        print("last reading (%s): %s %s%%" % (usage.get("at"), l["kind"], l["percentUsed"]))
    print("skip flag: %s" % ("SET (cancels the next night)" if os.path.exists(SKIP) else "not set"))
    if os.path.exists(ONLY):
        print("only (next night): %s" % open(ONLY).read().strip())
    for name, mt in (state.get("nothingOpen") or {}).items():
        print("source %s: empty since its plan changed at %s" % (name, fmt(mt)))
    loaded = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL)],
                            capture_output=True).returncode == 0
    print("launchd job: %s" % ("loaded" if loaded else "NOT loaded"))
    nxt = slot_times(cfg, now(), now() + dt.timedelta(days=2))[:2] if cfg else []
    print("next slots: %s" % ", ".join(s.strftime("%a %H:%M") for s in nxt))


def cmd_install():
    cfg = load(CONFIG, None)
    intervals = ""
    for s in cfg["slots"]:
        h, m = map(int, s.split(":"))
        intervals += ("    <dict><key>Hour</key><integer>%d</integer>"
                      "<key>Minute</key><integer>%d</integer></dict>\n" % (h, m))
    # launchd starts with a bare environment: take PATH (and the glance mod's plugin dir, if set) from the shell that
    # runs install, so no personal paths live in the committed config.json
    envd = {k: os.environ[k] for k in ("PATH", "CLAUDE_CODE_PLUGIN_DIRS") if os.environ.get(k)}
    envd.update(cfg.get("env", {}))
    env = "".join("    <key>%s</key><string>%s</string>\n" % (k, v) for k, v in envd.items())
    plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>{script}</string><string>run</string></array>
  <key>StartCalendarInterval</key>
  <array>
{intervals}  </array>
  <key>EnvironmentVariables</key>
  <dict>
{env}  </dict>
  <key>StandardOutPath</key><string>{logs}/launchd.log</string>
  <key>StandardErrorPath</key><string>{logs}/launchd.log</string>
</dict>
</plist>
""".format(label=LABEL, script=os.path.join(DIR, "night.py"), intervals=intervals, env=env, logs=LOGS)
    os.makedirs(LOGS, exist_ok=True)
    with open(PLIST, "w") as f:
        f.write(plist)
    dom = "gui/%d" % os.getuid()
    subprocess.run(["launchctl", "bootout", dom, PLIST], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", dom, PLIST], check=True)
    print("installed %s (slots %s; claude: %s)" % (PLIST, ", ".join(cfg["slots"]), claude_bin(dict(cfg, env=envd))))


def cmd_uninstall():
    subprocess.run(["launchctl", "bootout", "gui/%d" % os.getuid(), PLIST], capture_output=True)
    if os.path.exists(PLIST):
        os.remove(PLIST)
    print("removed %s" % PLIST)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["run"]:
        cmd_run("--dry-run" in args)
    elif args[:1] == ["tonight"]:
        cmd_tonight()
    elif args[:1] == ["status"]:
        cmd_status()
    elif args[:1] == ["install"]:
        cmd_install()
    elif args[:1] == ["uninstall"]:
        cmd_uninstall()
    else:
        print(__doc__)
