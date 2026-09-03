-- =====================================================
-- [투닝콘테스트] v3 마이그레이션 — 접수 이력 보관 & 복구
--   ① 재제출(덮어쓰기) 직전 상태를 자동으로 이력 테이블에 스냅샷 저장
--   ② 접수키로 이전 제출 이력 조회
--   ③ 참가자가 원하는 버전으로 되돌리기(복구) — 복구 직전 상태도 이력에 남음
--
-- 전제: supabase_schema.sql → supabase_migration_v2.sql 실행 완료
-- 성격: 비파괴 (기존 데이터 유지)
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

-- =====================================================
-- 1. 접수 이력 테이블
-- =====================================================
CREATE TABLE IF NOT EXISTS 투닝콘테스트_접수이력 (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id  UUID NOT NULL REFERENCES 투닝콘테스트_접수(id) ON DELETE CASCADE,
  version        INT  NOT NULL,                  -- 1부터 증가 (해당 접수건 내에서)
  snapshot       JSONB NOT NULL,                 -- 덮어쓰기 직전 행 전체
  archived_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  archived_reason TEXT NOT NULL DEFAULT 'resubmit'  -- 'resubmit' | 'restore'
);

COMMENT ON TABLE 투닝콘테스트_접수이력 IS '재제출·복구로 덮어쓰기 되기 직전의 접수 내용 스냅샷. 참가자 실수 복구용.';

CREATE UNIQUE INDEX IF NOT EXISTS 투닝콘테스트_접수이력_버전_uk
  ON 투닝콘테스트_접수이력 (submission_id, version);

CREATE INDEX IF NOT EXISTS 투닝콘테스트_접수이력_접수_idx
  ON 투닝콘테스트_접수이력 (submission_id, archived_at DESC);

-- 보안: v2 와 동일하게 anon 직접 접근 전면 차단 (RPC 로만)
ALTER TABLE 투닝콘테스트_접수이력 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE 투닝콘테스트_접수이력 FROM anon, authenticated;

-- =====================================================
-- 2. 자동 스냅샷 트리거
--    내용이 실제로 바뀌는 UPDATE 에만 반응 (status/updated_at 만 바뀌면 기록 안 함)
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_이력적재()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next int;
BEGIN
  SELECT coalesce(max(version), 0) + 1 INTO v_next
    FROM 투닝콘테스트_접수이력
   WHERE submission_id = OLD.id;

  INSERT INTO 투닝콘테스트_접수이력 (submission_id, version, snapshot, archived_reason)
  VALUES (
    OLD.id,
    v_next,
    to_jsonb(OLD),
    coalesce(current_setting('tc.archive_reason', true), 'resubmit')
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS 투닝콘테스트_접수_이력트리거 ON 투닝콘테스트_접수;

CREATE TRIGGER 투닝콘테스트_접수_이력트리거
BEFORE UPDATE ON 투닝콘테스트_접수
FOR EACH ROW
WHEN (
  (OLD.name, OLD.school, OLD.grade, OLD.class,
   OLD.contact_type, OLD.contact_email, OLD.teacher_phone, OLD.teacher_name, OLD.parent_phone,
   OLD.section, OLD.topic,
   OLD.link_proposal, OLD.work_description, OLD.link_novel, OLD.link_novel_proposal,
   OLD.link_editor, OLD.sns_link)
  IS DISTINCT FROM
  (NEW.name, NEW.school, NEW.grade, NEW.class,
   NEW.contact_type, NEW.contact_email, NEW.teacher_phone, NEW.teacher_name, NEW.parent_phone,
   NEW.section, NEW.topic,
   NEW.link_proposal, NEW.work_description, NEW.link_novel, NEW.link_novel_proposal,
   NEW.link_editor, NEW.sns_link)
)
EXECUTE FUNCTION public.투닝콘테스트_이력적재();

-- =====================================================
-- 3. 이력 조회 RPC — 접수키로만
--    반환: 최신 이력부터. version 이 클수록 최근에 보관된 것.
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_이력(p_key text)
RETURNS TABLE (
  version      int,
  archived_at  timestamptz,
  reason       text,
  section      text,
  topic        text,
  link_editor  text
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
         h.snapshot->>'link_editor'
    FROM 투닝콘테스트_접수이력 h
    JOIN 투닝콘테스트_접수 s ON s.id = h.submission_id
   WHERE s.submit_key = upper(btrim(p_key))
   ORDER BY h.version DESC
   LIMIT 20;
$$;

-- =====================================================
-- 4. 복구 RPC — 지정 버전으로 되돌리기
--    복구 직전의 현재 내용도 트리거가 이력에 남기므로 되돌리기의 되돌리기도 가능
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_복구(p_key text, p_version int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 접수 기간 (KST) — v2 의 제출 RPC 와 동일하게 유지하세요.
  v_open   CONSTANT timestamptz := '2026-09-30 00:00:00+09';
  v_close  CONSTANT timestamptz := '2026-10-30 23:59:59+09';

  v_id   uuid;
  v_snap jsonb;
  v_new  int;
BEGIN
  IF now() < v_open  THEN RAISE EXCEPTION 'not_open'; END IF;
  IF now() > v_close THEN RAISE EXCEPTION 'closed';   END IF;

  SELECT id INTO v_id
    FROM 투닝콘테스트_접수
   WHERE submit_key = upper(btrim(p_key));

  IF v_id IS NULL THEN RAISE EXCEPTION 'not_found'; END IF;

  SELECT snapshot INTO v_snap
    FROM 투닝콘테스트_접수이력
   WHERE submission_id = v_id AND version = p_version;

  IF v_snap IS NULL THEN RAISE EXCEPTION 'version_not_found'; END IF;

  -- 이번 UPDATE 로 보관될 이력의 사유를 'restore' 로 표시
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
    sns_link            = v_snap->>'sns_link',
    updated_at          = now()
  WHERE id = v_id;

  SELECT max(version) INTO v_new
    FROM 투닝콘테스트_접수이력
   WHERE submission_id = v_id;

  RETURN jsonb_build_object(
    'status',        'restored',
    'restored_from', p_version,
    'backup_version', v_new      -- 복구 직전 내용이 이 버전으로 보관됨
  );
END;
$$;

-- =====================================================
-- 5. 실행 권한
-- =====================================================
REVOKE ALL ON FUNCTION public.투닝콘테스트_이력(text)      FROM public;
REVOKE ALL ON FUNCTION public.투닝콘테스트_복구(text, int) FROM public;

GRANT EXECUTE ON FUNCTION public.투닝콘테스트_이력(text)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_복구(text, int) TO anon, authenticated;

-- 트리거 함수는 anon 이 직접 호출할 필요 없음
REVOKE ALL ON FUNCTION public.투닝콘테스트_이력적재() FROM public, anon, authenticated;

COMMIT;

-- =====================================================
-- 적용 후 확인 (선택)
-- =====================================================
-- 1) 트리거 등록 확인
--    SELECT tgname FROM pg_trigger WHERE tgrelid = '투닝콘테스트_접수'::regclass AND NOT tgisinternal;
--
-- 2) 이력 조회 (더미키 → 0건이 정상)
--    SELECT * FROM public.투닝콘테스트_이력('TC-0000-0000');
--
-- 3) 접수 기간 전 복구 시도 → not_open 이 정상
--    SELECT public.투닝콘테스트_복구('TC-0000-0000', 1);
