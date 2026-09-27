-- =====================================================
-- [투닝콘테스트] v18 — 참가자 본인 이메일 (선택 입력)
--
--   접수 확인 메일이 지도교사·보호자에게만 가서, 학생이 자기 접수번호를
--   직접 확인하려면 어른을 거쳐야 했습니다.
--
--   · 본인 이메일을 적으면 접수 확인 메일을 '함께' 받습니다
--   · 비워두면 지금과 동일하게 교사·보호자 주소로만 발송됩니다
--   · 초등 참가자가 대부분이라 필수로 두지 않습니다
--     (이메일이 없는 학생이 접수하지 못하는 일을 막기 위함)
--
-- 전제: v13, v17 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

ALTER TABLE 투닝콘테스트_접수
  ADD COLUMN IF NOT EXISTS student_email TEXT;

COMMENT ON COLUMN 투닝콘테스트_접수.student_email IS
  '참가자 본인 이메일(선택). 입력 시 접수 확인 메일을 교사/보호자와 함께 수신.';

COMMIT;

-- =====================================================
-- 1) 제출 RPC — 본인 이메일 저장 + 형식 검증
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
  v_stu      text := lower(nullif(btrim(coalesce(p_payload->>'student_email', '')), ''));
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

  -- 참가자 본인 이메일은 선택. 적었다면 형식만 확인한다.
  IF v_stu IS NOT NULL AND v_stu !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'invalid_student_email';
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
        contact_type, contact_email, student_email, teacher_phone, teacher_name, parent_phone,
        section, topic,
        work_description, board_link,
        pdf_url, proposal_text, ai_process, episodes,
        user_agent, consent, submit_key, updated_at
      ) VALUES (
        v_name, v_school, v_grade, v_class,
        v_ctype, v_email, v_stu,
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
-- 2) 관리자 목록 RPC — 본인 이메일 노출
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
  student_email text,
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
         g.contact_type, g.contact_email, g.student_email, g.teacher_name, g.teacher_phone, g.parent_phone,
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
-- 3) 메일 트리거 — 본인 이메일도 수신자에 포함
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_접수완료메일()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_api   text;
  v_on    text;
  v_subj  text;
  v_body  text;
  v_cc    text;
  v_from  text;
  v_html  text;
  v_when  text := to_char(coalesce(NEW.updated_at, now()) AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD HH24:MI');
  v_state text := CASE WHEN TG_OP = 'INSERT' THEN '접수 완료' ELSE '접수 내용이 수정' END;
  v_sec   text := CASE NEW.section
                    WHEN 'comic'    THEN '만화 / 웹툰'
                    WHEN 'novel'    THEN '소설 / 이야기'
                    WHEN 'cardnews' THEN '카드뉴스'
                    WHEN 'poster'   THEN '포스터'
                    ELSE coalesce(NEW.section, '') END;
BEGIN
  -- 수신 주소가 없으면 조용히 종료
  IF NEW.contact_email IS NULL OR position('@' in NEW.contact_email) = 0 THEN
    RETURN NEW;
  END IF;

  SELECT value INTO v_on  FROM 투닝콘테스트_설정 WHERE key = '메일발송';
  IF coalesce(v_on, 'on') <> 'on' THEN RETURN NEW; END IF;

  SELECT btrim(value) INTO v_api FROM 투닝콘테스트_설정 WHERE key = 'RESEND_API_KEY';
  IF coalesce(v_api, '') = '' THEN RETURN NEW; END IF;   -- 키 미등록이면 발송하지 않음

  SELECT value INTO v_subj FROM 투닝콘테스트_설정 WHERE key = '메일제목';
  SELECT value INTO v_body FROM 투닝콘테스트_설정 WHERE key = '메일본문';
  SELECT value INTO v_cc   FROM 투닝콘테스트_설정 WHERE key = '메일참조';
  SELECT value INTO v_from FROM 투닝콘테스트_설정 WHERE key = '메일발신';

  v_subj := coalesce(nullif(btrim(v_subj), ''), '[제2회 투닝 국제 공모전] 접수가 완료되었습니다');
  v_body := coalesce(v_body, '작품 접수가 완료되었습니다.');
  v_from := coalesce(nullif(btrim(v_from), ''), '제2회 투닝 국제 공모전 <support@tooning.io>');
  v_cc   := coalesce(nullif(btrim(v_cc), ''), 'leo@tooning.io,support@tooning.io');

  -- 치환
  v_body := replace(v_body, '{상태}',     v_state);
  v_body := replace(v_body, '{접수키}',   coalesce(NEW.submit_key, ''));
  v_body := replace(v_body, '{이름}',     coalesce(NEW.name, ''));
  v_body := replace(v_body, '{학교}',     coalesce(NEW.school, ''));
  v_body := replace(v_body, '{학년}',     coalesce(NEW.grade, ''));
  v_body := replace(v_body, '{부문}',     v_sec);
  v_body := replace(v_body, '{작품제목}', coalesce(NEW.topic, ''));
  v_body := replace(v_body, '{최종접수}', v_when);
  v_body := replace(v_body, '{작품링크}',
      CASE WHEN coalesce(NEW.board_link, '') = '' THEN '-'
           ELSE '<a href="' || NEW.board_link || '">' || NEW.board_link || '</a>' END);

  v_subj := replace(v_subj, '{접수키}', coalesce(NEW.submit_key, ''));
  v_subj := replace(v_subj, '{이름}',   coalesce(NEW.name, ''));
  v_subj := replace(v_subj, '{부문}',   v_sec);

  v_html := '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',sans-serif;'
         || 'font-size:15px;line-height:1.75;color:#222">'
         || replace(v_body, E'\n', '<br>') || '</div>';

  BEGIN
    PERFORM net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_api,
        'Content-Type',  'application/json',
        -- api.resend.com 은 Cloudflare 뒤라 User-Agent 없으면 1010 으로 차단됨
        'User-Agent',    'tooning-contest/1.0 (+https://tooning.io)'
      ),
      body := jsonb_build_object(
        'from',     v_from,
        -- 본인 이메일을 적었으면 함께 수신자로 넣는다
        'to',       CASE WHEN NEW.student_email IS NULL OR btrim(NEW.student_email) = ''
                         THEN jsonb_build_array(NEW.contact_email)
                         ELSE jsonb_build_array(NEW.contact_email, NEW.student_email) END,
        'cc',       (SELECT jsonb_agg(btrim(x)) FROM unnest(string_to_array(v_cc, ',')) AS x
                      WHERE btrim(x) <> ''),
        'reply_to', 'support@tooning.io',
        'subject',  v_subj,
        'html',     v_html
      )
    );
  EXCEPTION WHEN others THEN
    NULL;   -- 메일이 실패해도 접수는 정상 저장
  END;

  RETURN NEW;
END $$;


-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 컬럼 추가
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = '투닝콘테스트_접수' AND column_name = 'student_email';
--
-- 본인 이메일을 적은 접수의 메일 수신자가 2명인지
--   SELECT id, status_code, left(content, 120) FROM net._http_response
--    ORDER BY id DESC LIMIT 5;
