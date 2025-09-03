좋아! 아래는 MySQL 8.0 기준, 자주 쓰는 리텐션 정의별 쿼리 템플릿 모음이야.
(가정 스키마) events(user_id VARCHAR, event_date DATE) — 날짜당 1회 이상 방문 로그 존재.

⸻

0) 공통: 날짜/코호트 준비

-- 각 유저의 코호트(첫 방문일)
WITH cohort AS (
  SELECT user_id, MIN(event_date) AS join_date
  FROM events
  GROUP BY user_id
)
SELECT * FROM cohort; -- 확인용


⸻

1) Cohort D+N Retention (정통 리텐션)

(1-1) Long 형태 (모든 N)

WITH
cohort AS (
  SELECT user_id, MIN(event_date) AS join_date
  FROM events GROUP BY user_id
),
lagged AS (
  SELECT e.user_id, c.join_date,
         DATEDIFF(e.event_date, c.join_date) AS day_lag
  FROM events e
  JOIN cohort c ON e.user_id = c.user_id
),
bounds AS ( SELECT 30 AS max_n )  -- ← 보고 싶은 최대 N (D+30 등)
SELECT
  join_date,
  day_lag,                                   -- D+N
  COUNT(DISTINCT user_id) AS retained_users, -- D+N 당일 방문자(중복제거)
  COUNT(DISTINCT user_id)
    / COUNT(DISTINCT CASE WHEN day_lag = 0 THEN user_id END)
      OVER (PARTITION BY join_date) AS retention_rate
FROM lagged, bounds
WHERE day_lag BETWEEN 0 AND (SELECT max_n FROM bounds)
GROUP BY join_date, day_lag
ORDER BY join_date, day_lag;

(1-2) Wide/Pivot (D0~D7 예시)

WITH
cohort AS (
  SELECT user_id, MIN(event_date) AS join_date
  FROM events GROUP BY user_id
),
lagged AS (
  SELECT e.user_id, c.join_date,
         DATEDIFF(e.event_date, c.join_date) AS day_lag
  FROM events e JOIN cohort c ON e.user_id = c.user_id
)
SELECT
  join_date,
  COUNT(DISTINCT CASE WHEN day_lag = 0 THEN user_id END) AS d0,
  COUNT(DISTINCT CASE WHEN day_lag = 1 THEN user_id END) AS d1,
  COUNT(DISTINCT CASE WHEN day_lag = 2 THEN user_id END) AS d2,
  COUNT(DISTINCT CASE WHEN day_lag = 3 THEN user_id END) AS d3,
  COUNT(DISTINCT CASE WHEN day_lag = 4 THEN user_id END) AS d4,
  COUNT(DISTINCT CASE WHEN day_lag = 5 THEN user_id END) AS d5,
  COUNT(DISTINCT CASE WHEN day_lag = 6 THEN user_id END) AS d6,
  COUNT(DISTINCT CASE WHEN day_lag = 7 THEN user_id END) AS d7
FROM lagged
WHERE day_lag BETWEEN 0 AND 7
GROUP BY join_date
ORDER BY join_date;


⸻

2) Rolling Retention (D+N까지 한 번이라도 돌아오면 잔존)

WITH
cohort AS (
  SELECT user_id, MIN(event_date) AS join_date
  FROM events GROUP BY user_id
),
first_return AS (
  -- 가입 후 최초 재방문 시차 (D+1 이상만)
  SELECT
    c.user_id, c.join_date,
    MIN(DATEDIFF(e.event_date, c.join_date)) AS first_return_lag
  FROM cohort c
  JOIN events e
    ON e.user_id = c.user_id AND e.event_date > c.join_date
  GROUP BY c.user_id, c.join_date
),
-- 0..N 생성을 위한 수열
RECURSIVE n AS (
  SELECT 0 AS day_lag
  UNION ALL SELECT day_lag + 1 FROM n WHERE day_lag < 30    -- ← max N
)
SELECT
  c.join_date,
  n.day_lag,
  COUNT(DISTINCT c.user_id)                              AS cohort_size,
  COUNT(DISTINCT CASE WHEN fr.first_return_lag IS NOT NULL
                        AND fr.first_return_lag <= n.day_lag
                      THEN c.user_id END)               AS retained_users,
  COUNT(DISTINCT CASE WHEN fr.first_return_lag IS NOT NULL
                        AND fr.first_return_lag <= n.day_lag
                      THEN c.user_id END)
  / COUNT(DISTINCT c.user_id) AS rolling_retention
FROM cohort c
CROSS JOIN n
LEFT JOIN first_return fr
  ON fr.user_id = c.user_id AND fr.join_date = c.join_date
GROUP BY c.join_date, n.day_lag
ORDER BY c.join_date, n.day_lag;


⸻

3) Unbounded Retention (언젠가 한 번이라도 돌아오면 잔존)

기간 제한 없이 “재방문한 적 있음” 기준 — 코호트별 단일 값

WITH
cohort AS (
  SELECT user_id, MIN(event_date) AS join_date
  FROM events GROUP BY user_id
),
returned AS (
  SELECT DISTINCT c.user_id, c.join_date
  FROM cohort c
  JOIN events e
    ON e.user_id = c.user_id AND e.event_date > c.join_date
)
SELECT
  c.join_date,
  COUNT(DISTINCT c.user_id)                              AS cohort_size,
  COUNT(DISTINCT r.user_id)                              AS ever_returned,
  COUNT(DISTINCT r.user_id)/COUNT(DISTINCT c.user_id)    AS unbounded_retention
FROM cohort c
LEFT JOIN returned r
  ON r.user_id = c.user_id AND r.join_date = c.join_date
GROUP BY c.join_date
ORDER BY c.join_date;


⸻

4) 주차 Cohort Retention (Week Cohort, W+K)

WITH
cohort AS (
  SELECT user_id,
         STR_TO_DATE(CONCAT(YEARWEEK(MIN(event_date), 1),' Monday'), '%X%V %W') AS join_week -- ISO 주 시작 월요일
  FROM events GROUP BY user_id
),
lagged AS (
  SELECT
    e.user_id, c.join_week,
    TIMESTAMPDIFF(WEEK, c.join_week, e.event_date) AS week_lag
  FROM events e
  JOIN cohort c ON e.user_id = c.user_id
)
SELECT
  join_week,
  week_lag,
  COUNT(DISTINCT user_id) AS retained_users,
  COUNT(DISTINCT user_id)
   / COUNT(DISTINCT CASE WHEN week_lag = 0 THEN user_id END)
     OVER (PARTITION BY join_week) AS retention_rate
FROM lagged
WHERE week_lag BETWEEN 0 AND 12 -- 예: 12주
GROUP BY join_week, week_lag
ORDER BY join_week, week_lag;


⸻

5) “기준일 활동자” 기반 Day-N Retention (코호트X, 운영지표)

특정 기준일의 활성 사용자 중 N일 뒤에도 활성 비율

WITH
daily_users AS (
  SELECT DATE(event_date) AS d, user_id
  FROM events
  GROUP BY DATE(event_date), user_id
),
RECURSIVE n AS (
  SELECT 1 AS lag UNION ALL SELECT lag+1 FROM n WHERE lag < 7  -- D+1..D+7
)
SELECT
  du.d                              AS base_date,
  n.lag,
  COUNT(DISTINCT du.user_id)        AS base_users,
  COUNT(DISTINCT du2.user_id)       AS returned_users,
  COUNT(DISTINCT du2.user_id)/COUNT(DISTINCT du.user_id) AS dayN_retention
FROM daily_users du
CROSS JOIN n
LEFT JOIN daily_users du2
  ON du2.user_id = du.user_id
 AND du2.d = DATE_ADD(du.d, INTERVAL n.lag DAY)
GROUP BY du.d, n.lag
ORDER BY du.d, n.lag;


⸻

6) 보너스: Stickiness (DAU/MAU)

WITH
daily AS (
  SELECT DATE(event_date) AS d, COUNT(DISTINCT user_id) AS dau
  FROM events GROUP BY DATE(event_date)
),
monthly AS (
  SELECT DATE_FORMAT(event_date, '%Y-%m-01') AS m, COUNT(DISTINCT user_id) AS mau
  FROM events GROUP BY DATE_FORMAT(event_date, '%Y-%m-01')
),
map AS (
  SELECT d.d, DATE_FORMAT(d.d, '%Y-%m-01') AS m, d.dau
  FROM daily d
)
SELECT
  m.m AS month,
  AVG(dau)                 AS avg_dau,
  m.mau,
  AVG(dau) / m.mau         AS stickiness_dau_mau
FROM map d
JOIN monthly m ON m.m = d.m
GROUP BY m.m, m.mau
ORDER BY m.m;


⸻

성능 팁
	•	인덱스: (event_date, user_id) 복합 인덱스 강추.
	•	일자 캐스팅을 자주 쓰면 생성 칼럼 event_dt DATE GENERATED ALWAYS AS (DATE(event_date)) + 인덱스.
	•	대용량이면 중간 집계 테이블(일자별 유저 dedup) 운영.

원하는 기간(N), 기준일 범위, 앱/웹 구분 같은 필터가 있으면 변수화해 다시 정리해줄게!