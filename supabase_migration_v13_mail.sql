-- =====================================================
-- [투닝콘테스트] v13 — 접수 완료 자동 안내 메일 (Resend)
--
--   충남 supabase_setup.sql §7 구조를 그대로 이식합니다.
--   · 첫 접수(INSERT)와 재제출(updated_at 변경)에 안내 메일 발송
--   · 수신: 접수 시 입력한 연락 이메일(지도교사 또는 보호자)
--   · 참조: leo@tooning.io, support@tooning.io
--   · 본문에 접수키(고유번호)·부문·작품 링크·최종 접수 시각 포함
--   · 메일 양식은 DB 에 저장하고 /admin 에서 수정 (코드 배포 불필요)
--   · 메일 발송이 실패해도 접수는 정상 저장 (예외를 삼킴)
--
--   ▸ 충남과 다른 점 — API 키를 함수에 하드코딩하지 않습니다.
--     공개 저장소에 키가 들어가지 않도록 설정 테이블에 넣고 읽습니다.
--     (투닝콘테스트_설정 은 RLS + REVOKE 로 anon 접근이 막혀 있습니다)
--
-- 전제: v6, v9, v10, v11, v12 실행 완료
-- 실행: Supabase 대시보드 → SQL Editor → 전체 붙여넣기 → Run
--       실행 후 아래 8번의 API 키 등록까지 해야 메일이 나갑니다.
-- =====================================================

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

BEGIN;

-- =====================================================
-- 1. 메일 양식 · 발송 설정 (기존 투닝콘테스트_설정 재사용)
-- =====================================================
INSERT INTO 투닝콘테스트_설정 (key, value, note) VALUES
  ('메일발송', 'on', '접수 완료 안내 메일 발송 여부 (on/off)'),
  ('메일제목', '[제2회 투닝 국제 공모전] 접수가 완료되었습니다 — {접수키}',
   '치환 토큰: {이름} {부문} {접수키}'),
  ('메일참조', 'leo@tooning.io,support@tooning.io', '참조(CC) 주소, 쉼표 구분'),
  ('메일발신', '제2회 투닝 국제 공모전 <support@tooning.io>', 'Resend 에서 인증된 도메인이어야 합니다'),
  ('RESEND_API_KEY', '', '⚠️ 여기에 Resend API 키(re_...)를 넣으세요. 비어 있으면 발송하지 않습니다')
ON CONFLICT (key) DO NOTHING;

INSERT INTO 투닝콘테스트_설정 (key, value, note) VALUES
  ('메일본문',
E'안녕하세요.\n제2회 투닝 국제 공모전에 작품을 접수해 주셔서 감사합니다.\n아래와 같이 {상태}되었습니다.\n\n────────────────────\n• 접수번호(고유번호): {접수키}\n• 참가자: {이름} ({학교} · {학년})\n• 부문: {부문}\n• 작품 제목: {작품제목}\n• 작품 보드 링크: {작품링크}\n• 최종 접수 시각: {최종접수}\n────────────────────\n\n▪ 접수번호는 접수 내역 조회와 이전 제출 복구에 필요합니다. 꼭 보관해 주세요.\n▪ 접수 기간(2026. 9. 30 — 10. 30) 안에는 같은 이메일로 다시 제출하면 내용이 수정되며, 이전 제출 내용은 자동으로 보관됩니다.\n▪ 1인당 1작품·1개 부문만 출품할 수 있으며, 접수 후 부문 변경은 불가합니다.\n\n심사는 11월 초, 결과 발표는 11월 중순, 시상식은 11월 말 예정입니다.\n문의: support@tooning.io\n\n감사합니다.\n투닝 드림\n\n\n─────────────────────────────\n[English]\n\nThank you for entering the 2nd Tooning International Contest.\nYour entry has been received.\n\n• Entry number: {접수키}\n• Participant: {이름} ({학교} · {학년})\n• Division: {부문}\n• Board link: {작품링크}\n• Last submitted: {최종접수}\n\nPlease keep your entry number — it is required to look up or restore your submission.\nYou may resubmit with the same email until Oct 30, 2026 to update your entry.\n\nQuestions: support@tooning.io',
   '치환 토큰: {상태} {접수키} {이름} {학교} {학년} {부문} {작품제목} {작품링크} {최종접수}')
ON CONFLICT (key) DO NOTHING;

COMMIT;

-- =====================================================
-- 2. 관리자 — 메일 양식 조회 / 저장
-- =====================================================
CREATE OR REPLACE FUNCTION public.투닝콘테스트_메일양식(p_pw text)
RETURNS TABLE (mail_on text, mail_subject text, mail_body text, mail_cc text, mail_from text, key_set boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_pw IS DISTINCT FROM '2509' THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;
  RETURN QUERY
  SELECT
    (SELECT value FROM 투닝콘테스트_설정 WHERE key = '메일발송'),
    (SELECT value FROM 투닝콘테스트_설정 WHERE key = '메일제목'),
    (SELECT value FROM 투닝콘테스트_설정 WHERE key = '메일본문'),
    (SELECT value FROM 투닝콘테스트_설정 WHERE key = '메일참조'),
    (SELECT value FROM 투닝콘테스트_설정 WHERE key = '메일발신'),
    -- 키 값 자체는 절대 반환하지 않고, 등록 여부만 알려준다
    (SELECT coalesce(btrim(value), '') <> '' FROM 투닝콘테스트_설정 WHERE key = 'RESEND_API_KEY');
END $$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_메일양식(text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_메일양식(text) TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.투닝콘테스트_메일양식저장(
  p_pw text, p_on text, p_subject text, p_body text, p_cc text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_pw IS DISTINCT FROM '2509' THEN
    PERFORM pg_sleep(1);
    RAISE EXCEPTION 'unauthorized';
  END IF;

  UPDATE 투닝콘테스트_설정 SET value = CASE WHEN p_on = 'on' THEN 'on' ELSE 'off' END,
                              updated_at = now() WHERE key = '메일발송';
  UPDATE 투닝콘테스트_설정 SET value = p_subject, updated_at = now() WHERE key = '메일제목';
  UPDATE 투닝콘테스트_설정 SET value = p_body,    updated_at = now() WHERE key = '메일본문';
  UPDATE 투닝콘테스트_설정 SET value = p_cc,      updated_at = now() WHERE key = '메일참조';
END $$;

REVOKE ALL ON FUNCTION public.투닝콘테스트_메일양식저장(text, text, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.투닝콘테스트_메일양식저장(text, text, text, text, text) TO anon, authenticated;


-- =====================================================
-- 3. 발송 트리거 — 양식을 읽어 치환 후 Resend 호출
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
        'to',       jsonb_build_array(NEW.contact_email),
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
-- 4. 트리거 등록 — 최초 접수 / 재제출
-- =====================================================
DROP TRIGGER IF EXISTS 투닝콘테스트_접수메일_신규 ON 투닝콘테스트_접수;
CREATE TRIGGER 투닝콘테스트_접수메일_신규
AFTER INSERT ON 투닝콘테스트_접수
FOR EACH ROW EXECUTE FUNCTION public.투닝콘테스트_접수완료메일();

DROP TRIGGER IF EXISTS 투닝콘테스트_접수메일_수정 ON 투닝콘테스트_접수;
CREATE TRIGGER 투닝콘테스트_접수메일_수정
AFTER UPDATE ON 투닝콘테스트_접수
FOR EACH ROW WHEN (NEW.updated_at IS DISTINCT FROM OLD.updated_at)
EXECUTE FUNCTION public.투닝콘테스트_접수완료메일();


-- =====================================================
-- 5. ⚠️ 마지막 단계 — Resend API 키 등록 (이것을 해야 메일이 나갑니다)
-- =====================================================
-- Resend(https://resend.com) 에서
--   ① tooning.io 도메인 인증(DNS 레코드 등록)
--   ② API 키 발급 (re_ 로 시작)
-- 후 아래 한 줄을 실행하세요. 키는 이 파일이나 git 에 넣지 마세요.
--
--   UPDATE 투닝콘테스트_설정 SET value = 're_실제키', updated_at = now()
--    WHERE key = 'RESEND_API_KEY';
--
-- 등록 여부만 확인 (키 값은 노출되지 않습니다)
--   SELECT key, CASE WHEN btrim(value) = '' THEN '미등록' ELSE '등록됨' END AS 상태
--     FROM 투닝콘테스트_설정 WHERE key = 'RESEND_API_KEY';
--
-- 발송 잠시 중단하려면
--   UPDATE 투닝콘테스트_설정 SET value = 'off' WHERE key = '메일발송';


-- =====================================================
-- 6. 발송 로그 확인 (pg_net 응답)
-- =====================================================
-- 최근 호출 결과 — status_code 200 이면 Resend 접수 성공
--   SELECT id, status_code, left(content, 200) AS 응답, created
--     FROM net._http_response ORDER BY id DESC LIMIT 10;
