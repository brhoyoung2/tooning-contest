-- =====================================================
-- [투닝콘테스트] v6 마이그레이션 — 소설/이야기 부문 개편
--   ① 기획안을 링크가 아닌 본문 텍스트로 접수 (proposal_text — 소설·포스터 공용)
--      AI 심사가 본문을 그대로 읽을 수 있도록, 외부 링크 대신 텍스트로 받는다
--   ② 회차별 본문을 jsonb 배열로 접수 (episodes = [{ep, body}])
--      충남 웹소설 extra.episodes 구조와 동일
--   ③ 제출 RPC 에 소설 부문 전용 서버 검증 추가
--
-- 전제: supabase_schema.sql → v2 → v3 → v4 → v5 실행 완료
-- 성격: 비파괴 (기존 데이터 유지)
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

-- =====================================================
-- 1. 컬럼 추가
-- =====================================================
ALTER TABLE 투닝콘테스트_접수
  ADD COLUMN IF NOT EXISTS proposal_text TEXT,
  ADD COLUMN IF NOT EXISTS episodes      JSONB;

COMMENT ON COLUMN 투닝콘테스트_접수.proposal_text IS '기획안 본문(소설·포스터 부문). 참가자가 폼에 직접 작성하며 AI 심사 입력으로 그대로 사용.';
COMMENT ON COLUMN 투닝콘테스트_접수.episodes      IS '소설/이야기 부문 회차별 본문. [{"ep":1,"body":"..."}] 형식 (충남 웹소설 extra.episodes 와 동일 구조).';
COMMENT ON COLUMN 투닝콘테스트_접수.link_proposal IS '(사용 중지) 구 기획안 링크. proposal_text 로 대체됨.';
COMMENT ON COLUMN 투닝콘테스트_접수.link_novel    IS '(사용 중지) 구 소설 본문 링크. episodes 로 대체됨.';
COMMENT ON COLUMN 투닝콘테스트_접수.link_novel_proposal IS '(사용 중지) 구 포스터 기획안 링크. proposal_text 로 대체됨.';

-- 회차 수 조회용 (심사 배치에서 부문×회차수 확인)
CREATE INDEX IF NOT EXISTS 투닝콘테스트_접수_회차_idx
  ON 투닝콘테스트_접수 ((jsonb_array_length(episodes)))
  WHERE episodes IS NOT NULL;

COMMIT;

-- =====================================================
-- 2. 제출 RPC — 기획안 본문 · 회차 본문 저장 및 검증
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_제출(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 접수 기간 (KST). 운영 일정이 바뀌면 이 두 줄만 수정하세요.
  v_open   CONSTANT timestamptz := '2026-09-30 00:00:00+09';
  v_close  CONSTANT timestamptz := '2026-10-30 23:59:59+09';
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
  v_eps      jsonb := p_payload->'episodes';

  v_id       uuid;
  v_key      text;
  v_status   text;
  v_try      int := 0;
  v_ep       jsonb;
BEGIN
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

  SELECT id, submit_key INTO v_id, v_key
    FROM 투닝콘테스트_접수
   WHERE lower(contact_email) = v_email
     AND section = v_section
   LIMIT 1;

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
          pdf_url, proposal_text, episodes,
          user_agent, consent, submit_key, updated_at
        ) VALUES (
          v_name, v_school, v_grade, v_class,
          v_ctype, v_email,
          nullif(btrim(coalesce(p_payload->>'teacher_phone', '')), ''),
          nullif(btrim(coalesce(p_payload->>'teacher_name',  '')), ''),
          nullif(btrim(coalesce(p_payload->>'parent_phone',  '')), ''),
          v_section, v_topic,
          nullif(btrim(coalesce(p_payload->>'work_description', '')), ''),
          v_board, v_pdf, v_proposal, v_eps,
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
-- 3. 이력 트리거 — 기획안·회차 변경도 보관
-- =====================================================
DROP TRIGGER IF EXISTS 투닝콘테스트_접수_이력트리거 ON 투닝콘테스트_접수;

CREATE TRIGGER 투닝콘테스트_접수_이력트리거
BEFORE UPDATE ON 투닝콘테스트_접수
FOR EACH ROW
WHEN (
  (OLD.name, OLD.school, OLD.grade, OLD.class,
   OLD.contact_type, OLD.contact_email, OLD.teacher_phone, OLD.teacher_name, OLD.parent_phone,
   OLD.section, OLD.topic, OLD.work_description,
   OLD.board_link, OLD.pdf_url, OLD.proposal_text, OLD.episodes)
  IS DISTINCT FROM
  (NEW.name, NEW.school, NEW.grade, NEW.class,
   NEW.contact_type, NEW.contact_email, NEW.teacher_phone, NEW.teacher_name, NEW.parent_phone,
   NEW.section, NEW.topic, NEW.work_description,
   NEW.board_link, NEW.pdf_url, NEW.proposal_text, NEW.episodes)
)
EXECUTE FUNCTION public.투닝콘테스트_이력적재();

-- =====================================================
-- 4. 복구 RPC — 기획안·회차 함께 되돌리기
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_복구(p_key text, p_version int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_open   CONSTANT timestamptz := '2026-09-30 00:00:00+09';
  v_close  CONSTANT timestamptz := '2026-10-30 23:59:59+09';
  v_id   uuid;
  v_snap jsonb;
  v_new  int;
BEGIN
  IF now() < v_open  THEN RAISE EXCEPTION 'not_open'; END IF;
  IF now() > v_close THEN RAISE EXCEPTION 'closed';   END IF;

  SELECT id INTO v_id FROM 투닝콘테스트_접수 WHERE submit_key = upper(btrim(p_key));
  IF v_id IS NULL THEN RAISE EXCEPTION 'not_found'; END IF;

  SELECT snapshot INTO v_snap
    FROM 투닝콘테스트_접수이력
   WHERE submission_id = v_id AND version = p_version;
  IF v_snap IS NULL THEN RAISE EXCEPTION 'version_not_found'; END IF;

  PERFORM set_config('tc.archive_reason', 'restore', true);

  UPDATE 투닝콘테스트_접수 SET
    name                = v_snap->>'name',
    school              = v_snap->>'school',
    grade               = v_snap->>'grade',
    class               = v_snap->>'class',
    contact_type        = v_snap->>'contact_type',
    contact_email       = v_snap->>'contact_email',
    teacher_phone       = v_snap->>'teacher_phone',
    teacher_name        = v_snap->>'teacher_name',
    parent_phone        = v_snap->>'parent_phone',
    section             = v_snap->>'section',
    topic               = v_snap->>'topic',
    work_description    = v_snap->>'work_description',
    board_link          = coalesce(v_snap->>'board_link', v_snap->>'link_editor'),
    pdf_url             = v_snap->>'pdf_url',
    proposal_text       = v_snap->>'proposal_text',
    episodes            = CASE WHEN jsonb_typeof(v_snap->'episodes') = 'array'
                               THEN v_snap->'episodes' ELSE NULL END,
    updated_at          = now()
  WHERE id = v_id;

  SELECT max(version) INTO v_new FROM 투닝콘테스트_접수이력 WHERE submission_id = v_id;

  RETURN jsonb_build_object('status', 'restored', 'restored_from', p_version, 'backup_version', v_new);
END;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_복구(text, int) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_복구(text, int) TO anon, authenticated;

-- =====================================================
-- 5. 리뷰 뷰 — 심사용으로 회차 수·기획안 노출
-- =====================================================
CREATE OR REPLACE VIEW 투닝콘테스트_리뷰
  WITH (security_invoker = on)
AS
  SELECT
    s.id, s.created_at, s.updated_at,
    s.name, s.school, s.grade, s.school_level, s.class,
    s.contact_type, s.contact_email,
    s.section, s.topic,
    s.board_link, s.pdf_url,
    s.proposal_text,
    s.episodes,
    CASE WHEN s.episodes IS NULL THEN 0 ELSE jsonb_array_length(s.episodes) END AS episode_count,
    s.work_description,
    s.submit_key, s.status,
    e.ai_total_score, e.ai_feedback, e.final_award, e.human_score
  FROM 투닝콘테스트_접수 s
  LEFT JOIN 투닝콘테스트_심사 e ON e.submission_id = s.id
  ORDER BY s.created_at DESC;

REVOKE ALL ON TABLE 투닝콘테스트_리뷰 FROM anon, authenticated;

-- =====================================================
-- 적용 후 확인 (선택)
-- =====================================================
-- 1) 컬럼
--    SELECT column_name FROM information_schema.columns
--     WHERE table_name='투닝콘테스트_접수' AND column_name IN ('proposal_text','episodes');
--
-- 2) 소설 부문 검증 (접수 기간 전에는 not_open 이 먼저 발생)
--    SELECT public.투닝콘테스트_제출('{"section":"novel"}'::jsonb);
