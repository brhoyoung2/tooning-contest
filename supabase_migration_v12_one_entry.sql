-- =====================================================
-- [투닝콘테스트] v12 — 1인 1작품 · 1개 부문
--
--   공식 안내: "1인당 1작품, 1개 부문에만 출품 가능. 중복 출품 불가"
--   지금까지는 (이메일 + 부문) 이 유니크라 같은 사람이 부문을 바꿔
--   여러 건을 접수할 수 있었습니다. 이를 이메일 1건으로 제한합니다.
--
--   · 같은 이메일로 다시 제출 → 기존 접수 수정 (이력 보관은 그대로)
--   · 다른 부문으로 시도      → category_locked:<기존부문> 으로 거부
--                               (충남 폼의 '중복·변경 시 탈락' 정책과 동일)
--
-- 전제: v6, v9, v10, v11 실행 완료
-- 성격: 비파괴 (기존 데이터 유지) · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

-- =====================================================
-- 0. 사전 점검 — 같은 이메일로 2건 이상인 접수가 있으면 유니크 생성이 실패합니다
--    (아래 SELECT 가 0건이어야 정상. 결과가 있으면 먼저 정리하세요)
-- =====================================================
SELECT lower(contact_email) AS 이메일, count(*) AS 건수,
       string_agg(section || '/' || coalesce(submit_key, '키없음'), ', ') AS 접수
  FROM 투닝콘테스트_접수
 WHERE contact_email IS NOT NULL
 GROUP BY lower(contact_email)
HAVING count(*) > 1;

-- 시나리오 테스트로 생긴 건 정리 (실제 접수에는 영향 없음)
DELETE FROM 투닝콘테스트_접수 WHERE contact_email LIKE '%@test.invalid';

BEGIN;

-- =====================================================
-- 1. 유니크 키 교체: (이메일 + 부문) → 이메일
-- =====================================================
DROP INDEX IF EXISTS 투닝콘테스트_접수_이메일부문_uk;

CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_접수_이메일_uk
  ON 투닝콘테스트_접수 (lower(contact_email))
  WHERE contact_email IS NOT NULL;

COMMIT;

-- =====================================================
-- 2. 제출 RPC — 부문 변경 차단
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

  v_prev     text;
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

  -- ── 1인 1작품·1부문 ──
  --    이메일 기준으로만 기존 접수를 찾고, 부문을 바꾸려 하면 거부한다.
  SELECT id, submit_key, section INTO v_id, v_key, v_prev
    FROM 투닝콘테스트_접수
   WHERE lower(contact_email) = v_email
   LIMIT 1;

  IF v_id IS NOT NULL AND v_prev IS DISTINCT FROM v_section THEN
    RAISE EXCEPTION 'category_locked:%', v_prev;
  END IF;

  IF v_id IS NOT NULL THEN
    UPDATE 투닝콘테스트_접수 SET
      name                = v_name,
      school              = v_school,
      grade               = v_grade,
      class               = v_class,
      contact_type        = v_ctype,
      contact_email       = v_email,
      teacher_phone       = nullif(btrim(coalesce(p_payload->>'teacher_phone', '')), ''),
      teacher_name        = nullif(btrim(coalesce(p_payload->>'teacher_name',  '')), ''),
      parent_phone        = nullif(btrim(coalesce(p_payload->>'parent_phone',  '')), ''),
      topic               = v_topic,
      work_description    = nullif(btrim(coalesce(p_payload->>'work_description', '')), ''),
      board_link          = v_board,
      pdf_url             = coalesce(v_pdf, pdf_url),
      proposal_text       = v_proposal,
      ai_process          = v_ai,
      episodes            = v_eps,
      user_agent          = left(coalesce(p_payload->>'user_agent', ''), 500),
      consent             = true,
      updated_at          = now()
    WHERE id = v_id;

    v_status := 'updated';

    IF v_key IS NULL THEN
      LOOP
        v_try := v_try + 1;
        v_key := 'TC-' || upper(substr(md5(gen_random_uuid()::text), 1, 4))
                       || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
        BEGIN
          UPDATE 투닝콘테스트_접수 SET submit_key = v_key WHERE id = v_id;
          EXIT;
        EXCEPTION WHEN unique_violation THEN
          IF v_try >= 5 THEN RAISE EXCEPTION 'key_generation_failed'; END IF;
        END;
      END LOOP;
    END IF;

  ELSE
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

    v_status := 'created';
  END IF;

  RETURN jsonb_build_object('status', v_status, 'key', v_key);
END;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_제출(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_제출(jsonb) TO anon, authenticated;




-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 유니크 인덱스 확인 (투닝콘테스트_접수_이메일_uk 하나만 남아야 정상)
--   SELECT indexname FROM pg_indexes
--    WHERE tablename = '투닝콘테스트_접수' AND indexname LIKE '%uk';
--
-- 접수 기간 중, 같은 이메일로 다른 부문 제출 → category_locked:comic 형태로 거부
