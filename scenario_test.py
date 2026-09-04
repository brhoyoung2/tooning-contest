# -*- coding: utf-8 -*-
"""접수 시나리오 시뮬레이션 — 실제 anon 엔드포인트로 end-to-end 검증"""
import io, json, re, sys
import urllib.request

BASE = 'https://mllbsqnrvhvnqvxkpxof.supabase.co'
KEY = re.search(r"'(eyJ[A-Za-z0-9._-]+)'",
                io.open('index.html', encoding='utf-8').read()).group(1)
ADMIN_PW = '2509'

results = []


def call(fn, payload):
    req = urllib.request.Request(
        BASE + '/rest/v1/rpc/' + urllib.parse.quote(fn),
        data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
        headers={'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
                 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read().decode('utf-8') or 'null')
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        try:
            return e.code, json.loads(body)
        except Exception:
            return e.code, body


def check(label, ok, detail=''):
    results.append((ok, label, detail))
    print(('  PASS  ' if ok else '  FAIL  ') + label + (' — ' + detail if detail else ''))


def err_of(res):
    return res[1].get('message', '') if isinstance(res[1], dict) else str(res[1])


EMAIL = 'teacher@test.invalid'
BOARD = 'https://an-api.tooning.io/canvas-share/999001'


def base_payload(**kw):
    p = {
        'name': '테스트학생', 'school': '테스트초등학교', 'grade': '초등 5학년', 'class': '3반',
        'contact_type': 'teacher', 'contact_email': EMAIL,
        'teacher_name': '김선생', 'teacher_phone': '+82 010-0000-0000',
        'section': 'comic', 'topic': '2036년, 나의 하루 — 테스트',
        'work_description': '테스트용 시놉시스입니다.',
        'board_link': BOARD, 'consent': True, 'user_agent': 'scenario-test'
    }
    p.update(kw)
    return p


print('\n[1] 입력 검증 — 잘못된 요청은 거부되어야 함')
cases = [
    ('동의 미체크',        base_payload(consent=False),                       'consent_required'),
    ('필수값 누락(이름)',  base_payload(name=''),                             'missing_required'),
    ('이메일 형식 오류',   base_payload(contact_email='not-an-email'),        'invalid_email'),
    ('부문 화이트리스트',  base_payload(section='hacking'),                   'invalid_section'),
    ('연락처 유형 오류',   base_payload(contact_type='hacker'),               'invalid_contact_type'),
    ('보드 링크 외부 URL', base_payload(board_link='https://evil.example/x'), 'invalid_link'),
    ('PDF 외부 URL 주입',  base_payload(pdf_url='https://evil.example/a.pdf'), 'invalid_pdf'),
    ('소설: 기획안 없음',  base_payload(section='novel', episodes=[{'ep': 1, 'body': 'a'}] * 3),
     'proposal_required'),
    ('소설: 회차 부족',    base_payload(section='novel', proposal_text='기획안',
                                        episodes=[{'ep': 1, 'body': 'a'}]), 'episodes_required'),
    ('소설: 빈 회차',      base_payload(section='novel', proposal_text='기획안',
                                        episodes=[{'ep': 1, 'body': 'a'}, {'ep': 2, 'body': ' '},
                                                  {'ep': 3, 'body': 'c'}]), 'episode_empty'),
]
for label, payload, expect in cases:
    st, body = call('투닝콘테스트_제출', {'p_payload': payload})
    got = err_of((st, body))
    check(label, expect in got, '기대 %s / 실제 %s' % (expect, got or st))

print('\n[2] 정상 접수 (만화 부문)')
st, body = call('투닝콘테스트_제출', {'p_payload': base_payload()})
ok = isinstance(body, dict) and body.get('status') == 'created' and body.get('key')
key = body.get('key') if isinstance(body, dict) else None
check('접수 생성 + 접수키 발급', ok, str(body))
if not key:
    print('\n접수키를 받지 못해 이후 시나리오를 중단합니다.')
    sys.exit(1)
print('       발급된 접수키: ' + key)

print('\n[3] 접수 조회 (접수키)')
st, body = call('투닝콘테스트_조회', {'p_key': key})
row = body[0] if isinstance(body, list) and body else None
check('접수키로 1건 조회', bool(row) and row.get('name') == '테스트학생', str(row)[:110])
check('소문자 접수키도 조회', bool(call('투닝콘테스트_조회', {'p_key': key.lower()})[1]))
check('없는 접수키는 0건', call('투닝콘테스트_조회', {'p_key': 'TC-ZZZZ-ZZZZ'})[1] == [])

print('\n[4] 재제출 = 수정 (같은 이메일·부문)')
st, body = call('투닝콘테스트_제출', {'p_payload': base_payload(topic='수정된 제목 v2')})
check('status=updated', isinstance(body, dict) and body.get('status') == 'updated', str(body))
check('접수키 유지', isinstance(body, dict) and body.get('key') == key, str(body))
st, body = call('투닝콘테스트_조회', {'p_key': key})
check('수정 내용 반영', body and body[0].get('topic') == '수정된 제목 v2', str(body)[:110])

print('\n[5] 이력 보관')
st, hist = call('투닝콘테스트_이력', {'p_key': key})
check('이전 제출 1건 보관', isinstance(hist, list) and len(hist) == 1, str(hist)[:140])
if hist:
    check('보관된 내용이 수정 전 제목', hist[0].get('topic') == '2036년, 나의 하루 — 테스트',
          str(hist[0].get('topic')))

print('\n[6] 복구')
if hist:
    v = hist[0]['version']
    st, body = call('투닝콘테스트_복구', {'p_key': key, 'p_version': v})
    check('복구 성공', isinstance(body, dict) and body.get('status') == 'restored', str(body))
    st, cur = call('투닝콘테스트_조회', {'p_key': key})
    check('제목이 복구됨', cur and cur[0].get('topic') == '2036년, 나의 하루 — 테스트',
          str(cur)[:110])
    st, hist2 = call('투닝콘테스트_이력', {'p_key': key})
    check('복구 직전 상태도 보관(이력 2건)', isinstance(hist2, list) and len(hist2) == 2,
          '이력 %d건' % (len(hist2) if isinstance(hist2, list) else -1))
    st, body = call('투닝콘테스트_복구', {'p_key': key, 'p_version': 99})
    check('없는 버전 복구 거부', 'version_not_found' in err_of((st, body)), err_of((st, body)))

print('\n[7] 다른 부문은 별건 접수 (같은 이메일)')
novel = base_payload(section='novel', topic='소설 테스트',
                     proposal_text='기획 의도와 줄거리를 담은 기획안입니다.',
                     episodes=[{'ep': i, 'body': '본문 ' + str(i) + '화 ' + ('가' * 50)}
                               for i in (1, 2, 3)])
st, body = call('투닝콘테스트_제출', {'p_payload': novel})
novel_key = body.get('key') if isinstance(body, dict) else None
check('소설 부문 신규 접수', isinstance(body, dict) and body.get('status') == 'created', str(body))
check('만화와 다른 접수키 발급', bool(novel_key) and novel_key != key, str(novel_key))

print('\n[8] 관리자 조회')
st, body = call('투닝콘테스트_관리자목록', {'p_pw': 'wrong'})
check('틀린 비밀번호 거부', 'unauthorized' in err_of((st, body)), err_of((st, body)))
st, body = call('투닝콘테스트_관리자목록', {'p_pw': ADMIN_PW})
mine = [r for r in body if r.get('contact_email') == EMAIL] if isinstance(body, list) else []
check('관리자 목록에 테스트 2건 노출', len(mine) == 2, '조회 %d건' % len(mine))
if mine:
    nv = [r for r in mine if r['section'] == 'novel']
    check('소설 회차 수 집계', bool(nv) and nv[0].get('episode_count') == 3,
          str(nv[0].get('episode_count')) if nv else '-')
    check('기획안 본문 저장', bool(nv) and bool(nv[0].get('proposal_text')))
    check('학교급 자동 산출(초등)', mine[0].get('school_level') == '초등',
          str(mine[0].get('school_level')))

print('\n[9] 보안 재확인')
import urllib.parse
req = urllib.request.Request(
    BASE + '/rest/v1/' + urllib.parse.quote('투닝콘테스트_접수') + '?select=*&limit=1',
    headers={'apikey': KEY, 'Authorization': 'Bearer ' + KEY})
try:
    urllib.request.urlopen(req)
    check('anon 테이블 직접 조회 차단', False, '조회가 성공해버림')
except urllib.error.HTTPError as e:
    check('anon 테이블 직접 조회 차단', e.code in (401, 403), 'HTTP %d' % e.code)

print('\n' + '=' * 60)
p = sum(1 for r in results if r[0])
print('결과: %d/%d 통과' % (p, len(results)))
if p < len(results):
    print('\n실패 항목:')
    for ok, label, detail in results:
        if not ok:
            print('  · %s — %s' % (label, detail))
print('\n정리용 SQL:')
print("  DELETE FROM 투닝콘테스트_접수 WHERE contact_email LIKE '%@test.invalid';")
