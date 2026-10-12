-- =====================================================
-- [투닝콘테스트] v19 — 접수 확인 메일 발송 로그
--
--   문제: 메일 발송은 pg_net 으로 비동기 처리되고, 트리거는 실패를
--   삼키도록 되어 있습니다. 그래서 Resend 가 거절해도(할당량 초과,
--   주소 오타로 인한 반송 등) 접수는 저장되고 메일만 조용히 사라집니다.
--   접수번호는 메일로만 안내되므로, 참가자는 접수 여부를 알 수 없습니다.
--
--   이 마이그레이션은 '발송을 시도했다' 는 흔적을 남겨서
--   관리자 화면에서 성공·실패를 눈으로 확인할 수 있게 합니다.
--
--   · 메일 발송 동작 자체는 바꾸지 않습니다 (수신자·본문 동일)
--   · 로그 기록이 실패해도 접수는 그대로 저장됩니다
--
-- 전제: v13, v18 실행 완료
-- 성격: 비파괴 · 여러 번 실행해도 안전
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
-- =====================================================

BEGIN;

CREATE TABLE IF NOT EXISTS 투닝콘테스트_메일로그 (
  id         bigserial PRIMARY KEY,
  submit_key text,
  request_id bigint,
  recipients jsonb,
  op         text,
  note       text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS 투닝콘테스트_메일로그_시각_idx
  ON 투닝콘테스트_메일로그 (created_at DESC);

ALTER TABLE 투닝콘테스트_메일로그 ENABLE ROW LEVEL SECURITY;
-- 정책을 두지 않는다 = anon 은 접근 불가. 읽기는 아래 RPC 로만.

COMMIT;

-- =====================================================
-- 1) 메일 트리거 — 발송 요청 id 를 로그에 남긴다
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
  v_req   bigint;
  v_to    jsonb;
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

  -- 본인 이메일을 적었으면 함께 수신자로 넣는다
  v_to := CASE WHEN NEW.student_email IS NULL OR btrim(NEW.student_email) = ''
               THEN jsonb_build_array(NEW.contact_email)
               ELSE jsonb_build_array(NEW.contact_email, NEW.student_email) END;

  BEGIN
    SELECT net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || v_api,
        'Content-Type',  'application/json',
        -- api.resend.com 은 Cloudflare 뒤라 User-Agent 없으면 1010 으로 차단됨
        'User-Agent',    'tooning-contest/1.0 (+https://tooning.io)'
      ),
      body := jsonb_build_object(
        'from',     v_from,
        'to',       v_to,
        'cc',       (SELECT jsonb_agg(btrim(x)) FROM unnest(string_to_array(v_cc, ',')) AS x
                      WHERE btrim(x) <> ''),
        'reply_to', 'support@tooning.io',
        'subject',  v_subj,
        'html',     v_html
      )
    ) INTO v_req;

    -- 발송 요청 자체를 남겨 둔다. 나중에 응답과 맞춰 보기 위한 흔적이다.
    INSERT INTO 투닝콘테스트_메일로그 (submit_key, request_id, recipients, op)
    VALUES (NEW.submit_key, v_req, v_to, TG_OP);
  EXCEPTION WHEN others THEN
    -- 메일도 로그도 접수를 막지 않는다
    BEGIN
      INSERT INTO 투닝콘테스트_메일로그 (submit_key, request_id, recipients, op, note)
      VALUES (NEW.submit_key, NULL, v_to, TG_OP, left(SQLERRM, 300));
    EXCEPTION WHEN others THEN NULL; END;
  END;

  RETURN NEW;
END $$;

-- =====================================================
-- 2) 관리자용 메일 상태 조회
--
--    pg_net 의 응답(net._http_response)은 몇 시간 뒤 자동 정리됩니다.
--    그래서 최근 건은 실제 응답 코드까지, 오래된 건은 '발송 시도함'
--    까지만 확인됩니다. status 값의 의미는 아래와 같습니다.
--      sent     : Resend 가 정상 접수 (2xx)
--      failed   : Resend 가 거절 (할당량 초과·주소 오류 등) — 확인 필요
--      queued   : 요청은 보냈고 응답 기록이 아직/이미 없음
--      error    : 발송 요청 자체가 실패 (note 참고) — 확인 필요
-- =====================================================
DROP FUNCTION IF EXISTS public.투닝콘테스트_메일상태(text, int);

CREATE FUNCTION public.투닝콘테스트_메일상태(p_pw text, p_limit int DEFAULT 200)
RETURNS TABLE (
  created_at  timestamptz,
  submit_key  text,
  recipients  jsonb,
  op          text,
  status      text,
  status_code int,
  detail      text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $fn$
DECLARE
  v_pw CONSTANT text := '2509';   -- ← 관리자 목록 RPC 와 동일하게 유지
BEGIN
  IF p_pw IS DISTINCT FROM v_pw THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;

  RETURN QUERY
  SELECT l.created_at,
         l.submit_key,
         l.recipients,
         l.op,
         CASE
           WHEN l.request_id IS NULL                      THEN 'error'
           WHEN r.status_code BETWEEN 200 AND 299         THEN 'sent'
           WHEN r.status_code IS NOT NULL                 THEN 'failed'
           ELSE 'queued'
         END::text,
         r.status_code,
         coalesce(l.note, left(r.content, 300))
    FROM 투닝콘테스트_메일로그 l
    LEFT JOIN net._http_response r ON r.id = l.request_id
   ORDER BY l.created_at DESC
   LIMIT greatest(1, least(coalesce(p_limit, 200), 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_메일상태(text, int) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_메일상태(text, int) TO anon, authenticated;

-- =====================================================
-- 적용 후 확인
-- =====================================================
-- 테스트 접수를 한 건 넣어 본 뒤:
--   SELECT created_at, submit_key, status, status_code, left(detail, 80)
--     FROM public.투닝콘테스트_메일상태('2509', 20);
--
-- status 가 failed / error 인 행이 있으면 그 참가자는 확인 메일을
-- 받지 못한 것이므로, 접수번호를 따로 안내해 주셔야 합니다.
