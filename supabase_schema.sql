-- =====================================================
-- 투닝 국제 공모전 DB 스키마
-- Supabase SQL Editor에서 실행하세요
-- =====================================================

-- 1. 접수 테이블
CREATE TABLE IF NOT EXISTS submissions (
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
  topic            TEXT,
  link_proposal    TEXT,          -- 기획안 링크 (novel용)
  work_description TEXT,          -- 시놉시스 / 설명 (comic, cardnews)
  link_novel       TEXT,          -- 소설 본문 링크
  link_novel_proposal TEXT,       -- 포스터 기획안 링크
  link_editor      TEXT,          -- 투닝 에디터 공유 링크 (공식 제출작)

  -- 가산점
  sns_link         TEXT,

  -- 메타
  user_agent       TEXT,
  status           TEXT DEFAULT 'pending'
                   CHECK (status IN ('pending', 'reviewing', 'evaluated', 'announced'))
);

-- RLS 활성화
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;

-- 익명 사용자: INSERT만 허용 (개인정보 보호)
CREATE POLICY "anon_can_insert" ON submissions
  FOR INSERT TO anon WITH CHECK (true);

-- =====================================================

-- 2. 평가 테이블 (AI + 인간 심사)
CREATE TABLE IF NOT EXISTS evaluations (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at            TIMESTAMPTZ DEFAULT now(),
  submission_id         UUID REFERENCES submissions(id) ON DELETE CASCADE,

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
  final_award           TEXT   -- '대상' | '금상' | '은상' | '동상' | '장려상' | NULL
);

ALTER TABLE evaluations ENABLE ROW LEVEL SECURITY;
-- evaluations는 service_role(관리자)만 접근

-- =====================================================

-- 3. 편의 뷰: 접수 + 평가 조인 (관리자 페이지용)
CREATE OR REPLACE VIEW submission_review AS
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
  FROM submissions s
  LEFT JOIN evaluations e ON e.submission_id = s.id
  ORDER BY s.created_at DESC;
