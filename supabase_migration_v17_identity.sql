-- =====================================================
-- [투닝콘테스트] v17 — 참가자 식별 기준 변경 (동명이인 보호)
--
--   ⚠️ v15/v16 은 참가자를 '연락 이메일 + 이름' 으로 묶었습니다.
--      그래서 한 지도교사 이메일로 동명이인 학생 두 명이 접수하면
--      뒤에 낸 학생의 접수가 '재접수' 로 처리되어
--      앞 학생이 '이전 접수' 로 밀려 심사에서 빠졌습니다.
--
--   이제 '이름 + 학교 + 학년 + 반' 으로 식별합니다.
--   · 같은 교사 이메일로 여러 학생을 접수해도 학생별로 분리됩니다
--   · 동명이인이라도 학년·반이 다르면 서로 다른 참가자로 봅니다
--   · 같은 학생이 이메일을 바꿔 다시 접수해도 하나로 묶입니다
--
--   남는 경우: 같은 학교·같은 학년·같은 반에 완전히 같은 이름 두 명.
--   이때는 합쳐지지 않고 관리자 화면의 '이름 중복' 배지로 확인합니다.
--   (표기가 흔들려 갈라지는 쪽이 학생이 사라지는 것보다 안전합니다)
--
-- 전제: v15, v16 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

-- =====================================================
-- 1) 참가자 식별 키 — 공백·대소문자 흔들림을 흡수
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_참가자키(
  p_name text, p_school text, p_grade text, p_class text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT lower(replace(btrim(coalesce(p_name,   '')), ' ', '')) || '|' ||
         lower(replace(btrim(coalesce(p_school, '')), ' ', '')) || '|' ||
         lower(replace(btrim(coalesce(p_grade,  '')), ' ', '')) || '|' ||
         lower(replace(btrim(coalesce(p_class,  '')), ' ', ''));
$fn$;

CREATE INDEX IF NOT EXISTS 투닝콘테스트_접수_참가자키_idx
  ON 투닝콘테스트_접수 (public.투닝콘테스트_참가자키(name, school, grade, class), created_at DESC);

-- =====================================================
-- 2) 제출 RPC — 재접수 판정을 참가자 키 기준으로
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_제출(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 접수 기간은 투닝콘테스트_설정 테이블에서 읽습니다 (일정 변경 시 UPDATE 한 줄)
  v_open   timestamptz;
  v_close  timestamptz;
  -- 소설 부문 규격
  v_ep_min CONSTANT int := 3;

  v_email    text := lower(btrim(coalesce(p_payload->>'contact_email', '')));
  v_section  text := btrim(coalesce(p_payload->>'section', ''));
  v_board    text := btrim(coalesce(p_payload->>'board_link', ''));
  v_name     text := btrim(coalesce(p_payload->>'name', ''));
  v_school   text := btrim(coalesce(p_payload->>'school', ''));
  v_grade    text := btrim(coalesce(p_payload->>'grade', ''));
  v_class    text := btrim(coalesce(p_payload->>'class', ''));
  v_ctype    text := btrim(coalesce(p_payload->>'contact_type', ''));
  v_topic    text := btrim(coalesce(p_payload->>'topic', ''));
  v_pdf      text := nullif(btrim(coalesce(p_payload->>'pdf_url', '')), '');
  v_proposal text := nullif(btrim(coalesce(p_payload->>'proposal_text', '')), '');
  v_ai       text := nullif(btrim(coalesce(p_payload->>'ai_process', '')), '');
  v_eps      jsonb := p_payload->'episodes';

  v_prior    int := 0;
  v_id       uuid;
  v_key      text;
  v_status   text;
  v_try      int := 0;
  v_ep       jsonb;
BEGIN
  v_open  := coalesce(public.투닝콘테스트_기간('접수시작'), '2026-09-30 00:00:00+09'::timestamptz);
  v_close := coalesce(public.투닝콘테스트_기간('접수마감'), '2026-10-30 23:59:59+09'::timestamptz);
  IF now() < v_open  THEN RAISE EXCEPTION 'not_open'; END IF;
  IF now() > v_close THEN RAISE EXCEPTION 'closed';   END IF;

  IF coalesce((p_payload->>'consent')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'consent_required';
  END IF;

  IF v_name = '' OR v_school = '' OR v_grade = '' OR v_class = '' OR v_topic = '' THEN
    RAISE EXCEPTION 'missing_required';
  END IF;

  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  IF v_section NOT IN ('comic', 'novel', 'cardnews', 'poster') THEN
    RAISE EXCEPTION 'invalid_section';
  END IF;

  IF v_ctype NOT IN ('teacher', 'parent') THEN
    RAISE EXCEPTION 'invalid_contact_type';
  END IF;

  IF position('tooning.io' in lower(v_board)) = 0 THEN
    RAISE EXCEPTION 'invalid_link';
  END IF;

  IF v_pdf IS NOT NULL AND position('/storage/v1/object/public/submissions/' in v_pdf) = 0 THEN
    RAISE EXCEPTION 'invalid_pdf';
  END IF;

  -- ── 생성형 AI 활용 과정: 전 부문 공통 필수 ──
  IF v_ai IS NULL THEN
    RAISE EXCEPTION 'ai_process_required';
  END IF;

  -- ── 지도교사 이름: 지도교사 유형일 때 필수 ──
  IF v_ctype = 'teacher'
     AND nullif(btrim(coalesce(p_payload->>'teacher_name', '')), '') IS NULL THEN
    RAISE EXCEPTION 'teacher_name_required';
  END IF;

  -- ── 시놉시스/설명: 만화·카드뉴스 부문 필수 ──
  IF v_section IN ('comic', 'cardnews')
     AND nullif(btrim(coalesce(p_payload->>'work_description', '')), '') IS NULL THEN
    RAISE EXCEPTION 'description_required';
  END IF;

  -- ── 기획안 본문: 소설·포스터 부문 필수 ──
  IF v_section IN ('novel', 'poster') AND v_proposal IS NULL THEN
    RAISE EXCEPTION 'proposal_required';
  END IF;
  IF v_section NOT IN ('novel', 'poster') THEN
    v_proposal := NULL;              -- 다른 부문에서 잘못 넘어온 값은 저장하지 않음
  END IF;

  -- ── 회차 본문: 소설 부문 전용 ──
  IF v_section = 'novel' THEN
    IF v_eps IS NULL OR jsonb_typeof(v_eps) <> 'array'
       OR jsonb_array_length(v_eps) < v_ep_min THEN
      RAISE EXCEPTION 'episodes_required';
    END IF;
    FOR v_ep IN SELECT * FROM jsonb_array_elements(v_eps) LOOP
      IF btrim(coalesce(v_ep->>'body', '')) = '' THEN
        RAISE EXCEPTION 'episode_empty';
      END IF;
    END LOOP;
  ELSE
    v_eps := NULL;
  END IF;

  -- ── 재접수 허용 ──
  --    기존 접수를 덮어쓰지 않고 항상 새 접수로 저장한다.
  --    같은 참가자의 마지막 접수가 '최신'으로 표시되고 최종 접수로 인정된다.
  LOOP
    v_try := v_try + 1;
    v_key := 'TC-' || upper(substr(md5(gen_random_uuid()::text), 1, 4))
                   || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
    BEGIN
      INSERT INTO 투닝콘테스트_접수 (
        name, school, grade, class,
        contact_type, contact_email, teacher_phone, teacher_name, parent_phone,
        section, topic,
        work_description, board_link,
        pdf_url, proposal_text, ai_process, episodes,
        user_agent, consent, submit_key, updated_at
      ) VALUES (
        v_name, v_school, v_grade, v_class,
        v_ctype, v_email,
        nullif(btrim(coalesce(p_payload->>'teacher_phone', '')), ''),
        nullif(btrim(coalesce(p_payload->>'teacher_name',  '')), ''),
        nullif(btrim(coalesce(p_payload->>'parent_phone',  '')), ''),
        v_section, v_topic,
        nullif(btrim(coalesce(p_payload->>'work_description', '')), ''),
        v_board, v_pdf, v_proposal, v_ai, v_eps,
        left(coalesce(p_payload->>'user_agent', ''), 500),
        true, v_key, now()
      );
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_try >= 5 THEN RAISE EXCEPTION 'submit_failed'; END IF;
    END;
  END LOOP;

  -- 같은 참가자의 이전 접수가 있으면 'resubmitted', 첫 접수면 'created'
  SELECT count(*) INTO v_prior
    FROM 투닝콘테스트_접수
   WHERE public.투닝콘테스트_참가자키(name, school, grade, class)
         = public.투닝콘테스트_참가자키(v_name, v_school, v_grade, v_class)
     AND submit_key <> v_key;

  v_status := CASE WHEN v_prior > 0 THEN 'resubmitted' ELSE 'created' END;

  RETURN jsonb_build_object('status', v_status, 'key', v_key, 'prior', v_prior);
END;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_제출(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_제출(jsonb) TO anon, authenticated;

-- =====================================================
-- 3) 관리자 목록 RPC — 최신 판정을 참가자 키 기준으로
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_관리자목록(text);

CREATE FUNCTION public.투닝콘테스트_관리자목록(p_pw text)
RETURNS TABLE (
  id            uuid,
  created_at    timestamptz,
  updated_at    timestamptz,
  submit_key    text,
  name          text,
  school        text,
  grade         text,
  school_level  text,
  class         text,
  contact_type  text,
  contact_email text,
  teacher_name  text,
  teacher_phone text,
  parent_phone  text,
  section       text,
  topic         text,
  work_description text,
  proposal_text text,
  ai_process    text,
  episodes      jsonb,
  episode_count int,
  board_link    text,
  pdf_url       text,
  status        text,
  is_latest     boolean,
  seq           int,
  total_seq     int
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pw CONSTANT text := '2509';   -- ← 운영 전 변경 권장
BEGIN
  IF p_pw IS DISTINCT FROM v_pw THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN QUERY
  WITH g AS (
    SELECT s.*,
           row_number() OVER (PARTITION BY public.투닝콘테스트_참가자키(s.name, s.school, s.grade, s.class)
                              ORDER BY s.created_at)                    AS rn,
           count(*)    OVER (PARTITION BY public.투닝콘테스트_참가자키(s.name, s.school, s.grade, s.class)) AS cnt
      FROM 투닝콘테스트_접수 s
  )
  SELECT g.id, g.created_at, g.updated_at, g.submit_key,
         g.name, g.school, g.grade, g.school_level, g.class,
         g.contact_type, g.contact_email, g.teacher_name, g.teacher_phone, g.parent_phone,
         g.section, g.topic, g.work_description, g.proposal_text, g.ai_process,
         g.episodes,
         CASE WHEN g.episodes IS NULL THEN 0 ELSE jsonb_array_length(g.episodes) END,
         g.board_link, g.pdf_url, g.status,
         (g.rn = g.cnt)   AS is_latest,
         g.rn::int        AS seq,
         g.cnt::int       AS total_seq
    FROM g
   ORDER BY g.created_at DESC;
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_관리자목록(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_관리자목록(text) TO anon, authenticated;

-- =====================================================
-- 4) 접수 조회 RPC — 참가자 키 기준
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_조회(text);

CREATE FUNCTION public.투닝콘테스트_조회(p_key text)
RETURNS TABLE (
  submit_key text,
  name       text,
  school     text,
  grade      text,
  section    text,
  topic      text,
  status     text,
  created_at timestamptz,
  is_latest  boolean,
  queried    boolean,
  seq        int,
  total_seq  int
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  WITH target AS (
    SELECT public.투닝콘테스트_참가자키(name, school, grade, class) AS pkey
      FROM 투닝콘테스트_접수
     WHERE submit_key = upper(btrim(p_key))
     LIMIT 1
  ),
  mine AS (
    SELECT s.*,
           row_number() OVER (ORDER BY s.created_at) AS rn,
           count(*)     OVER ()                      AS cnt
      FROM 투닝콘테스트_접수 s, target t
     WHERE public.투닝콘테스트_참가자키(s.name, s.school, s.grade, s.class) = t.pkey
  )
  SELECT m.submit_key, m.name, m.school, m.grade, m.section, m.topic, m.status, m.created_at,
         (m.rn = m.cnt)                       AS is_latest,
         (m.submit_key = upper(btrim(p_key))) AS queried,
         m.rn::int                            AS seq,
         m.cnt::int                           AS total_seq
    FROM mine m
   ORDER BY m.created_at DESC
   LIMIT 20;
$fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_조회(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_조회(text) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 같은 교사 이메일 + 동명이인(학년·반 다름) 이 각각 최신으로 잡히는지
--   SELECT name, class, submit_key, seq, total_seq, is_latest
--     FROM public.투닝콘테스트_관리자목록('2509')
--    ORDER BY name, seq;
