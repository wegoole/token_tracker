# -*- coding: utf-8 -*-
"""ttk.py - CodeBuddy token 用量记录器

扫描 CodeBuddy CLI 的会话记录（默认 ~/.codebuddy-cli/projects 下的 jsonl；
可用 --projects 参数或环境变量 TTK_PROJECTS 覆盖数据目录），
按 天 / 调用方式(终端, 弹窗) / 模型 聚合 token，并按各模型的输入/输出单价估算花销。

调用方式说明：终端 = Windows Terminal 交互会话；弹窗 = WinForms 弹窗驱动的
headless 会话。两者是同一工具的两种调用方式，共写同一个 projects 目录
（按 sessionId 前缀 ccb- 区分）。

用法:
  py -3.11 ttk.py                 # 增量扫描 + 生成 ttk.report.json（默认 7 天）
  py -3.11 ttk.py --days 14
  py -3.11 ttk.py --projects PATH # 指定数据目录（等同 TTK_PROJECTS 环境变量）
  py -3.11 ttk.py --refresh       # 丢弃缓存，全量重扫
  py -3.11 ttk.py --update-prices # 从 DeepSeek 官方价格页抓价
  py -3.11 ttk.py --json          # 同时把报告打到 stdout
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

try:
    from ttk_service import check_signin_today, do_signin, refresh_matrix, get_records_summary, append_scan_record
except ImportError:
    try:
        import ttk_service
        check_signin_today = ttk_service.check_signin_today
        do_signin = ttk_service.do_signin
        refresh_matrix = ttk_service.refresh_matrix
        get_records_summary = ttk_service.get_records_summary
        append_scan_record = ttk_service.append_scan_record
    except Exception:
        check_signin_today = None
        do_signin = None
        refresh_matrix = None
        get_records_summary = None
        append_scan_record = None

BASE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROJECTS = os.path.join(os.path.expanduser('~'), '.codebuddy-cli', 'projects')
CACHE = os.path.join(BASE, 'ttk.cache.json')
PRICES = os.path.join(BASE, 'prices.json')
REPORT = os.path.join(BASE, 'ttk.report.json')
MEMBERSHIP = os.path.join(BASE, 'membership.json')
TZ = datetime.timezone(datetime.timedelta(hours=8))
WEEK = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']

DEFAULT_PRICES = {
    "currency": "CNY",
    "unit": "per_1m_tokens",
    "source": "各厂商官网刊例价（list price）；美元价 ×7.15；核对 2026-10-31",
    "pricing_basis": (
        "统一口径：一律取厂商官网「刊例价」，不采用限时折扣/活动价/中转站转售价。"
        "人民币官网价直接填，美元官网价 ×7.15。"
        "官网未公布缓存价时：缓存命中 = 输入价 ×10%，缓存写入 = 未命中输入价。"
        "DeepSeek 保留高峰/空闲双档，按请求时间戳判定。"
    ),
    "fetched_at": "2026-10-17",
    "peak": {"ranges": [[9, 12], [14, 18]], "holidays": []},
    "models": {
        "deepseek-flash": {
            "aliases": ["deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4.1-flash-sg",
                        "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"],
            "hit": {"peak": 0.04, "off": 0.02},
            "miss": {"peak": 2.0, "off": 1.0},
            "out": {"peak": 8.0, "off": 4.0},
            "source": "DeepSeek 官网刊例价（高峰/空闲双档）",
        },
        "deepseek-v4-pro": {
            "aliases": ["deepseek-v4-pro"],
            "hit": {"peak": 0.30, "off": 0.15},
            "miss": {"peak": 9.0, "off": 4.5},
            "out": {"peak": 27.0, "off": 13.5},
            "source": "DeepSeek 官网刊例价（高峰/空闲双档）",
        },
        "hy3": {
            "aliases": ["hy3"],
            "hit": {"peak": 0.25, "off": 0.25},
            "miss": {"peak": 1.0, "off": 1.0},
            "out": {"peak": 4.0, "off": 4.0},
            "source": "腾讯云 TokenHub 官网刊例价",
        },
        "hy4-preview": {
            "aliases": ["hy4-preview"],
            "hit": {"peak": 0.3, "off": 0.3},
            "miss": {"peak": 6.0, "off": 6.0},
            "out": {"peak": 18.0, "off": 18.0},
            "source": "腾讯云 TokenHub 官网刊例价",
        },
        "minimax-m3.1-flash": {
            "aliases": ["minimax-m3.1-flash", "space-bunny"],
            "hit": {"peak": 0.1, "off": 0.1},
            "miss": {"peak": 1.0, "off": 1.0},
            "out": {"peak": 4.0, "off": 4.0},
            "source": "MiniMax 官网刊例价（space-bunny 为同模型早期别名）",
        },
        "glm-5.3-flash": {
            "aliases": ["glm-5.3-flash"],
            "hit": {"peak": 0.23, "off": 0.23},
            "miss": {"peak": 0.8, "off": 0.8},
            "out": {"peak": 2.8, "off": 2.8},
            "source": "智谱官网刊例价（限时五折档 0.4/0.115/1.4 未采用）",
        },
        "step-5-preview": {
            "aliases": ["step-5-preview"],
            "hit": {"peak": 0.7, "off": 0.7},
            "miss": {"peak": 7.0, "off": 7.0},
            "out": {"peak": 20.0, "off": 20.0},
            "source": "阶跃星辰官网刊例价（缓存命中 2026-10-14 起 0.70）",
        },
        "kimi-k3.1-pro": {
            "aliases": ["kimi-k3.1-pro"],
            "hit": {"peak": 1.3, "off": 1.3},
            "miss": {"peak": 13.0, "off": 13.0},
            "write": {"peak": 13.0, "off": 13.0},
            "out": {"peak": 68.0, "off": 68.0},
            "source": "Kimi 官网刊例价",
        },
        "kimi-k3": {
            "aliases": ["kimi-k3"],
            "hit": {"peak": 2.0, "off": 2.0},
            "miss": {"peak": 20.0, "off": 20.0},
            "write": {"peak": 20.0, "off": 20.0},
            "out": {"peak": 100.0, "off": 100.0},
            "source": "Kimi 官网刊例价（缓存写入取 5min TTL 档）",
        },
        "gpt-6-luna": {
            "aliases": ["gpt-6-luna"],
            "hit": {"peak": 0.0715, "off": 0.0715},
            "miss": {"peak": 0.715, "off": 0.715},
            "write": {"peak": 0.715, "off": 0.715},
            "out": {"peak": 3.575, "off": 3.575},
            "source": "OpenAI 官网刊例价 $0.10/$0.50 ×7.15（缓存命中未公布，按输入 10% 估）",
        },
        "gpt-6.1-sol": {
            "aliases": ["gpt-6.1-sol"],
            "hit": {"peak": 0.715, "off": 0.715},
            "miss": {"peak": 14.3, "off": 14.3},
            "write": {"peak": 14.3, "off": 14.3},
            "out": {"peak": 71.5, "off": 71.5},
            "source": "OpenAI 官网刊例价 $2/$0.10/$10 ×7.15",
        },
    },
}

DEFAULT_MEMBERSHIP = {
    "plan": "WorkBuddy Pro",
    "currency": "USD",
    "monthly_fee_usd": 7.0,
    "usd_cny": 6.714,
    "note": "会员按月付费；API 价值按各模型 Token 单价估算，不含积分",
}

BUCKETS = ('hit_peak', 'hit_off', 'miss_peak', 'miss_off',
           'write_peak', 'write_off', 'out_peak', 'out_off')

# 免费/受限模型分组（按 requestModelId 判定）。429 额度池在渠道级：
# ds 与混元3（网关 id "hy3"）**共用一个池**（2026-10-24 确认，实证：10-21
# 混元单日 11 次 429 而 ds 用量仅 3.24亿），合并归组到 ds；step 独立。
# hunyuan3 在网关的模型 id 是 "hy3"（不含 hunyuan 子串），必须显式列入。
FREE_GROUPS = [
    ('ds', ('deepseek', 'hunyuan', 'hy3')),
    ('step', ('step',)),
]


def group_of(model):
    ml = (model or '').lower()
    for g, keys in FREE_GROUPS:
        for k in keys:
            if k in ml:
                return g
    return None


# 免费模型「日用量上限」预估阈值（重负载日的量级，非硬上限）。
# 429 是短时间 burst 触顶（回补速率桶），ttk 只有日聚合、量不到 burst，
# 故 warn 用「日累计接近预估上限」；danger 为当日已出现 >=1 次 429（硬性信号）。
# 阈值与 warn_ratio 均可在 limits.json 覆盖，此处仅为文件缺失时的兜底。
DEFAULT_LIMITS = {
    'ds':       {'req': 1950, 'tokens': 300_000_000,
                 'note': 'ds+混元3 共用池（10-24 合并口径）：10-22/23/24 连续三天 ~1.9k 请求 / ~2.9亿 token 就触 429，上限取触限日水平；warn=80%×阈值'},
    'step':     {'req': 900, 'tokens': 130_000_000,
                 'note': '10-25 首次实测触限（811req / 1.25亿 吃 429，reset 16:13）；10-24 1437req / 1.73亿 未触限，故上限取触限日量 900req / 1.3亿，warn≈720req / 1.04亿'},
}
DEFAULT_WARN_RATIO = 0.8


def load_limits():
    """读 limits.json：返回 (各渠道阈值 dict, warn_ratio)。文件缺失/损坏用兜底值。"""
    cfg = {k: dict(v) for k, v in DEFAULT_LIMITS.items()}
    ratio = DEFAULT_WARN_RATIO
    p = os.path.join(BASE, 'limits.json')
    try:
        with open(p, encoding='utf-8-sig') as f:
            user = json.load(f)
        for k, v in (user or {}).items():
            if k == 'warn_ratio':
                try:
                    r = float(v)
                    if 0 < r <= 1:
                        ratio = r
                except (TypeError, ValueError):
                    pass
            elif k in cfg and isinstance(v, dict):
                cfg[k].update(v)
    except Exception:
        pass
    return cfg, ratio


def compute_warnings(today, limits, warn_ratio=DEFAULT_WARN_RATIO, cooldowns=None):
    ratio = float(warn_ratio)
    cd = {c['group']: c for c in (cooldowns or [])}
    fm = {f['group']: f for f in (today.get('free_models') or [])}
    err = today.get('errors') or {'total': 0, 'by_model': {}}
    err_bg = {}
    for m, n in (err.get('by_model') or {}).items():
        g = group_of(m) or 'other'
        err_bg[g] = err_bg.get(g, 0) + n
    out = []
    level = 0
    for g, spec in limits.items():
        f = fm.get(g) or {'req': 0, 'tokens': 0, 'err429': 0}
        req = f['req']
        tok = f['tokens']
        e429 = err_bg.get(g, 0)
        if e429 > 0:
            lvl = 2
        elif req >= spec['req'] * ratio or tok >= spec['tokens'] * ratio:
            lvl = 1
        else:
            lvl = 0
        level = max(level, lvl)
        c = cd.get(g) or {}
        out.append({'group': g, 'level': lvl, 'req': req, 'tokens': tok,
                    'threshold_req': spec['req'], 'threshold_tokens': spec['tokens'],
                    'err429': e429, 'warn_ratio': ratio, 'note': spec.get('note', ''),
                    'model': c.get('model'), 'model_label': c.get('model_label'),
                    'reset_at': c.get('reset_at'),
                    'remain': c.get('remain'),
                    'cooldown': bool(c.get('active')),
                    'advice': c.get('advice')})
    return out, level


def fmt_tok(n):
    n = float(n)
    if n >= 1e8:
        return '%.2f亿' % (n / 1e8)
    if n >= 1e4:
        return '%.1f万' % (n / 1e4)
    return str(int(n))


def load_json(path, default):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, obj, compact=False):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        if compact:
            json.dump(obj, f, ensure_ascii=False, separators=(',', ':'))
        else:
            json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def zero_bucket():
    return {k: 0 for k in BUCKETS} | {'req': 0}


def day_skeleton():
    return {'terminal': zero_bucket(), 'popup': zero_bucket(), 'models': {}}


def is_peak(dt, prices):
    if dt.weekday() >= 5:
        return False
    if dt.strftime('%Y-%m-%d') in set(prices.get('peak', {}).get('holidays') or []):
        return False
    for start, end in prices.get('peak', {}).get('ranges') or [[9, 12], [14, 18]]:
        if start <= dt.hour < end:
            return True
    return False


def alias_map(prices):
    m = {}
    for name, spec in (prices.get('models') or {}).items():
        for a in [name] + list(spec.get('aliases') or []):
            m[a] = name
    return m


def fetch_prices(timeout=8):
    """从 DeepSeek 官方价格页解析 CNY 峰谷价，失败抛异常。"""
    url = 'https://api-docs.deepseek.com/zh-cn/quick_start/pricing'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    html = urllib.request.urlopen(req, timeout=timeout).read().decode('utf-8', 'ignore')
    start = html.find('百万tokens输入')
    end = html.find('并发限制', start)
    if start < 0 or end < 0:
        raise ValueError('价格表定位失败')
    start = html.rfind('<tr', 0, start)          # 补回被切断的表头行
    seg = html[start:end]
    rows = re.findall(r'<tr[^>]*>(.*?)</tr>', seg, re.S)
    found = {}
    cur = None
    for row in rows:
        cells = [re.sub(r'<[^>]+>', '', c).replace('\u00a0', ' ').strip()
                 for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.S)]
        for i, c in enumerate(cells):
            if '缓存命中' in c:
                cur = 'hit'
            elif '缓存未命中' in c:
                cur = 'miss'
            elif '百万tokens输出' in c:
                cur = 'out'
            if c.startswith('空闲') or c.startswith('高峰'):
                mode = 'off' if c.startswith('空闲') else 'peak'
                nums = []
                for v in cells[i + 1:]:
                    mm = re.search(r'([0-9]+(?:\.[0-9]+)?)\s*元', v)
                    if mm:
                        nums.append(float(mm.group(1)))
                if cur and len(nums) >= 2:
                    found.setdefault(cur, {})[mode] = (nums[0], nums[1])
    need = [('hit', 'off'), ('hit', 'peak'), ('miss', 'off'), ('miss', 'peak'),
            ('out', 'off'), ('out', 'peak')]
    for k, mode in need:
        if k not in found or mode not in found[k]:
            raise ValueError('价格解析不完整: %s/%s' % (k, mode))
    models = {
        'deepseek-flash': {
            'aliases': DEFAULT_PRICES['models']['deepseek-flash']['aliases'],
            'hit': {'peak': found['hit']['peak'][0], 'off': found['hit']['off'][0]},
            'miss': {'peak': found['miss']['peak'][0], 'off': found['miss']['off'][0]},
            'out': {'peak': found['out']['peak'][0], 'off': found['out']['off'][0]},
            'source': 'DeepSeek 官方峰谷价',
        },
        'deepseek-v4-pro': {
            'aliases': ['deepseek-v4-pro'],
            'hit': {'peak': found['hit']['peak'][1], 'off': found['hit']['off'][1]},
            'miss': {'peak': found['miss']['peak'][1], 'off': found['miss']['off'][1]},
            'out': {'peak': found['out']['peak'][1], 'off': found['out']['off'][1]},
            'source': 'DeepSeek 官方峰谷价',
        },
    }
    return models


def ensure_prices(update=False):
    prices = load_json(PRICES, None) or json.loads(json.dumps(DEFAULT_PRICES))
    today = datetime.datetime.now(TZ).date()
    need = bool(update)
    if not need and prices.get('models'):
        try:
            age = (today - datetime.date.fromisoformat(prices.get('fetched_at', ''))).days
            last = prices.get('last_check')
            last_age = (today - datetime.date.fromisoformat(last)).days if last else 99
            need = age >= 7 and last_age >= 1
        except Exception:
            need = True
    if need:
        try:
            # 只刷新 DeepSeek，保留其它模型的公开价/中转站参考价。
            prices.setdefault('models', {}).update(fetch_prices())
            prices['fetched_at'] = today.strftime('%Y-%m-%d')
            print('[ttk] 价格已更新: %s' % prices['fetched_at'], file=sys.stderr)
        except Exception as e:
            if update:
                print('[ttk] 抓价失败，沿用本地价格: %s' % e, file=sys.stderr)
        prices['last_check'] = today.strftime('%Y-%m-%d')
        save_json(PRICES, prices)
    elif not os.path.exists(PRICES):
        save_json(PRICES, prices)
    return prices


def parse_usage_line(o, prices, aliases, seen):
    pd = o.get('providerData') or {}
    ru = pd.get('rawUsage')
    if not ru:
        return None
    mid = pd.get('messageId') or o.get('id')
    if not mid:
        return None
    h = hashlib.md5(str(mid).encode('utf-8')).hexdigest()[:12]
    if h in seen:
        return None
    seen[h] = 1
    ts = o.get('timestamp')
    if not ts:
        return None
    try:
        dt = datetime.datetime.fromtimestamp(ts / 1000.0, TZ)
    except Exception:
        return None
    prompt = int(ru.get('prompt_tokens') or 0)
    hit = int(ru.get('prompt_cache_hit_tokens') or 0)
    write = int(ru.get('prompt_cache_write_tokens') or 0)
    # 部分网关把 cache write 排除在 prompt_cache_miss_tokens 外；直接用总输入
    # 反推未命中，保证 hit + miss + write == prompt_tokens，不漏计上行。
    miss = max(prompt - hit - write, 0)
    out = int(ru.get('completion_tokens') or 0)
    credit = float(ru.get('credit') or 0)
    model = pd.get('requestModelId') or pd.get('model') or 'unknown'
    sid = str(o.get('sessionId') or '')
    client = 'popup' if sid.startswith('ccb-') else 'terminal'
    peak = is_peak(dt, prices)
    b = ('peak' if peak else 'off')
    return {
        'date': dt.strftime('%Y-%m-%d'),
        'weekday': WEEK[dt.weekday()],
        'client': client,
        'model': model,
        'hit': hit, 'miss': miss, 'write': write, 'out': out, 'credit': credit,
        'hit_key': 'hit_' + b, 'miss_key': 'miss_' + b,
        'write_key': 'write_' + b, 'out_key': 'out_' + b,
        'priced': model in aliases,
    }


RESET_RE = re.compile(r'reset at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')


def _err_text(o, err):
    """把 429 的可读正文拼出来（message 优先，其次 content）。"""
    txt = ''
    if isinstance(err, dict):
        txt = str(err.get('message') or '')
    c = o.get('content')
    if isinstance(c, list):
        for x in c:
            if isinstance(x, dict):
                txt += str(x.get('text') or '')
    elif isinstance(c, str):
        txt += c
    return txt


def parse_reset_at(txt):
    """从 429 正文里抠出官方给的重置时刻（本地时区字符串，不带 tz 后缀）。

    网关原文：`429 usage exceeds frequency limit, ... your usage will reset at
    2026-10-25 16:13:22 UTC+8, alternatively, you can switch to the other models`
    """
    m = RESET_RE.search(txt or '')
    if not m:
        return None
    try:
        return datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')
    except ValueError:
        return None


def count_429(o, days, seen, last_model):
    """累计 429 限流事件。429 行本身不带模型 id，用同文件最近的请求模型反推。

    返回归因到的模型（便于调用方更新 last_model，虽然 429 不会更新）。
    """
    pd = o.get('providerData') or {}
    err = pd.get('error') or {}
    is429 = err.get('status') == 429
    txt = ''
    if not is429:
        # 兜底：assistant 失败且正文以 429 开头
        c = o.get('content')
        txt = ''
        if isinstance(c, list):
            for x in c:
                if isinstance(x, dict):
                    txt += x.get('text', '')
        elif isinstance(c, str):
            txt = c
        if not (o.get('status') == 'incomplete' and txt.strip().startswith('429')):
            return None
    else:
        txt = _err_text(o, err)
    mid = o.get('id')
    if not mid:
        return None
    h = hashlib.md5(str(mid).encode('utf-8')).hexdigest()[:12]
    if h in seen:
        return None
    seen[h] = 1
    ts = o.get('timestamp')
    if not ts:
        return None
    try:
        dt = datetime.datetime.fromtimestamp(ts / 1000.0, TZ)
    except Exception:
        return None
    date = dt.strftime('%Y-%m-%d')
    model = last_model or 'unknown'
    d = days.setdefault(date, day_skeleton())
    e = d.setdefault('errors', {'total': 0, 'by_model': {}})
    e['total'] += 1
    e['by_model'][model] = e['by_model'].get(model, 0) + 1
    # 事件明细：网关会给出确切的重置时刻，留着才能算「还要等多久」
    reset = parse_reset_at(txt)
    ev = e.setdefault('events', [])
    ev.append({'at': dt.strftime('%Y-%m-%d %H:%M:%S'),
               'model': model,
               'reset_at': reset.strftime('%Y-%m-%d %H:%M:%S') if reset else None})
    if len(ev) > 200:          # 防缓存膨胀，只留最近的
        del ev[:-200]
    return model


def add_record(days, rec):
    d = days.setdefault(rec['date'], day_skeleton())
    bucket = d[rec['client']]
    bucket[rec['hit_key']] += rec['hit']
    bucket[rec['miss_key']] += rec['miss']
    bucket[rec['write_key']] += rec['write']
    bucket[rec['out_key']] += rec['out']
    bucket['req'] += 1
    m = d['models'].setdefault(rec['model'], zero_bucket() | {'credit': 0.0})
    m[rec['hit_key']] += rec['hit']
    m[rec['miss_key']] += rec['miss']
    m[rec['write_key']] += rec['write']
    m[rec['out_key']] += rec['out']
    m['req'] += 1
    m['credit'] += rec['credit']


def model_cost_breakdown(bucket, spec):
    """返回可复算的逐项计价明细；价格单位均为 CNY / 百万 Token。"""
    rows = []
    if not spec:
        return rows
    for field in ('hit', 'miss', 'write', 'out'):
        # 未单列缓存写入价的模型，写入按普通输入价估算。
        price = spec.get(field)
        if field == 'write' and not price:
            price = spec.get('miss')
        if not price:
            continue
        peak_tokens = bucket.get(field + '_peak', 0)
        off_tokens = bucket.get(field + '_off', 0)
        peak_cost = peak_tokens * price['peak'] / 1e6
        off_cost = off_tokens * price['off'] / 1e6
        rows.append({
            'kind': field,
            'tokens': peak_tokens + off_tokens,
            'peak_tokens': peak_tokens,
            'off_tokens': off_tokens,
            'peak_price': price['peak'],
            'off_price': price['off'],
            'peak_cost': peak_cost,
            'off_cost': off_cost,
            'cost': peak_cost + off_cost,
        })
    return rows


def model_cost(bucket, spec):
    return sum(row['cost'] for row in model_cost_breakdown(bucket, spec))


def load_membership():
    m = dict(DEFAULT_MEMBERSHIP)
    m.update(load_json(MEMBERSHIP, {}) or {})
    return m


def fee_usd_for(memb, day):
    """返回 day 当天适用的月费（美元）。"""
    return float(memb.get('monthly_fee_usd') or 0)


def day_cost(d, prices, aliases):
    total = 0.0
    for name, b in (d.get('models') or {}).items():
        total += model_cost(b, prices['models'].get(aliases.get(name, '')))
    return total


def bucket_view(b):
    hit = b.get('hit_peak', 0) + b.get('hit_off', 0)
    miss = b.get('miss_peak', 0) + b.get('miss_off', 0)
    write = b.get('write_peak', 0) + b.get('write_off', 0)
    out = b.get('out_peak', 0) + b.get('out_off', 0)
    return {'in': hit + miss + write, 'hit': hit, 'miss': miss,
            'write': write, 'out': out,
            'tokens': hit + miss + write + out, 'req': b['req']}


def projects_dir(override=None):
    """数据源目录优先级：显式参数 > 环境变量 TTK_PROJECTS > 默认路径。"""
    for cand in (override, os.environ.get('TTK_PROJECTS', '').strip()):
        if cand:
            return os.path.abspath(os.path.expanduser(cand))
    return DEFAULT_PROJECTS


def migrate_state(state):
    """兼容旧缓存的客户端键与新增 token 分项。"""
    for d in (state.get('days') or {}).values():
        for old, new in (('cb', 'terminal'), ('ccb', 'popup')):
            if old in d:
                d.setdefault(new, d.pop(old))
        buckets = [d.get('terminal', {}), d.get('popup', {})]
        buckets += list((d.get('models') or {}).values())
        for bucket in buckets:
            for key in BUCKETS:
                bucket.setdefault(key, 0)
    return state


def pretty_model(mid):
    """模型 id → 官方展示名：step-5-preview → Step-5-Preview（对齐客户端文案）。"""
    if not mid:
        return ''
    return '-'.join(p[:1].upper() + p[1:] for p in str(mid).split('-'))


def fmt_remain(sec):
    """秒 → '5h02m' / '48m'，用于冷却倒计时。"""
    sec = int(max(0, sec))
    h, m = divmod(sec // 60, 60)
    if h:
        return '%dh%02dm' % (h, m)
    return '%dm' % m


def build_cooldowns(out_days, now):
    """按渠道汇总最近一次 429 与官方重置时刻 → 冷却倒计时。

    网关 429 正文带 `your usage will reset at YYYY-MM-DD HH:MM:SS UTC+8`，
    直接用它算「还剩多久恢复」，比只知道「今天触发过」有用得多。
    """
    latest = {}
    for od in out_days:
        for ev in ((od.get('errors') or {}).get('events') or []):
            g = group_of(ev.get('model')) or 'other'
            prev = latest.get(g)
            if not prev or ev['at'] > prev['at']:
                latest[g] = ev
    out = []
    for g, ev in latest.items():
        reset = ev.get('reset_at')
        remain = None
        active = False
        if reset:
            try:
                rt = datetime.datetime.strptime(reset, '%Y-%m-%d %H:%M:%S').replace(tzinfo=TZ)
                remain = int((rt - now).total_seconds())
                active = remain > 0
            except ValueError:
                reset = None
        if active:
            others = [x for x, _ in FREE_GROUPS if x != g]
            advice = ('先切 %s 继续' % '/'.join(others)) if others else '先歇一会'
        else:
            advice = None
        out.append({'group': g, 'model': ev.get('model'),
                    'model_label': pretty_model(ev.get('model')),
                    'last429_at': ev['at'], 'reset_at': reset,
                    'remain_sec': remain if active else 0,
                    'remain': fmt_remain(remain) if active else None,
                    'active': active, 'advice': advice})
    out.sort(key=lambda x: (not x['active'], x['group']))
    return out


def build_report(days, prices, span, meta):
    aliases = alias_map(prices)
    now = datetime.datetime.now(TZ)
    today = now.date()
    out_days = []
    for i in range(span - 1, -1, -1):
        dt = today - datetime.timedelta(days=i)
        key = dt.strftime('%Y-%m-%d')
        d = days.get(key) or day_skeleton()
        terminal = bucket_view(d['terminal'])
        popup = bucket_view(d['popup'])
        models = []
        cost = 0.0
        credits = 0.0
        unpriced_models = []
        credit_unit_price = float(prices.get('credit_cny') or 0.05)
        for name, b in d['models'].items():
            spec = prices['models'].get(aliases.get(name, ''))
            c = model_cost(b, spec)
            v = bucket_view(b)
            cost += c
            credits += b.get('credit', 0.0)
            if not spec and v['tokens']:
                unpriced_models.append(name)
            models.append({'id': name, 'req': b['req'], 'tokens': v['tokens'],
                           'in': v['in'], 'hit': v['hit'], 'miss': v['miss'],
                           'write': v['write'], 'out': v['out'], 'cost': round(c, 4),
                           'priced': bool(spec),
                           'price_unit': 'CNY_per_1m_tokens',
                           'price_source': (spec or {}).get('source'),
                           'breakdown': model_cost_breakdown(b, spec),
                           'credit': b.get('credit', 0.0)})
        models.sort(key=lambda x: (-x['tokens'], x['id']))
        token_cost = round(cost, 4)
        credit_cost = round(credits * credit_unit_price, 4)
        total_cost = token_cost
        out_days.append({
            'date': key, 'weekday': WEEK[dt.weekday()],
            'terminal': terminal, 'popup': popup,
            'in': terminal['in'] + popup['in'],
            'hit': terminal['hit'] + popup['hit'],
            'miss': terminal['miss'] + popup['miss'],
            'write': terminal['write'] + popup['write'],
            'out': terminal['out'] + popup['out'],
            'tokens': terminal['tokens'] + popup['tokens'],
            'req': terminal['req'] + popup['req'],
            'token_cost': token_cost,
            'credit_cost': credit_cost,
            'cost': total_cost,
            'credits': round(credits, 2),
            'unpriced_models': sorted(unpriced_models),
            'models': models,
        })
    # 免费/受限模型用量 + 渠道级 429 关联
    for od in out_days:
        d = days.get(od['date']) or day_skeleton()
        err = d.get('errors') or {'total': 0, 'by_model': {}}
        od['errors'] = {'total': err['total'], 'by_model': dict(err.get('by_model', {})),
                        'events': list(err.get('events') or [])}
        free = []
        for g, keys in FREE_GROUPS:
            req = 0
            tok = 0
            e429 = 0
            for name, b in (d.get('models') or {}).items():
                nl = name.lower()
                if any(k in nl for k in keys):
                    req += b['req']
                    tok += (b.get('hit_peak', 0) + b.get('hit_off', 0)
                            + b.get('miss_peak', 0) + b.get('miss_off', 0)
                            + b.get('write_peak', 0) + b.get('write_off', 0)
                            + b.get('out_peak', 0) + b.get('out_off', 0))
                    e429 += err.get('by_model', {}).get(name, 0)
            free.append({'group': g, 'req': req, 'tokens': tok, 'err429': e429})
        od['free_models'] = free

    memb = load_membership()
    month_key = today.strftime('%Y-%m')
    m_cost = 0.0
    m_req = 0
    m_tokens = 0
    m_days = 0
    for key, d in days.items():
        if not key.startswith(month_key):
            continue
        m_cost += day_cost(d, prices, aliases)
        v = bucket_view(d['terminal'])
        w = bucket_view(d['popup'])
        m_req += v['req'] + w['req']
        m_tokens += v['tokens'] + w['tokens']
        m_days += 1
    usd_cny = float(memb.get('usd_cny') or 6.714)
    fee_usd = fee_usd_for(memb, today)
    fee_cny = fee_usd * usd_cny
    membership = {
        'plan': memb.get('plan') or 'WorkBuddy Pro',
        'month': month_key,
        'usd_cny': round(usd_cny, 3),
        'fee_usd': round(fee_usd, 2),
        'fee_cny': round(fee_cny, 2),
        'api_cost': round(m_cost, 2),
        'saved': round(m_cost - fee_cny, 2),
        'multiple': round(m_cost / fee_cny, 2) if fee_cny else 0.0,
        'month_tokens': m_tokens,
        'month_req': m_req,
        'month_days': m_days,
        'note': memb.get('note'),
    }
    credit_unit_price = float(prices.get('credit_cny') or 0.05)
    tot_credits = sum(d['credits'] for d in out_days)
    tot_token_cost = sum(d.get('token_cost', d['cost']) for d in out_days)
    tot_credit_cost = round(tot_credits * credit_unit_price, 4)
    tot_cost = round(tot_token_cost, 4)

    totals = {
        'days': span,
        'tokens': sum(d['tokens'] for d in out_days),
        'token_cost': round(tot_token_cost, 4),
        'credit_cost': tot_credit_cost,
        'cost': tot_cost,
        'credits': round(tot_credits, 2),
        'credit_unit_price': credit_unit_price,
        'req': sum(d['req'] for d in out_days),
        'terminal_tokens': sum(d['terminal']['tokens'] for d in out_days),
        'popup_tokens': sum(d['popup']['tokens'] for d in out_days),
        'err429': sum(d['errors']['total'] for d in out_days),
        'unpriced_models': sorted({m for d in out_days for m in d.get('unpriced_models', [])}),
    }
    rate_limit = {'total': 0, 'by_model': {}, 'by_group': {}}
    for od in out_days:
        e = od.get('errors') or {'total': 0, 'by_model': {}}
        rate_limit['total'] += e['total']
        for m, n in (e.get('by_model') or {}).items():
            rate_limit['by_model'][m] = rate_limit['by_model'].get(m, 0) + n
            g = group_of(m) or 'other'
            rate_limit['by_group'][g] = rate_limit['by_group'].get(g, 0) + n

    limits, warn_ratio = load_limits()
    cooldowns = build_cooldowns(out_days, now)
    today_w = out_days[-1] if out_days else {'free_models': [], 'errors': {'total': 0, 'by_model': {}}}
    warnings, alert_level = compute_warnings(today_w, limits, warn_ratio, cooldowns)
    rate_limit['cooldown'] = [c for c in cooldowns if c['active']]

    return {
        'generated_at': now.strftime('%Y-%m-%d %H:%M:%S'),
        'tz': 'UTC+8',
        'days': out_days,
        'today': out_days[-1] if out_days else None,
        'totals': totals,
        'rate_limit': rate_limit,
        'cooldowns': cooldowns,
        'warnings': warnings,
        'alert_level': alert_level,
        'warn_ratio': warn_ratio,
        'limits': {k: {'req': v['req'], 'tokens': v['tokens'], 'note': v.get('note', '')}
                   for k, v in limits.items()},
        'membership': membership,
        'prices': {'source': prices.get('source'), 'fetched_at': prices.get('fetched_at'),
                   'currency': prices.get('currency', 'CNY'),
                   'basis': prices.get('pricing_basis', ''),
                   'note': '费用按各模型输入/缓存/输出 Token 单价估算；单价统一取厂商官网刊例价（美元×7.15），不采用限时折扣/活动价/中转站价；DeepSeek 高峰=工作日 9:00-12:00 / 14:00-18:00（北京时间），积分不计入费用'},
        'meta': meta,
        'signin': (check_signin_today() if check_signin_today else None),
        'matrix': (load_json(REPORT, {}).get('matrix') if os.path.exists(REPORT) else None) or (refresh_matrix() if refresh_matrix else None),
    }


def scan(force=False, prices=None, quiet=False, projects=None):
    t0 = time.time()
    prices = prices or ensure_prices()
    aliases = alias_map(prices)
    state = load_json(CACHE, None) or {'version': 1, 'files': {}, 'seen': {}, 'days': {}}
    if force:
        state = {'version': 1, 'files': {}, 'seen': {}, 'days': {}}
    migrate_state(state)
    files = state.setdefault('files', {})
    seen = state.setdefault('seen', {})
    days = state.setdefault('days', {})

    root = projects_dir(projects)
    paths = []
    if os.path.isdir(root):
        paths = glob.glob(os.path.join(root, '**', '*.jsonl'), recursive=True)
        paths = [p for p in paths if os.path.isfile(p)]
        if not paths and not quiet:
            print('[ttk] %s 下没有会话 jsonl，报告为空。' % root, file=sys.stderr)
    elif not quiet:
        print('[ttk] 未找到 CodeBuddy CLI 会话记录：%s' % root, file=sys.stderr)
        print('[ttk] ttk 计量 CodeBuddy CLI（终端 / 弹窗两种调用方式）的 token 用量；'
              '请先在任意调用方式下使用 CodeBuddy CLI，'
              '或用 --projects / 环境变量 TTK_PROJECTS 指定数据目录。', file=sys.stderr)
    new_records = 0
    scanned_bytes = 0
    rebuild = False

    for p in paths:
        try:
            st = os.stat(p)
        except OSError:
            continue
        ent = files.get(p)
        if ent and ent.get('size') == st.st_size and abs(ent.get('mtime', 0) - st.st_mtime) < 1e-6:
            continue
        offset = 0
        if ent and st.st_size >= ent.get('offset', 0):
            offset = ent.get('offset', 0)
        elif ent:
            rebuild = True
            break
        # 跨调用归因：沿用该文件已知最近模型
        last_model = (ent or {}).get('model')
        try:
            with open(p, 'rb') as f:
                f.seek(offset)
                data = f.read()
        except OSError:
            continue
        scanned_bytes += len(data)
        cut = data.rfind(b'\n')
        if cut < 0:
            files[p] = {'size': st.st_size, 'mtime': st.st_mtime, 'offset': offset}
            continue
        chunk = data[:cut + 1]
        for line in chunk.split(b'\n'):
            if b'rawUsage' in line:
                try:
                    o = json.loads(line.decode('utf-8', 'ignore'))
                except Exception:
                    o = None
                if o is not None:
                    rec = parse_usage_line(o, prices, aliases, seen)
                    if rec:
                        add_record(days, rec)
                        new_records += 1
                        last_model = rec['model']
                continue
            # 429 限流（行内不含 rawUsage）
            if b'"status":429' in line or b'429 too many' in line:
                try:
                    o = json.loads(line.decode('utf-8', 'ignore'))
                except Exception:
                    o = None
                if o is not None:
                    count_429(o, days, seen, last_model)
        files[p] = {'size': st.st_size, 'mtime': st.st_mtime,
                    'offset': offset + cut + 1, 'model': last_model}

    if rebuild:
        if not quiet:
            print('[ttk] 检测到文件被截断，全量重扫', file=sys.stderr)
        return scan(force=True, prices=prices, quiet=quiet, projects=projects)

    save_json(CACHE, state, compact=True)
    meta = {'files': len(paths), 'new_records': new_records,
            'scan_ms': int((time.time() - t0) * 1000),
            'scanned_mb': round(scanned_bytes / 1048576.0, 1),
            'requests': sum((d.get('terminal', {}).get('req', 0)
                             + d.get('popup', {}).get('req', 0))
                            for d in days.values())}
    if not paths:
        # 无数据源：缓存保留历史（写回上面已完成），但报告必须是空的，
        # 不能把旧数据当成当前数据源的统计展示。
        days = {}
        meta['requests'] = 0
    return days, meta


def main():
    ap = argparse.ArgumentParser(description='CodeBuddy Token & Matrix Tracker')
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--scan', action='store_true', help='执行会话 token 扫描（同默认）')
    ap.add_argument('--refresh-matrix', action='store_true', help='刷新 6 通道账号矩阵与精准积分')
    ap.add_argument('--signin', action='store_true', help='执行国内主号每日签到 (+100积分)')
    ap.add_argument('--check-signin', action='store_true', help='检查今日签到状态')
    ap.add_argument('--records', action='store_true', help='读取历史签到、巡检与扫描记录')
    ap.add_argument('--all', action='store_true', help='执行全量：签到检查 + 矩阵刷新 + 会话扫描')
    ap.add_argument('--refresh', action='store_true', help='丢弃 token 缓存，全量重扫')
    ap.add_argument('--update-prices', action='store_true')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--projects', default='',
                    help='CodeBuddy CLI 会话数据目录（等同环境变量 TTK_PROJECTS）')
    args = ap.parse_args()

    # 1. 独立签到
    if args.signin:
        if do_signin:
            res = do_signin()
            rep = load_json(REPORT, None) or {}
            rep['signin'] = check_signin_today() if check_signin_today else None
            if refresh_matrix:
                try:
                    rep['matrix'] = refresh_matrix()
                except Exception:
                    pass
            save_json(REPORT, rep)
            if args.json:
                print(json.dumps(res, ensure_ascii=False, indent=2))
            elif not args.quiet:
                print(f"[ttk] 签到结果: {res.get('message', '完成')} | 标记: {res.get('badge_text')}")
        return

    # 2. 仅检查签到
    if args.check_signin:
        res = check_signin_today() if check_signin_today else {}
        if args.json:
            print(json.dumps(res, ensure_ascii=False, indent=2))
        elif not args.quiet:
            print(f"[ttk] 今日签到状态: {res.get('badge_text')} ({res.get('msg')})")
        return

    # 3. 独立刷新矩阵与精准积分
    if args.refresh_matrix:
        if refresh_matrix:
            m_data = refresh_matrix()
            rep = load_json(REPORT, None) or {}
            rep['matrix'] = m_data
            rep['signin'] = check_signin_today() if check_signin_today else rep.get('signin')
            rep['generated_at'] = m_data['updated_at']
            save_json(REPORT, rep)
            if args.json:
                print(json.dumps(m_data, ensure_ascii=False, indent=2))
            elif not args.quiet:
                print(f"[ttk] 矩阵刷新完成: 6通道总积分 {m_data['total_credits']} 点 (更新于 {m_data['updated_at']})")
        return

    # 4. 读取运行记录
    if args.records:
        if get_records_summary:
            rec_data = get_records_summary()
            if args.json:
                print(json.dumps(rec_data, ensure_ascii=False, indent=2))
            elif not args.quiet:
                print(f"[ttk] 历史记录: 签到 {len(rec_data.get('signin_history', []))} 条, 巡检 {len(rec_data.get('matrix_history', []))} 条")
        return

    # 5. 全量预检
    if args.all:
        if check_signin_today and do_signin:
            st = check_signin_today()
            if not st.get('today_checked'):
                do_signin()
        if refresh_matrix:
            refresh_matrix()

    # 默认/会话扫描逻辑
    prices = ensure_prices(update=args.update_prices)
    days, meta = scan(force=args.refresh, prices=prices, quiet=args.quiet,
                      projects=args.projects or None)
    report = build_report(days, prices, max(1, args.days), meta)
    # 显式刷新时同步刷新账号矩阵，否则报告会一直沿用上次的旧额度
    if refresh_matrix and (args.refresh or args.all):
        try:
            report['matrix'] = refresh_matrix()
        except Exception:
            pass
    save_json(REPORT, report)

    t = report.get('today') or {}
    if append_scan_record:
        append_scan_record(meta, t.get('tokens', 0), t.get('cost', 0.0), t.get('credits', 0.0))

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    elif not args.quiet:
        print('[ttk] %s  tokens=%s  est_cost=%.2f CNY  req=%s  (+%s records, %sms)' % (
            t.get('date', '-'), f"{t.get('tokens', 0):,}", t.get('cost', 0.0), t.get('req', 0), meta['new_records'], meta['scan_ms']))
        print('[ttk] 今日上下行：输入 %s tokens（命中 %s · 未命中 %s · 缓存写入 %s）· 输出 %s tokens' % (
            f"{t.get('in', 0):,}", f"{t.get('hit', 0):,}", f"{t.get('miss', 0):,}",
            f"{t.get('write', 0):,}", f"{t.get('out', 0):,}"))
        print('[ttk] 今日拆分：终端 %s tokens（%d 次）· 弹窗 %s tokens（%d 次）' % (
            f"{t.get('terminal', {}).get('tokens', 0):,}", t.get('terminal', {}).get('req', 0),
            f"{t.get('popup', {}).get('tokens', 0):,}", t.get('popup', {}).get('req', 0)))
        if t.get('unpriced_models'):
            print('[ttk] ⚠ 未配置 Token 单价：%s（这些模型不计入估算费用）' % ', '.join(t['unpriced_models']))
        if report.get('matrix'):
            print(f"[ttk] 6通道全矩阵资产：{report['matrix']['total_credits']} 点可用")
        if report.get('signin'):
            print(f"[ttk] 今日签到标记：{report['signin'].get('badge_text')}")
        rl = report.get('rate_limit') or {}
        if rl.get('total'):
            parts = ['%s %d' % (g, n) for g, n in sorted(rl.get('by_group', {}).items(), key=lambda x: -x[1])]
            print('[ttk] 近 %d 天 429 限流 %d 次（渠道级额度）· %s' % (args.days, rl['total'], ' · '.join(parts)))
        for w in report.get('warnings') or []:
            if not w['level']:
                continue
            tag = '已触发 429 限流' if w['level'] == 2 else '接近免费额度上限'
            print('[ttk] ⚠ %s %s：今日 %d 请求 / %s（阈值 %d 请求 / %s）' % (
                w['group'], tag, w['req'], fmt_tok(w['tokens']),
                w['threshold_req'], fmt_tok(w['threshold_tokens'])))
            if w.get('cooldown') and w.get('remain'):
                print('[ttk]    ↳ %s 使用量已超出频率限制，%s 重置后可用（还剩 %s）· 可先切换其他模型（硬挤会反复中断）' % (
                    w.get('model_label') or w['group'], w.get('reset_at'), w['remain']))


if __name__ == '__main__':
    main()
