# -*- coding: utf-8 -*-
"""
교수님 심사 코드 발급 + 작품 배정 (v21 의 투닝콘테스트_심사위원등록 RPC).

  python judge_assign.py 배정.json            # 발급·배정
  python judge_assign.py 배정.json --dry      # 검사만
  python judge_assign.py --status             # 상장 발급 현황

배정.json 예시 (_심사결과/ 아래에 두면 gitignore 대상):
  [
    {"교수명": "홍길동", "대학": "○○대학교", "직함": "교수", "email": "prof@univ.ac.kr",
     "submit_key": "TC-0E4C-4394", "상": "금상"}
  ]
code 를 적지 않으면 PRO-XXXX-XXXX-XXXX 가 자동 생성된다. 교수님(대학)당 부문별 1건, 최대 4건이다 (우수상 64명 = 16개 대학 x 4부문).
같은 교수님께 다른 부문 작품을 주려면 처음 발급된 code 를 적어 넣는다.
같은 부문의 다른 작품을 다시 주면 작품이 교체된다.

결과 코드 목록은 _심사결과/심사코드_발급.csv 로 저장된다. 코드는 교수님 개인 메일로만 전달할 것.
"""
import argparse, csv, io, json, os, re, sys
import urllib.request, urllib.parse, urllib.error

BASE = 'https://mllbsqnrvhvnqvxkpxof.supabase.co'
PW = os.environ.get('TC_ADMIN_PW', '2509')


def rpc(fn, payload):
    key = re.search(r"'(eyJ[A-Za-z0-9._-]+)'", io.open('index.html', encoding='utf-8').read()).group(1)
    req = urllib.request.Request(
        BASE + '/rest/v1/rpc/' + urllib.parse.quote(fn),
        data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
        headers={'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode('utf-8') or 'null')
    except urllib.error.HTTPError as e:
        return {'_error': e.code, 'body': e.read().decode('utf-8')[:400]}


def latest_sections():
    """심사 대상(최신 접수)의 접수번호 → 부문. 조회가 안 되면 빈 dict 로 두고 서버 검증에 맡긴다."""
    rows = rpc('투닝콘테스트_관리자목록', {'p_pw': PW})
    if not isinstance(rows, list):
        return {}
    return {r['submit_key']: r['section'] for r in rows if r.get('is_latest')}


def status():
    rows = rpc('투닝콘테스트_상장현황', {'p_pw': PW})
    if not isinstance(rows, list):
        print('조회 실패:', rows); return 1
    done = sum(1 for r in rows if r.get('out_발급'))
    print('심사위원·배정 %d행 / 상장 발급 %d건\n' % (len(rows), done))
    for r in rows:
        print('  %-26s %-8s %-14s → %-8s %-3s %s' % (
            r['out_code'], r['out_교수명'], (r['out_대학'] or '')[:14],
            r['out_학생'] or '(배정 없음)', r['out_상'] or '',
            '발급완료' if r['out_발급'] else '대기'))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?')
    ap.add_argument('--dry', action='store_true')
    ap.add_argument('--status', action='store_true')
    a = ap.parse_args()
    if a.status:
        return status()
    if not a.path:
        ap.error('배정 JSON 경로가 필요합니다 (또는 --status)')

    rows = json.load(io.open(a.path, encoding='utf-8'))
    bad = []
    for i, r in enumerate(rows, 1):
        for k in ('교수명', '대학'):
            if not str(r.get(k) or '').strip():
                bad.append('%d행: %s 가 비어 있습니다' % (i, k))
        sk = str(r.get('submit_key') or '').strip().upper()
        if sk and not re.match(r'^TC-[A-Z0-9]{4}-[A-Z0-9]{4}$', sk):
            bad.append('%d행: 접수번호 형식 오류 %r' % (i, sk))
        c = str(r.get('code') or '').strip().upper()
        if c and not re.match(r'^PRO-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$', c):
            bad.append('%d행: 코드 형식 오류 %r' % (i, c))
    # 교수님(대학)당 부문별 1건 · 작품당 1분 — 우수상 64명 = 16개 대학 x 4부문
    sections = latest_sections()
    SEC = {'comic': '만화', 'novel': '소설', 'cardnews': '카드뉴스', 'poster': '포스터'}
    by_slot, by_key = {}, {}
    for i, r in enumerate(rows, 1):
        sk = str(r.get('submit_key') or '').strip().upper()
        if not sk:
            continue
        c = str(r.get('code') or '').strip().upper() or ('(새 코드) ' + str(r.get('교수명')) + '|' + str(r.get('대학')))
        sec = sections.get(sk)
        if sections and sec is None:
            bad.append('%d행: %s 는 심사 대상(최신 접수)에 없는 접수번호입니다' % (i, sk))
            continue
        slot = (c, sec)
        if slot in by_key.values() or (slot in by_slot and by_slot[slot] != sk):
            bad.append('%d행: %s 님께 이미 %s 부문 작품(%s)이 배정돼 있습니다 — 부문별 1건입니다'
                       % (i, r.get('교수명'), SEC.get(sec, sec), by_slot.get(slot)))
        by_slot[slot] = sk
        if sk in by_key and by_key[sk] != slot:
            bad.append('%d행: %s 는 이미 다른 교수님께 배정돼 있습니다 — 작품당 1분입니다' % (i, sk))
        by_key[sk] = slot
    if bad:
        print('형식 문제 — 올리지 않았습니다.'); [print('  ·', b) for b in bad]; return 1
    print('형식 확인 OK — %d행' % len(rows))
    if a.dry:
        print('--dry 이므로 올리지 않았습니다.'); return 0

    res = rpc('투닝콘테스트_심사위원등록', {'p_pw': PW, 'p_rows': rows})
    if isinstance(res, dict) and '_error' in res:
        print('실패:', res); print('v21 마이그레이션을 먼저 실행하셨는지 확인해주세요.'); return 1

    os.makedirs('_심사결과', exist_ok=True)
    out = os.path.join('_심사결과', '심사코드_발급.csv')
    with io.open(out, 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.writer(f)
        w.writerow(['심사 코드', '교수명', '대학', '접수번호', '상'])
        for r in res:
            w.writerow([r['out_code'], r['out_교수명'], r['out_대학'], r['out_submit_key'] or '', r['out_상'] or ''])
    print('\n발급·배정 %d행' % len(res))
    for r in res:
        print('  %-26s %-8s %-14s %s %s' % (r['out_code'], r['out_교수명'], (r['out_대학'] or '')[:14],
                                          r['out_submit_key'] or '-', r['out_상'] or ''))
    print('\n저장: %s  ← 코드는 교수님 개인 메일로만 전달하세요' % out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
