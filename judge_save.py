# -*- coding: utf-8 -*-
"""
심사 결과를 DB 에 올린다 (v20 의 투닝콘테스트_심사저장 RPC).

  python judge_save.py _심사결과/1차.json           # 업로드
  python judge_save.py _심사결과/1차.json --dry     # 검사만 하고 올리지 않음
  python judge_save.py --show                       # 저장된 순위 보기

입력 JSON 은 심사기준.md 의 출력 형식을 그대로 담은 배열이다.
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.request
import urllib.parse
import urllib.error

BASE = 'https://mllbsqnrvhvnqvxkpxof.supabase.co'
ADMIN_PW = os.environ.get('TC_ADMIN_PW', '2509')
AXES = ['주제적합성', '창의성', '완성도', '표현력']
SEC = {'comic': '만화/웹툰', 'novel': '소설/이야기', 'cardnews': '카드뉴스', 'poster': '포스터'}


def rpc(fn, payload):
    key = re.search(r"'(eyJ[A-Za-z0-9._-]+)'", io.open('index.html', encoding='utf-8').read()).group(1)
    req = urllib.request.Request(
        BASE + '/rest/v1/rpc/' + urllib.parse.quote(fn),
        data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
        headers={'apikey': key, 'Authorization': 'Bearer ' + key,
                 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode('utf-8') or 'null')
    except urllib.error.HTTPError as e:
        return {'_error': e.code, 'body': e.read().decode('utf-8')[:400]}


def check(rows):
    """올리기 전에 형식을 확인한다. 점수 하나가 틀어지면 순위 전체가 흔들린다."""
    bad = []
    seen = set()
    for i, r in enumerate(rows):
        k = str(r.get('submit_key') or '')
        if not re.match(r'^TC-[A-Z0-9]{4}-[A-Z0-9]{4}$', k):
            bad.append('%d행: 접수번호 형식 오류 %r' % (i + 1, k))
        pair = (k, r.get('round', 1))
        if pair in seen:
            bad.append('%d행: 같은 차수에 중복 %s' % (i + 1, k))
        seen.add(pair)
        for a in AXES:
            v = r.get(a)
            if not isinstance(v, (int, float)) or not (0 <= v <= 10):
                bad.append('%d행 %s: 0~10 밖이거나 숫자 아님 (%r)' % (i + 1, a, v))
        if r.get('evidence') not in ('pdf', 'text_only'):
            bad.append('%d행: evidence 는 pdf 또는 text_only (%r)' % (i + 1, r.get('evidence')))
        if r.get('evidence') == 'text_only' and '텍스트' not in str(r.get('근거') or ''):
            bad.append('%d행: text_only 인데 근거에 작품 미확인 사실이 없음' % (i + 1))
    return bad


def show():
    rows = rpc('투닝콘테스트_심사결과', {'p_pw': ADMIN_PW, 'p_round': 1})
    if not isinstance(rows, list):
        print('조회 실패:', rows)
        return 1
    if not rows:
        print('저장된 심사 결과가 없습니다.')
        return 0
    cur = None
    for r in rows:
        key = (r['section'], r['school_level'])
        if key != cur:
            cur = key
            print('\n── %s · %s (%d명) ──' % (SEC.get(r['section'], r['section']),
                                             r['school_level'], r['부문내총원']))
            print('   %-3s %-8s %-16s %5s  %s' % ('순위', '이름', '학교', '총점', '비고'))
        print('   %-3d %-8s %-16s %5.1f  %s' % (
            r['순위'], r['name'], (r['school'] or '')[:16], float(r['총점']),
            '작품 미확인(텍스트만)' if r['evidence'] == 'text_only' else ''))
    print('\n총 %d건' % len(rows))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?', help='심사 결과 JSON')
    ap.add_argument('--dry', action='store_true', help='검사만 하고 올리지 않음')
    ap.add_argument('--show', action='store_true', help='저장된 순위 보기')
    args = ap.parse_args()

    if args.show:
        return show()
    if not args.path:
        ap.error('심사 결과 JSON 경로가 필요합니다 (또는 --show)')

    rows = json.load(io.open(args.path, encoding='utf-8'))
    problems = check(rows)
    if problems:
        print('형식 문제 %d건 — 올리지 않았습니다.' % len(problems))
        for p in problems:
            print('  ·', p)
        return 1
    print('형식 확인 OK — %d건' % len(rows))
    for r in rows:
        print('   %s  %s  총점 %.1f  %s' % (
            r['submit_key'], ' '.join('%s %.1f' % (a, r[a]) for a in AXES),
            sum(r[a] for a in AXES), '[텍스트만]' if r['evidence'] == 'text_only' else ''))
    if args.dry:
        print('\n--dry 이므로 올리지 않았습니다.')
        return 0

    res = rpc('투닝콘테스트_심사저장', {'p_pw': ADMIN_PW, 'p_rows': rows})
    if isinstance(res, dict) and '_error' in res:
        print('\n저장 실패:', res)
        print('v20 마이그레이션을 먼저 실행하셨는지 확인해주세요.')
        return 1
    print('\n저장 완료:', res)
    return 0


if __name__ == '__main__':
    sys.exit(main())
