-- =====================================================
-- [투닝콘테스트] DB 스키마
-- 네이밍 규칙: 투닝콘테스트_* (몬스터_* 동일 패턴)
-- Supabase SQL Editor에서 전체 실행
-- =====================================================

-- 기존 테이블/뷰 정리 (있을 경우 삭제)
DROP VIEW  IF EXISTS tc_review            CASCADE;
DROP VIEW  IF EXISTS submission_review    CASCADE;
DROP TABLE IF EXISTS tc_evaluations       CASCADE;
DROP TABLE IF EXISTS tc_submissions       CASCADE;
DROP TABLE IF EXISTS evaluations          CASCADE;
DROP TABLE IF EXISTS submissions          CASCADE;

-- =====================================================
-- 1. 접수 테이블
-- =====================================================
CREATE TABLE 투닝콘테스트_접수 (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at       TIMESTAMPTZ DEFAULT now(),

  -- 개인정보
  name             TEXT NOT NULL,
  school           TEXT NOT NULL,
  grade            TEXT NOT NULL,
  class            TEXT NOT NULL,
  contact_type     TEXT NOT NULL CHECK (contact_type IN ('teacher', 'parent')),
  teacher_phone    TEXT,
  teacher_name     TEXT,
  parent_phone     TEXT,

  -- 출품 부문
  section          TEXT NOT NULL CHECK (section IN ('comic', 'novel', 'cardnews', 'poster')),

  -- 작품 정보
  topic               TEXT,
  link_proposal       TEXT,       -- 기획안 링크 (novel)
  work_description    TEXT,       -- 시놉시스 (comic, cardnews)
  link_novel          TEXT,       -- 소설 본문 링크
  link_novel_proposal TEXT,       -- 포스터 기획안 링크
  link_editor         TEXT,       -- 투닝 에디터 공유 링크 (공식 제출작)

  -- 가산점
  sns_link         TEXT,

  -- 메타
  user_agent       TEXT,
  status           TEXT DEFAULT 'pending'
                   CHECK (status IN ('pending', 'reviewing', 'evaluated', 'announced'))
);

ALTER TABLE 투닝콘테스트_접수 ENABLE ROW LEVEL SECURITY;

-- 익명 사용자: INSERT만 허용
CREATE POLICY "투닝콘테스트_접수_anon_insert" ON 투닝콘테스트_접수
  FOR INSERT TO anon WITH CHECK (true);

-- =====================================================
-- 2. 심사 테이블 (AI + 인간 심사)
-- =====================================================
CREATE TABLE 투닝콘테스트_심사 (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at            TIMESTAMPTZ DEFAULT now(),
  submission_id         UUID REFERENCES 투닝콘테스트_접수(id) ON DELETE CASCADE,

  -- AI 1차 심사
  ai_score_creativity   INT CHECK (ai_score_creativity BETWEEN 1 AND 10),
  ai_score_story        INT CHECK (ai_score_story BETWEEN 1 AND 10),
  ai_score_ai_usage     INT CHECK (ai_score_ai_usage BETWEEN 1 AND 10),
  ai_score_completion   INT CHECK (ai_score_completion BETWEEN 1 AND 10),
  ai_total_score        NUMERIC(5,2),
  ai_feedback           TEXT,
  ai_evaluated_at       TIMESTAMPTZ,

  -- 인간 최종 심사
  human_score           INT,
  human_reviewer        TEXT,
  human_feedback        TEXT,
  human_evaluated_at    TIMESTAMPTZ,

  -- 수상 결과
  final_award           TEXT    -- '대상' | '금상' | '은상' | '동상' | '장려상'
);

ALTER TABLE 투닝콘테스트_심사 ENABLE ROW LEVEL SECURITY;
-- 심사 테이블은 service_role(관리자)만 접근

-- =====================================================
-- 3. 리뷰 뷰 (접수 + 심사 조인, 관리자 페이지용)
-- =====================================================
CREATE OR REPLACE VIEW 투닝콘테스트_리뷰 AS
  SELECT
    s.id,
    s.created_at,
    s.name,
    s.school,
    s.grade,
    s.section,
    s.topic,
    s.link_editor,
    s.link_proposal,
    s.link_novel,
    s.work_description,
    s.sns_link,
    s.status,
    e.ai_total_score,
    e.ai_feedback,
    e.final_award,
    e.human_score
  FROM 투닝콘테스트_접수 s
  LEFT JOIN 투닝콘테스트_심사 e ON e.submission_id = s.id
  ORDER BY s.created_at DESC;
