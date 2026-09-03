-- ⚠️ 이 파일의 내용은 supabase_migration_v6.sql 에 모두 포함되어 있습니다.
--    아직 실행하지 않으셨다면 이 파일 대신 v6 하나만 실행하세요.
--    (v6 은 여러 번 실행해도 안전하며 선행 항목을 자동 보정합니다)
-- =====================================================
-- [투닝콘테스트] v5 마이그레이션 — 작품 보드 링크(board_link)로 정정
--   ① link_editor → board_link 컬럼명 변경 (충남 가이드의 공통 필드명과 통일)
--   ② 보드 링크를 4개 부문 공통 필수로 (소설 부문 접수 불가 버그 수정)
--   ③ 허용 도메인에 an-api.tooning.io(작품 공유 보드 링크) 명시
--   ④ 제출·복구 RPC, 이력 트리거, 리뷰 뷰에 반영
--
-- 전제: supabase_schema.sql → v2 → v3 → v4 실행 완료
-- 성격: 비파괴 (컬럼명만 변경, 데이터 유지)
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

-- =====================================================
-- 1. 컬럼명 변경 (이미 바뀌어 있으면 건너뜀)
-- =====================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = '투닝콘테스트_접수'
       AND column_name = 'link_editor'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = '투닝콘테스트_접수'
       AND column_name = 'board_link'
  ) THEN
    EXECUTE 'ALTER TABLE public."투닝콘테스트_접수" RENAME COLUMN link_editor TO board_link';
  END IF;
END $$;

COMMENT ON COLUMN 투닝콘테스트_접수.board_link IS '투닝에서 작품을 공유하면 생성되는 작품 보드 링크(예: https://an-api.tooning.io/canvas-share/000000). 공식 제출작이자 심사 대조용.';

COMMIT;

-- =====================================================
-- 2. 리뷰 뷰 재생성 (컬럼명 반영)
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
    s.link_proposal, s.link_novel, s.work_description,
    s.submit_key, s.status,
    e.ai_total_score, e.ai_feedback, e.final_award, e.human_score
  FROM 투닝콘테스트_접수 s
  LEFT JOIN 투닝콘테스트_심사 e ON e.submission_id = s.id
  ORDER BY s.created_at DESC;

REVOKE ALL ON TABLE 투닝콘테스트_리뷰 FROM anon, authenticated;

-- =====================================================
-- 3. 제출 RPC — board_link 로 갱신
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

  v_id       uuid;
  v_key      text;
  v_status   text;
  v_try      int := 0;
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

  -- 작품 보드 링크: 4개 부문 공통 필수, 투닝 도메인만 허용
  -- (an-api.tooning.io / tooning.io / www · plus · editor.tooning.io 모두 'tooning.io' 를 포함)
  IF position('tooning.io' in lower(v_board)) = 0 THEN
    RAISE EXCEPTION 'invalid_link';
  END IF;

  IF v_pdf IS NOT NULL AND position('/storage/v1/object/public/submissions/' in v_pdf) = 0 THEN
    RAISE EXCEPTION 'invalid_pdf';
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
      link_proposal       = nullif(btrim(coalesce(p_payload->>'link_proposal',       '')), ''),
      work_description    = nullif(btrim(coalesce(p_payload->>'work_description',    '')), ''),
      link_novel          = nullif(btrim(coalesce(p_payload->>'link_novel',          '')), ''),
      link_novel_proposal = nullif(btrim(coalesce(p_payload->>'link_novel_proposal', '')), ''),
      board_link          = v_board,
      pdf_url             = coalesce(v_pdf, pdf_url),
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
          link_proposal, work_description, link_novel, link_novel_proposal, board_link,
          pdf_url, user_agent, consent, submit_key, updated_at
        ) VALUES (
          v_name, v_school, v_grade, v_class,
          v_ctype, v_email,
          nullif(btrim(coalesce(p_payload->>'teacher_phone', '')), ''),
          nullif(btrim(coalesce(p_payload->>'teacher_name',  '')), ''),
          nullif(btrim(coalesce(p_payload->>'parent_phone',  '')), ''),
          v_section, v_topic,
          nullif(btrim(coalesce(p_payload->>'link_proposal',       '')), ''),
          nullif(btrim(coalesce(p_payload->>'work_description',    '')), ''),
          nullif(btrim(coalesce(p_payload->>'link_novel',          '')), ''),
          nullif(btrim(coalesce(p_payload->>'link_novel_proposal', '')), ''),
          v_board, v_pdf,
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
-- 4. 이력 트리거 — board_link 반영
-- =====================================================
DROP TRIGGER IF EXISTS 투닝콘테스트_접수_이력트리거 ON 투닝콘테스트_접수;

CREATE TRIGGER 투닝콘테스트_접수_이력트리거
BEFORE UPDATE ON 투닝콘테스트_접수
FOR EACH ROW
WHEN (
  (OLD.name, OLD.school, OLD.grade, OLD.class,
   OLD.contact_type, OLD.contact_email, OLD.teacher_phone, OLD.teacher_name, OLD.parent_phone,
   OLD.section, OLD.topic,
   OLD.link_proposal, OLD.work_description, OLD.link_novel, OLD.link_novel_proposal,
   OLD.board_link, OLD.pdf_url, OLD.sns_link)
  IS DISTINCT FROM
  (NEW.name, NEW.school, NEW.grade, NEW.class,
   NEW.contact_type, NEW.contact_email, NEW.teacher_phone, NEW.teacher_name, NEW.parent_phone,
   NEW.section, NEW.topic,
   NEW.link_proposal, NEW.work_description, NEW.link_novel, NEW.link_novel_proposal,
   NEW.board_link, NEW.pdf_url, NEW.sns_link)
)
EXECUTE FUNCTION public.투닝콘테스트_이력적재();

-- =====================================================
-- 5. 이력 조회 RPC — board_link 반영
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_이력(text);

CREATE FUNCTION public.투닝콘테스트_이력(p_key text)
RETURNS TABLE (
  version     int,
  archived_at timestamptz,
  reason      text,
  section     text,
  topic       text,
  board_link  text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT h.version,
         h.archived_at,
         h.archived_reason,
         h.snapshot->>'section',
         h.snapshot->>'topic',
         coalesce(h.snapshot->>'board_link', h.snapshot->>'link_editor')
    FROM 투닝콘테스트_접수이력 h
    JOIN 투닝콘테스트_접수 s ON s.id = h.submission_id
   WHERE s.submit_key = upper(btrim(p_key))
   ORDER BY h.version DESC
   LIMIT 20;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_이력(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_이력(text) TO anon, authenticated;

-- =====================================================
-- 6. 복구 RPC — board_link 반영
--    (구 스냅샷은 link_editor 키를 가지므로 coalesce 로 함께 처리)
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
    link_proposal       = v_snap->>'link_proposal',
    work_description    = v_snap->>'work_description',
    link_novel          = v_snap->>'link_novel',
    link_novel_proposal = v_snap->>'link_novel_proposal',
    board_link          = coalesce(v_snap->>'board_link', v_snap->>'link_editor'),
    pdf_url             = v_snap->>'pdf_url',
    sns_link            = v_snap->>'sns_link',
    updated_at          = now()
  WHERE id = v_id;

  SELECT max(version) INTO v_new FROM 투닝콘테스트_접수이력 WHERE submission_id = v_id;

  RETURN jsonb_build_object('status', 'restored', 'restored_from', p_version, 'backup_version', v_new);
END;
$$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_복구(text, int) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_복구(text, int) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인 (선택)
-- =====================================================
-- 1) 컬럼명
--    SELECT column_name FROM information_schema.columns
--     WHERE table_name='투닝콘테스트_접수' AND column_name IN ('board_link','link_editor');
--     -> board_link 만 나와야 정상
--
-- 2) 접수 기간 전 제출 시도 → not_open
--    SELECT public.투닝콘테스트_제출('{}'::jsonb);
