# -*- coding: utf-8 -*-
"""ttk.py - CodeBuddy token 用量记录器

扫描 CodeBuddy CLI 的会话记录（默认 ~/.codebuddy-cli/projects 下的 jsonl；
可用 --projects 参数或环境变量 TTK_PROJECTS 覆盖数据目录），
按 天 / 调用方式(终端, 弹窗) / 模型 聚合 token，并按 DeepSeek 官方峰谷价计算花销。

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
    "source": "https://api-docs.deepseek.com/zh-cn/quick_start/pricing",
    "fetched_at": "2026-10-17",
    "peak": {"ranges": [[9, 12], [14, 18]], "holidays": []},
    "models": {
        "deepseek-flash": {
            "aliases": ["deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4-flash",
                        "deepseek-v4-flash-vision-exp"],
            "hit": {"peak": 0.04, "off": 0.02},
            "miss": {"peak": 2.0, "off": 1.0},
            "out": {"peak": 8.0, "off": 4.0},
        },
        "deepseek-v4-pro": {
            "aliases": ["deepseek-v4-pro"],
            "hit": {"peak": 0.30, "off": 0.15},
            "miss": {"peak": 9.0, "off": 4.5},
            "out": {"peak": 27.0, "off": 13.5},
        },
    },
}

DEFAULT_MEMBERSHIP = {
    "plan": "WorkBuddy Pro",
    "currency": "USD",
    "monthly_fee_usd": 7.0,
    "next_fee_usd": 10.0,
    "next_effective": "2026-11-01",
    "usd_cny": 7.15,
    "note": "会员按月付费；API 价值按 DeepSeek 官方价折算，两者之差即省下的钱",
}

BUCKETS = ('hit_peak', 'hit_off', 'miss_peak', 'miss_off', 'out_peak', 'out_off')

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
    'step':     {'req': 5000, 'tokens': 1_000_000_000,
                 'note': '7天观测 0 次429，未触顶；阈值保守占位'},
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


def compute_warnings(today, limits, warn_ratio=DEFAULT_WARN_RATIO):
    ratio = float(warn_ratio)
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
        out.append({'group': g, 'level': lvl, 'req': req, 'tokens': tok,
                    'threshold_req': spec['req'], 'threshold_tokens': spec['tokens'],
                    'err429': e429, 'warn_ratio': ratio, 'note': spec.get('note', '')})
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
        },
        'deepseek-v4-pro': {
            'aliases': ['deepseek-v4-pro'],
            'hit': {'peak': found['hit']['peak'][1], 'off': found['hit']['off'][1]},
            'miss': {'peak': found['miss']['peak'][1], 'off': found['miss']['off'][1]},
            'out': {'peak': found['out']['peak'][1], 'off': found['out']['off'][1]},
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
            prices['models'] = fetch_prices()
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
    miss = ru.get('prompt_cache_miss_tokens')
    miss = int(miss) if miss is not None else max(prompt - hit, 0)
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
        'hit': hit, 'miss': miss, 'out': out, 'credit': credit,
        'hit_key': 'hit_' + b, 'miss_key': 'miss_' + b, 'out_key': 'out_' + b,
        'priced': model in aliases,
    }


def count_429(o, days, seen, last_model):
    """累计 429 限流事件。429 行本身不带模型 id，用同文件最近的请求模型反推。

    返回归因到的模型（便于调用方更新 last_model，虽然 429 不会更新）。
    """
    pd = o.get('providerData') or {}
    err = pd.get('error') or {}
    is429 = err.get('status') == 429
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
    return model


def add_record(days, rec):
    d = days.setdefault(rec['date'], day_skeleton())
    bucket = d[rec['client']]
    bucket[rec['hit_key']] += rec['hit']
    bucket[rec['miss_key']] += rec['miss']
    bucket[rec['out_key']] += rec['out']
    bucket['req'] += 1
    m = d['models'].setdefault(rec['model'], zero_bucket() | {'credit': 0.0})
    m[rec['hit_key']] += rec['hit']
    m[rec['miss_key']] += rec['miss']
    m[rec['out_key']] += rec['out']
    m['req'] += 1
    m['credit'] += rec['credit']


def model_cost(bucket, spec):
    if not spec:
        return 0.0
    total = 0.0
    for key, field in (('hit', 'hit'), ('miss', 'miss'), ('out', 'out')):
        total += bucket.get(field + '_peak', 0) * spec[key]['peak'] / 1e6
        total += bucket.get(field + '_off', 0) * spec[key]['off'] / 1e6
    return total


def load_membership():
    m = dict(DEFAULT_MEMBERSHIP)
    m.update(load_json(MEMBERSHIP, {}) or {})
    return m


def fee_usd_for(memb, day):
    """返回 day 当天适用的月费（美元）：到 next_effective 之后切到新价。"""
    nxt = memb.get('next_fee_usd')
    eff = memb.get('next_effective')
    if nxt and eff:
        try:
            if day >= datetime.date.fromisoformat(str(eff)):
                return float(nxt)
        except ValueError:
            pass
    return float(memb.get('monthly_fee_usd') or 0)


def day_cost(d, prices, aliases):
    total = 0.0
    for name, b in (d.get('models') or {}).items():
        total += model_cost(b, prices['models'].get(aliases.get(name, '')))
    return total


def bucket_view(b):
    hit = b['hit_peak'] + b['hit_off']
    miss = b['miss_peak'] + b['miss_off']
    out = b['out_peak'] + b['out_off']
    return {'in': hit + miss, 'hit': hit, 'miss': miss, 'out': out,
            'tokens': hit + miss + out, 'req': b['req']}


def projects_dir(override=None):
    """数据源目录优先级：显式参数 > 环境变量 TTK_PROJECTS > 默认路径。"""
    for cand in (override, os.environ.get('TTK_PROJECTS', '').strip()):
        if cand:
            return os.path.abspath(os.path.expanduser(cand))
    return DEFAULT_PROJECTS


def migrate_state(state):
    """旧缓存（客户端键 cb/ccb）迁移到 terminal/popup，兼容历史 cache。"""
    for d in (state.get('days') or {}).values():
        for old, new in (('cb', 'terminal'), ('ccb', 'popup')):
            if old in d:
                d.setdefault(new, d.pop(old))
    return state


def build_report(days, prices, span, meta):
    aliases = alias_map(prices)
    today = datetime.datetime.now(TZ).date()
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
        for name, b in d['models'].items():
            spec = prices['models'].get(aliases.get(name, ''))
            c = model_cost(b, spec)
            v = bucket_view(b)
            cost += c
            credits += b.get('credit', 0.0)
            models.append({'id': name, 'req': b['req'], 'tokens': v['tokens'],
                           'in': v['in'], 'out': v['out'], 'cost': round(c, 4),
                           'credit': b.get('credit', 0.0)})
        models.sort(key=lambda x: (-x['tokens'], x['id']))
        out_days.append({
            'date': key, 'weekday': WEEK[dt.weekday()],
            'terminal': terminal, 'popup': popup,
            'in': terminal['in'] + popup['in'],
            'hit': terminal['hit'] + popup['hit'],
            'miss': terminal['miss'] + popup['miss'],
            'out': terminal['out'] + popup['out'],
            'tokens': terminal['tokens'] + popup['tokens'],
            'req': terminal['req'] + popup['req'],
            'cost': round(cost, 4), 'credits': round(credits, 2), 'models': models,
        })
    # 免费/受限模型用量 + 渠道级 429 关联
    for od in out_days:
        d = days.get(od['date']) or day_skeleton()
        err = d.get('errors') or {'total': 0, 'by_model': {}}
        od['errors'] = {'total': err['total'], 'by_model': dict(err.get('by_model', {}))}
        free = []
        for g, keys in FREE_GROUPS:
            req = 0
            tok = 0
            e429 = 0
            for name, b in (d.get('models') or {}).items():
                nl = name.lower()
                if any(k in nl for k in keys):
                    req += b['req']
                    tok += (b['hit_peak'] + b['hit_off'] + b['miss_peak']
                            + b['miss_off'] + b['out_peak'] + b['out_off'])
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
    usd_cny = float(memb.get('usd_cny') or 7.15)
    fee_usd = fee_usd_for(memb, today)
    fee_cny = fee_usd * usd_cny
    nxt_fee = memb.get('next_fee_usd')
    nxt_eff = memb.get('next_effective')
    show_next = bool(nxt_fee and nxt_eff and float(nxt_fee) != fee_usd)
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
        'next_fee_usd': round(float(nxt_fee), 2) if show_next else None,
        'next_effective': str(nxt_eff) if show_next else None,
        'note': memb.get('note'),
    }
    totals = {
        'days': span,
        'tokens': sum(d['tokens'] for d in out_days),
        'cost': round(sum(d['cost'] for d in out_days), 4),
        'credits': round(sum(d['credits'] for d in out_days), 2),
        'req': sum(d['req'] for d in out_days),
        'terminal_tokens': sum(d['terminal']['tokens'] for d in out_days),
        'popup_tokens': sum(d['popup']['tokens'] for d in out_days),
        'err429': sum(d['errors']['total'] for d in out_days),
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
    today_w = out_days[-1] if out_days else {'free_models': [], 'errors': {'total': 0, 'by_model': {}}}
    warnings, alert_level = compute_warnings(today_w, limits, warn_ratio)

    return {
        'generated_at': datetime.datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S'),
        'tz': 'UTC+8',
        'days': out_days,
        'today': out_days[-1] if out_days else None,
        'totals': totals,
        'rate_limit': rate_limit,
        'warnings': warnings,
        'alert_level': alert_level,
        'warn_ratio': warn_ratio,
        'limits': {k: {'req': v['req'], 'tokens': v['tokens'], 'note': v.get('note', '')}
                   for k, v in limits.items()},
        'membership': membership,
        'prices': {'source': prices.get('source'), 'fetched_at': prices.get('fetched_at'),
                   'currency': prices.get('currency', 'CNY'),
                   'note': '高峰=工作日 9:00-12:00 / 14:00-18:00（北京时间），其余为空闲时段'},
        'meta': meta,
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
    ap = argparse.ArgumentParser()
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--refresh', action='store_true')
    ap.add_argument('--update-prices', action='store_true')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--projects', default='',
                    help='CodeBuddy CLI 会话数据目录（等同环境变量 TTK_PROJECTS）')
    args = ap.parse_args()

    prices = ensure_prices(update=args.update_prices)
    days, meta = scan(force=args.refresh, prices=prices, quiet=args.quiet,
                      projects=args.projects or None)
    report = build_report(days, prices, max(1, args.days), meta)
    save_json(REPORT, report)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    elif not args.quiet:
        t = report['today']
        print('[ttk] %s  tokens=%s  cost=%.2f CNY  req=%s  (+%s records, %sms)' % (
            t['date'], f"{t['tokens']:,}", t['cost'], t['req'], meta['new_records'], meta['scan_ms']))
        print('[ttk] 今日拆分：终端 %s tokens（%d 次）· 弹窗 %s tokens（%d 次）' % (
            f"{t['terminal']['tokens']:,}", t['terminal']['req'],
            f"{t['popup']['tokens']:,}", t['popup']['req']))
        rl = report.get('rate_limit') or {}
        if rl.get('total'):
            parts = ['%s %d' % (g, n) for g, n in sorted(rl.get('by_group', {}).items(), key=lambda x: -x[1])]
            print('[ttk] 近 %d 天 429 限流 %d 次（渠道级额度）· %s' % (args.days, rl['total'], ' · '.join(parts)))
        for w in report.get('warnings') or []:
            if not w['level']:
                continue
            if w['level'] == 2:
                tag = '已触发 429 限流'
            else:
                tag = '接近免费额度上限'
            print('[ttk] ⚠ %s %s：今日 %d 请求 / %s（阈值 %d 请求 / %s）' % (
                w['group'], tag, w['req'], fmt_tok(w['tokens']),
                w['threshold_req'], fmt_tok(w['threshold_tokens'])))


if __name__ == '__main__':
    main()
