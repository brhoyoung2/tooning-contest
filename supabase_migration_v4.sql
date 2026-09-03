-- ⚠️ 이 파일의 내용은 supabase_migration_v6.sql 에 모두 포함되어 있습니다.
--    아직 실행하지 않으셨다면 이 파일 대신 v6 하나만 실행하세요.
--    (v6 은 여러 번 실행해도 안전하며 선행 항목을 자동 보정합니다)
-- =====================================================
-- [투닝콘테스트] v4 마이그레이션 — 작품 PDF 업로드
--   ① Storage 공개 버킷 submissions (PDF 전용, 20MB 제한)
--   ② 접수 테이블 pdf_url 컬럼
--   ③ 제출 RPC 가 pdf_url 을 함께 저장하도록 갱신
--   ④ SNS 가산점 입력 제거에 따른 정리 (컬럼은 보존)
--
-- 전제: supabase_schema.sql → v2 → v3 실행 완료
-- 성격: 비파괴 (기존 데이터 유지)
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

-- =====================================================
-- 1. 접수 테이블에 PDF URL 컬럼
-- =====================================================
ALTER TABLE 투닝콘테스트_접수
  ADD COLUMN IF NOT EXISTS pdf_url TEXT;

COMMENT ON COLUMN 투닝콘테스트_접수.pdf_url IS '참가자가 업로드한 작품 원본 PDF 의 공개 URL. 심사 시 링크 접근 실패에 대비한 백업 입력물.';
COMMENT ON COLUMN 투닝콘테스트_접수.sns_link IS '(사용 중지) SNS 가산점 입력란은 접수 폼에서 제거됨. 과거 데이터 보존용.';

COMMIT;

-- =====================================================
-- 2. Storage 버킷 — 트랜잭션 밖에서 실행
--    public read / anon upload, PDF 만, 20MB 제한
-- =====================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('submissions', 'submissions', true, 20971520, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE
  SET public            = EXCLUDED.public,
      file_size_limit   = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 기존 정책 정리 후 재생성
DROP POLICY IF EXISTS "투닝콘테스트_제출물_업로드" ON storage.objects;
DROP POLICY IF EXISTS "투닝콘테스트_제출물_공개읽기" ON storage.objects;

-- 업로드: anon 이 submissions 버킷의 entries/ 경로에만 새 파일 생성 가능
CREATE POLICY "투닝콘테스트_제출물_업로드" ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'submissions' AND name LIKE 'entries/%');

-- 읽기: 공개 (심사·확인용)
CREATE POLICY "투닝콘테스트_제출물_공개읽기" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'submissions');

-- UPDATE/DELETE 정책은 만들지 않음 → 참가자가 남의 파일을 덮어쓰거나 지울 수 없음

-- =====================================================
-- 3. 제출 RPC 갱신 — pdf_url 저장 추가
--    (v2 의 함수를 그대로 두고 이 블록으로 교체합니다)
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
  v_editor   text := btrim(coalesce(p_payload->>'link_editor', ''));
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

  IF position('tooning.io' in lower(v_editor)) = 0 THEN
    RAISE EXCEPTION 'invalid_link';
  END IF;

  -- 업로드된 PDF 는 우리 Storage 의 submissions 버킷 것만 허용
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
      link_editor         = v_editor,
      -- 새 PDF 를 올리지 않았으면 기존 PDF 를 유지
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
          link_proposal, work_description, link_novel, link_novel_proposal, link_editor,
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
          v_editor, v_pdf,
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
-- 4. 이력 트리거에 pdf_url 변경도 반영
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
   OLD.link_editor, OLD.pdf_url, OLD.sns_link)
  IS DISTINCT FROM
  (NEW.name, NEW.school, NEW.grade, NEW.class,
   NEW.contact_type, NEW.contact_email, NEW.teacher_phone, NEW.teacher_name, NEW.parent_phone,
   NEW.section, NEW.topic,
   NEW.link_proposal, NEW.work_description, NEW.link_novel, NEW.link_novel_proposal,
   NEW.link_editor, NEW.pdf_url, NEW.sns_link)
)
EXECUTE FUNCTION public.투닝콘테스트_이력적재();

-- =====================================================
-- 5. 복구 RPC 에도 pdf_url 반영
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
    link_editor         = v_snap->>'link_editor',
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
-- 1) 버킷 설정
--    SELECT id, public, file_size_limit, allowed_mime_types FROM storage.buckets WHERE id = 'submissions';
--
-- 2) Storage 정책 (업로드 1개 + 읽기 1개)
--    SELECT policyname FROM pg_policies WHERE schemaname='storage' AND tablename='objects';
--
-- 3) pdf_url 컬럼
--    SELECT column_name FROM information_schema.columns
--     WHERE table_name='투닝콘테스트_접수' AND column_name='pdf_url';
