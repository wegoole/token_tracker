# -*- coding: utf-8 -*-
"""ttk_service.py - CodeBuddy 矩阵刷新、每日自动签到与记录服务模块
为 ttk.py 与 _ttk.ps1 提供 6 通道实时积分刷新、每日签到自动化及运行历史记录支持。
"""

import os
import sys
import json
import datetime
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CB_LOGIN_DIR = r"E:\ai tec\cb_login"
PROFILES_FILE = os.path.join(CB_LOGIN_DIR, "profiles.json")
SIGNIN_STATE_FILE = os.path.join(BASE_DIR, "signin_state.json")
SIGNIN_LOG_FILE = os.path.join(BASE_DIR, "signin_history.jsonl")
RECORDS_LOG_FILE = os.path.join(BASE_DIR, "records_history.jsonl")
SCAN_LOG_FILE = os.path.join(BASE_DIR, "scan_history.jsonl")
STATUS_MD_SRC = os.path.join(CB_LOGIN_DIR, "CREDIT_STATUS.md")
STATUS_MD_LOCAL = os.path.join(BASE_DIR, "CREDIT_STATUS.md")
COOLDOWN_FILE = os.path.join(CB_LOGIN_DIR, "matrix_cooldown.json")
TARGET6_CREDITS_FILE = os.path.join(CB_LOGIN_DIR, "target6_credits.json")
BRIDGE_PORT = 18777


def ensure_bridge():
    """脚本猫回传接收端（127.0.0.1:18777）没起就拉起来；返回是否可用。"""
    import socket
    import subprocess

    def alive():
        s = socket.socket()
        s.settimeout(0.4)
        try:
            s.connect(("127.0.0.1", BRIDGE_PORT))
            return True
        except Exception:
            return False
        finally:
            try:
                s.close()
            except Exception:
                pass

    if alive():
        return True
    script = os.path.join(CB_LOGIN_DIR, "wb_credit_bridge.py")
    if not os.path.exists(script):
        return False
    try:
        flags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
        subprocess.Popen([sys.executable, script], cwd=CB_LOGIN_DIR,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=flags)
        time.sleep(0.6)
        return alive()
    except Exception:
        return False

REAL_HOME = os.environ.get("USERPROFILE", os.path.expanduser("~"))

# 导入 429 冷静期模块
try:
    sys.path.insert(0, CB_LOGIN_DIR)
    from matrix_cooldown import check_target_cooldown, record_rate_limit, record_target_success
except Exception:
    def check_target_cooldown(tid):
        return False, 0, "正常可用"
    def record_rate_limit(*args, **kwargs):
        pass
    def record_target_success(*args, **kwargs):
        pass

def get_today_str():
    return datetime.datetime.now().strftime("%Y-%m-%d")

def get_now_str():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def make_clean_opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))

def get_target1_token():
    auth_file = os.path.join(
        REAL_HOME,
        r"AppData\Local\CodeBuddyExtension\Data\Public\auth\Tencent-Cloud.coding-copilot.info"
    )
    if not os.path.exists(auth_file):
        return None, "国内主号授权文件不存在"
    try:
        with open(auth_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        token = data.get("auth", {}).get("accessToken", "")
        nickname = data.get("account", {}).get("nickname", "Wengole")
        if not token:
            return None, "accessToken 为空"
        return token, nickname
    except Exception as e:
        return None, str(e)

def get_target_token(tgt):
    if tgt.get("kind") == "api":
        return None, "api"
    home_rel = tgt.get("home", "~")
    if home_rel == "~":
        home_dir = REAL_HOME
    else:
        home_dir = os.path.normpath(os.path.join(CB_LOGIN_DIR, home_rel))
    auth_file = os.path.join(
        home_dir,
        r"AppData\Local\CodeBuddyExtension\Data\Public\auth\Tencent-Cloud.coding-copilot.info"
    )
    if not os.path.exists(auth_file):
        return None, "未找到凭据"
    try:
        with open(auth_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("auth", {}).get("accessToken", ""), data.get("account", {}).get("nickname", "")
    except Exception as e:
        return None, str(e)

# ==================== 每日签到逻辑 ====================

def check_signin_today():
    """检查今日是否已经签到"""
    today = get_today_str()
    if os.path.exists(SIGNIN_STATE_FILE):
        try:
            with open(SIGNIN_STATE_FILE, "r", encoding="utf-8") as f:
                st = json.load(f)
            if st.get("last_signin_date") == today and st.get("status") in ["success", "already"]:
                return {
                    "today_checked": True,
                    "date": today,
                    "time": st.get("last_signin_time", ""),
                    "reward": st.get("reward", 100),
                    "badge_text": f"✔ 今日已签到 (+{st.get('reward', 100)}点)",
                    "badge_status": "ok",
                    "msg": st.get("message", "今日已签到")
                }
        except Exception:
            pass

    return {
        "today_checked": False,
        "date": today,
        "time": "",
        "reward": 0,
        "badge_text": "⚡ 今日未签到 (点此签到)",
        "badge_status": "warn",
        "msg": "今日尚未签到"
    }

def do_signin(force=False):
    """
    执行国内主号 (Target 1) 每日签到
    接口: POST https://www.codebuddy.cn/billing/meter/daily-checkin
    """
    today = get_today_str()
    now = get_now_str()

    if not force:
        cur = check_signin_today()
        if cur["today_checked"]:
            return {
                "success": True,
                "already": True,
                "reward": cur["reward"],
                "date": today,
                "time": cur["time"],
                "message": cur["msg"],
                "badge_text": cur["badge_text"]
            }

    token, nick = get_target1_token()
    if not token:
        err_msg = f"签到失败: 无法获取 Target 1 Token ({nick})"
        return {
            "success": False,
            "already": False,
            "reward": 0,
            "date": today,
            "time": now,
            "message": err_msg,
            "badge_text": "❌ 凭据缺失"
        }

    url = "https://www.codebuddy.cn/billing/meter/daily-checkin"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0",
        "Accept": "application/json"
    }

    opener = make_clean_opener()
    req = urllib.request.Request(url, data=b"{}", headers=headers)

    res_status = "fail"
    reward = 0
    msg = ""
    already = False

    try:
        with opener.open(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("code") == 0:
                reward = data.get("data", {}).get("credit", 100)
                msg = f"签到成功！获得 {reward} 积分"
                res_status = "success"
            else:
                msg = data.get("msg", "未知返回")
    except urllib.error.HTTPError as e:
        raw = e.read()
        err_txt = ""
        try:
            err_json = json.loads(raw.decode("utf-8"))
            err_txt = err_json.get("msg", "")
        except Exception:
            err_txt = raw.decode("utf-8", errors="ignore")

        if "今天已签到" in err_txt or "已签到" in err_txt or e.code == 400:
            already = True
            reward = 100
            res_status = "already"
            msg = "今天已签到，请明天再来"
        else:
            msg = f"HTTP {e.code}: {err_txt[:50]}"
    except Exception as e:
        msg = f"网络异常: {str(e)[:40]}"

    success = (res_status in ["success", "already"])

    # 持久化状态
    state_record = {
        "last_signin_date": today,
        "last_signin_time": now,
        "status": res_status,
        "reward": reward,
        "account": nick,
        "message": msg
    }
    try:
        with open(SIGNIN_STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state_record, f, ensure_ascii=False, indent=2)
    except Exception:
        pass

    # 追加历史日志
    try:
        with open(SIGNIN_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(state_record, ensure_ascii=False) + "\n")
    except Exception:
        pass

    badge_text = f"✔ 今日已签到 (+{reward}点)" if success else "❌ 签到失败"

    return {
        "success": success,
        "already": already,
        "reward": reward,
        "date": today,
        "time": now,
        "message": msg,
        "badge_text": badge_text
    }

# ==================== 6 通道矩阵巡检与积分刷新 ====================

def fetch_single_target_credits(tgt):
    tid = str(tgt.get("id"))
    label = tgt.get("label", f"Target {tid}")
    kind = tgt.get("kind", "web")
    domain = "www.codebuddy.cn" if tgt.get("site") == "cn" else "www.codebuddy.ai"

    # Target 6 商业 API：走主 Brave 脚本猫回传的实时额度；查不到就明确降级，不拿旧快照冒充实时值
    if kind == "api":
        ensure_bridge()
        snap_total = None
        snap_at = None
        snap_plan = ""
        snap_expire = ""
        snap_src = ""
        snap_age = None
        if os.path.exists(TARGET6_CREDITS_FILE):
            try:
                with open(TARGET6_CREDITS_FILE, "r", encoding="utf-8") as f:
                    cdata = json.load(f)
                snap_total = round(float(cdata.get("total_remain")), 2)
                snap_at = cdata.get("updated_at")
                snap_plan = cdata.get("plan", "")
                snap_expire = cdata.get("expire_time", "")
                snap_src = cdata.get("source", "")
                if snap_at:
                    try:
                        t = datetime.datetime.strptime(snap_at, "%Y-%m-%d %H:%M:%S")
                        snap_age = (datetime.datetime.now() - t).total_seconds() / 60.0
                    except Exception:
                        snap_age = None
            except Exception:
                pass

        # 主路径：脚本猫油猴脚本在 workbuddy.ai 页面里实时回传（source=userscript）
        if snap_src == "userscript" and snap_total is not None and snap_age is not None and snap_age <= 90:
            return {
                "id": tid,
                "label": label,
                "nickname": "-",
                "total_credits": snap_total,
                "base": round(float(cdata.get("base_remain") or 0.0), 2),
                "bonus": round(float(cdata.get("bonus_remain") or 0.0), 2),
                "detail": f"实时（{snap_plan or 'Pro'}）基础 {round(float(cdata.get('base_remain') or 0.0), 2)} + 赠送/奖励 {round(float(cdata.get('bonus_remain') or 0.0), 2)}",
                "status": "健康可用",
                "reset_time": f"{snap_age:.0f} 分钟前更新" + (f" · 到期 {snap_expire[:10]}" if snap_expire else ""),
                "kind": "api",
                "live": True,
            }

        # 备选：CDP 直连主 Brave（需 --remote-debugging-port）
        res = {"ok": False, "error": "未调用"}
        api_domain = tgt.get("api_domain") or "www.workbuddy.ai"
        try:
            if CB_LOGIN_DIR not in sys.path:
                sys.path.insert(0, CB_LOGIN_DIR)
            import cb_session
            res = cb_session.fetch_credits(api_domain)
        except Exception as e:
            res = {"ok": False, "error": f"cb_session 不可用: {type(e).__name__}"}

        expect_uid = str(tgt.get("api_uid") or "").lower()
        got_uid = str(res.get("uid") or "").lower()
        mismatch = bool(res.get("ok") and expect_uid and got_uid and not got_uid.startswith(expect_uid[:8]))

        if res.get("ok") and not mismatch:
            total_val = float(res["total"])
            base_val = float(res.get("base") or 0.0)
            bonus_val = float(res.get("bonus") or 0.0)
            now_str = get_now_str()
            try:
                with open(TARGET6_CREDITS_FILE, "w", encoding="utf-8") as f:
                    json.dump({
                        "updated_at": now_str,
                        "source": res.get("via") or "cdp",
                        "plan": res.get("plan") or snap_plan,
                        "expire_time": snap_expire,
                        "base_remain": base_val,
                        "bonus_remain": bonus_val,
                        "total_remain": total_val,
                    }, f, ensure_ascii=False, indent=2)
            except Exception:
                pass
            return {
                "id": tid,
                "label": label,
                "nickname": (got_uid[:8] if got_uid else "-"),
                "total_credits": total_val,
                "base": base_val,
                "bonus": bonus_val,
                "detail": f"实时 基础 {base_val} + 赠送/奖励 {bonus_val}",
                "status": "健康可用",
                "reset_time": f"正常可用 (Pro 到期 {snap_expire[:10]})" if snap_expire else "正常可用",
                "kind": "api",
                "live": True,
            }

        if mismatch:
            reason = f"登录态不是该 Key 的账号（当前 {got_uid[:8]}，应为 {expect_uid[:8]}）"
        elif snap_src == "userscript" and snap_age is not None:
            reason = f"脚本猫回传已 {snap_age/60:.1f} 小时未更新（打开一次 workbuddy.ai 页面即可）"
        else:
            reason = res.get("error") or "未知错误"

        return {
            "id": tid,
            "label": label,
            "nickname": "-",
            "total_credits": snap_total if snap_total is not None else 0.0,
            "base": 0.0,
            "bonus": 0.0,
            "detail": f"实时查询失败：{reason}" + (f"；显示 {snap_at} 快照" if snap_total is not None else ""),
            "status": "查询失败",
            "reset_time": "-",
            "kind": "api",
            "live": False,
        }


    token, nick = get_target_token(tgt)
    if not token:
        return {
            "id": tid,
            "label": label,
            "total_credits": 0.0,
            "base": 0.0,
            "bonus": 0.0,
            "detail": "凭据缺失",
            "status": "未登录",
            "reset_time": "-",
            "kind": kind
        }

    opener = make_clean_opener()
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "Mozilla/5.0",
        "Accept": "application/json"
    }

    total_credits = 0.0
    base_val = 0.0
    bonus_val = 0.0
    detail_str = "查询中"
    fetch_ok = False

    try:
        url = f"https://{domain}/billing/meter/get-user-resource-summary"
        req = urllib.request.Request(url, data=b"{}", headers=headers)
        with opener.open(req, timeout=6) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            s_data = data.get("data", {})
            raw_tot = s_data.get("TotalCredits")
            if raw_tot is not None:
                fetch_ok = True
                total_credits = round(float(raw_tot), 2)
                for g in s_data.get("CreditGroups", []):
                    rem = float(g.get("CycleRemainCapacity", 0) or 0)
                    if g.get("Kind") == "plan_base":
                        base_val += rem
                    else:
                        bonus_val += rem
                base_val = round(base_val, 2)
                bonus_val = round(bonus_val, 2)
                detail_str = f"基础 {base_val} + 赠送/奖励 {bonus_val}"
            else:
                detail_str = "响应缺少 TotalCredits"
    except Exception as e:
        detail_str = f"查询失败({str(e)[:30]})"

    # 429 冷静期状态判定；抓取失败必须降级，不能沿用「健康可用」掩盖
    in_cd, rem_sec, rstr = check_target_cooldown(tid)
    if not fetch_ok:
        status = "查询失败"
        reset_time = "-"
    elif in_cd:
        m = int(rem_sec // 60)
        s = int(rem_sec % 60)
        status = "429 限流中"
        reset_time = f"{rstr} (剩 {m}分{s}秒)"
    else:
        status = "健康可用"
        reset_time = "正常可用"

    return {
        "id": tid,
        "label": label,
        "nickname": nick,
        "total_credits": total_credits,
        "base": base_val,
        "bonus": bonus_val,
        "detail": detail_str,
        "status": status,
        "reset_time": reset_time,
        "kind": kind,
        "live": fetch_ok,
    }

def refresh_matrix(fast=True):
    """
    全量刷新 6 通道账号矩阵（支持多线程毫秒级并发查询）
    """
    now = get_now_str()
    targets = []
    if os.path.exists(PROFILES_FILE):
        try:
            with open(PROFILES_FILE, "r", encoding="utf-8") as f:
                pdata = json.load(f)
            targets = pdata.get("targets", [])
        except Exception:
            pass

    results = []
    total_matrix_credits = 0.0

    if targets:
        with ThreadPoolExecutor(max_workers=min(len(targets), 6)) as pool:
            futures = {pool.submit(fetch_single_target_credits, tgt): tgt for tgt in targets}
            for fut in as_completed(futures):
                try:
                    res = fut.result()
                    results.append(res)
                except Exception:
                    pass

    # 排序 Target 1..6
    results.sort(key=lambda x: str(x.get("id")))
    stale_credits = 0.0
    for r in results:
        if r.get("live", True):
            total_matrix_credits += float(r.get("total_credits", 0.0))
        else:
            stale_credits += float(r.get("total_credits", 0.0))

    total_matrix_credits = round(total_matrix_credits, 2)
    stale_credits = round(stale_credits, 2)

    matrix_data = {
        "updated_at": now,
        "total_credits": total_matrix_credits,
        "stale_credits": stale_credits,
        "live_targets": sum(1 for r in results if r.get("live", True)),
        "targets_count": len(results),
        "targets": results
    }

    # 同步追加到记录历史中
    try:
        with open(RECORDS_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "type": "matrix_refresh",
                "time": now,
                "total_credits": total_matrix_credits,
                "targets": [{t["id"]: t["total_credits"], "status": t["status"]} for t in results]
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass

    # 尝试同步最新状态至 CREDIT_STATUS.md
    try:
        generate_credit_status_md(matrix_data)
    except Exception:
        pass

    return matrix_data

def generate_credit_status_md(matrix_data):
    now = matrix_data["updated_at"]
    total = matrix_data["total_credits"]
    targets = matrix_data.get("targets", [])

    lines = [
        "# CodeBuddy 多账号矩阵实时监控看板",
        "",
        f"> **最后巡检时间**：`{now}`  ",
        "> **更新机制**：自动化巡检脚本直连官方 API 极速聚合生成  ",
        "> **保护机制**：429 状态已自动持久化登记至 `matrix_cooldown.json`，在恢复前自动拦截保护",
        "",
        "---",
        "",
        "### 账号状态、积分与 429 恢复时刻表",
        "",
        "| 通道编号 | 通道名称 | 账号昵称 | 当前状态 | 剩余可用积分 | 429 刷新解封时间 |",
        "| :---: | :--- | :---: | :---: | :---: | :---: |"
    ]

    for t in targets:
        mark = "" if t.get("live", True) else " ⚠️陈旧"
        lines.append(f"| **Target {t['id']}** | {t['label']} | `{t.get('nickname', '-')}` | [{t['status']}]{mark} | `{t['total_credits']} 点 ({t.get('detail', '-')})` | `{t.get('reset_time', '正常可用')}` |")

    stale = matrix_data.get("stale_credits", 0.0)
    live_n = matrix_data.get("live_targets", len(targets))
    lines.extend([
        "",
        "---",
        "",
        f"**矩阵实时可用总储备**：`{total} 点`（{live_n}/{len(targets)} 通道实时查询成功）  ",
    ])
    if stale:
        lines.append(f"另有 `{stale} 点` 为失败通道的陈旧快照，**未计入**上面的总储备。  ")
    lines.append("（按 DeepSeek-V4.1-Flash x0.00 免费 / Flash-SG x0.03 倍率计算）")
    lines.append("")

    content = "\n".join(lines)
    for p in [STATUS_MD_SRC, STATUS_MD_LOCAL]:
        try:
            with open(p, "w", encoding="utf-8") as f:
                f.write(content)
        except Exception:
            pass

# ==================== 记录读取与聚合 ====================

def get_records_summary(limit=10):
    """
    聚合所有历史记录：签到历史、巡检历史、429冷却历史、会话扫描记录
    """
    # 1. 签到历史
    signin_items = []
    if os.path.exists(SIGNIN_LOG_FILE):
        try:
            with open(SIGNIN_LOG_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        signin_items.append(json.loads(line.strip()))
        except Exception:
            pass
    signin_items.reverse()

    # 2. 矩阵巡检历史
    matrix_items = []
    if os.path.exists(RECORDS_LOG_FILE):
        try:
            with open(RECORDS_LOG_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        matrix_items.append(json.loads(line.strip()))
        except Exception:
            pass
    matrix_items.reverse()

    # 3. 429 冷静历史
    cooldown_info = {}
    if os.path.exists(COOLDOWN_FILE):
        try:
            with open(COOLDOWN_FILE, "r", encoding="utf-8") as f:
                cooldown_info = json.load(f)
        except Exception:
            pass

    # 4. 会话扫描记录
    scan_items = []
    if os.path.exists(SCAN_LOG_FILE):
        try:
            with open(SCAN_LOG_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    if line.strip():
                        scan_items.append(json.loads(line.strip()))
        except Exception:
            pass
    scan_items.reverse()

    return {
        "signin_history": signin_items[:limit],
        "matrix_history": matrix_items[:limit],
        "cooldown_data": cooldown_info,
        "scan_history": scan_items[:limit]
    }

def append_scan_record(meta, today_tokens, today_cost, today_credits):
    rec = {
        "time": get_now_str(),
        "date": get_today_str(),
        "new_records": meta.get("new_records", 0),
        "scan_ms": meta.get("scan_ms", 0),
        "scanned_mb": meta.get("scanned_mb", 0.0),
        "files": meta.get("files", 0),
        "requests": meta.get("requests", 0),
        "today_tokens": today_tokens,
        "today_cost": today_cost,
        "today_credits": today_credits
    }
    try:
        with open(SCAN_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass

if __name__ == "__main__":
    if "--signin" in sys.argv:
        res = do_signin(force=("--force" in sys.argv))
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif "--check-signin" in sys.argv:
        res = check_signin_today()
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif "--matrix" in sys.argv:
        res = refresh_matrix()
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif "--records" in sys.argv:
        res = get_records_summary()
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        print("ttk_service.py: use --signin, --check-signin, --matrix, or --records")
