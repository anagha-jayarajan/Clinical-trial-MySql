-- =====================================================================
-- Clinical Trial Data Analysis in MySQL (MySQL 8.0+)
-- Phase II trial: Drug A vs Placebo, systolic/diastolic blood pressure
-- Data is synthetic (randomly generated); exact numbers change per run.
-- =====================================================================

-- ---------- 1. BUILD DATABASE, TABLES, SYNTHETIC DATA ----------
DROP DATABASE IF EXISTS clinical_trial;
CREATE DATABASE clinical_trial;
USE clinical_trial;

CREATE TABLE dm (
  subjid INT PRIMARY KEY,
  age INT, sex CHAR(1), arm VARCHAR(10), site VARCHAR(10)
);

CREATE TABLE vs (
  subjid INT, visit VARCHAR(10), visitnum INT, sbp INT, dbp INT,
  PRIMARY KEY (subjid, visitnum),
  FOREIGN KEY (subjid) REFERENCES dm(subjid)
);

CREATE TABLE ae (
  aeid INT AUTO_INCREMENT PRIMARY KEY,
  subjid INT, aeterm VARCHAR(40), severity VARCHAR(10), related VARCHAR(3),
  FOREIGN KEY (subjid) REFERENCES dm(subjid)
);

INSERT INTO dm (subjid, age, sex, arm, site)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i+1 FROM n WHERE i < 60)
SELECT 1000+i, 35+FLOOR(RAND()*40), IF(RAND()<0.5,'M','F'),
       IF(i%2=0,'Drug A','Placebo'), CONCAT('Site',1+i%3)
FROM n;

INSERT INTO vs (subjid, visit, visitnum, sbp, dbp)
SELECT d.subjid, v.visit, v.num,
  ROUND(150 + RAND()*20 - 10 - IF(d.arm='Drug A', v.drop_d, v.drop_p)),
  ROUND(95 + RAND()*10 - 5 - IF(d.arm='Drug A', v.drop_d, v.drop_p)*0.5)
FROM dm d
JOIN (SELECT 'Baseline' visit, 1 num, 0 drop_d, 0 drop_p
      UNION ALL SELECT 'Week 4', 2, 8, 2
      UNION ALL SELECT 'Week 8', 3, 15, 3) v;

INSERT INTO ae (subjid, aeterm, severity, related)
SELECT subjid,
  ELT(1+FLOOR(RAND()*4),'Headache','Dizziness','Nausea','Fatigue'),
  ELT(1+FLOOR(RAND()*3),'Mild','Moderate','Severe'),
  IF(RAND()<0.5,'Yes','No')
FROM dm
WHERE RAND() < IF(arm='Drug A', 0.6, 0.35);

-- ---------- 2. DATA QUALITY CHECKS (no rows returned = clean) ----------
SELECT 'dm' AS tbl, COUNT(*) AS n FROM dm
UNION ALL SELECT 'vs', COUNT(*) FROM vs
UNION ALL SELECT 'ae', COUNT(*) FROM ae;

SELECT * FROM vs WHERE subjid NOT IN (SELECT subjid FROM dm);                    -- orphans
SELECT subjid, COUNT(*) AS n_visits FROM vs GROUP BY subjid HAVING COUNT(*) < 3; -- missing visits
SELECT * FROM vs WHERE sbp NOT BETWEEN 80 AND 220 OR dbp NOT BETWEEN 40 AND 130; -- implausible
SELECT * FROM vs WHERE sbp <= dbp;                                               -- entry errors

-- ---------- 3. ANALYSIS VIEW (change from baseline) ----------
CREATE OR REPLACE VIEW advs AS
SELECT v.subjid, d.arm, d.age, d.sex, d.site,
       v.visit, v.visitnum, v.sbp, v.dbp,
       b.sbp AS base_sbp,
       v.sbp - b.sbp AS chg
FROM vs v
JOIN vs b ON b.subjid = v.subjid AND b.visitnum = 1
JOIN dm d ON d.subjid = v.subjid;

-- ---------- 4. REPORT TABLES ----------
-- Table 1: Demographics
SELECT arm, COUNT(*) AS n,
  ROUND(AVG(age),1) AS mean_age, MIN(age) AS min_age, MAX(age) AS max_age,
  SUM(sex='M') AS n_male
FROM dm GROUP BY arm;

-- Table 2: SBP by visit and arm
SELECT arm, visit, COUNT(*) AS n,
  ROUND(AVG(sbp),1) AS mean_sbp, ROUND(AVG(chg),1) AS mean_change
FROM advs GROUP BY arm, visitnum, visit ORDER BY visitnum, arm;

-- Table 3: Efficacy at Week 8 (Welch t-statistic; |t| > 2 ~ p < 0.05)
WITH s AS (
  SELECT arm, COUNT(*) AS n, AVG(chg) AS m, VAR_SAMP(chg) AS v
  FROM advs WHERE visitnum = 3 GROUP BY arm
)
SELECT ROUND(a.m,1) AS mean_chg_drug, ROUND(p.m,1) AS mean_chg_placebo,
  ROUND(a.m - p.m,1) AS difference,
  ROUND((a.m - p.m) / SQRT(a.v/a.n + p.v/p.n), 2) AS t_statistic
FROM s a JOIN s p ON a.arm = 'Drug A' AND p.arm = 'Placebo';

-- Table 3b: Responders (SBP drop of 10 mmHg or more at Week 8)
SELECT arm, COUNT(*) AS n, SUM(chg <= -10) AS responders,
  ROUND(100*SUM(chg <= -10)/COUNT(*),1) AS pct_responders
FROM advs WHERE visitnum = 3 GROUP BY arm;

-- Table 4: Patients with at least one AE
SELECT d.arm, COUNT(DISTINCT d.subjid) AS n_subjects,
  COUNT(DISTINCT a.subjid) AS subjects_with_ae,
  ROUND(100*COUNT(DISTINCT a.subjid)/COUNT(DISTINCT d.subjid),1) AS pct_with_ae
FROM dm d LEFT JOIN ae a ON a.subjid = d.subjid
GROUP BY d.arm;

-- Table 5: AE terms by arm
SELECT a.aeterm, SUM(d.arm='Drug A') AS drug_a, SUM(d.arm='Placebo') AS placebo
FROM ae a JOIN dm d USING (subjid)
GROUP BY a.aeterm ORDER BY a.aeterm;

-- Table 6: Severe AEs related to the drug
SELECT d.subjid, d.arm, a.aeterm, a.severity
FROM ae a JOIN dm d USING (subjid)
WHERE a.severity='Severe' AND a.related='Yes';

-- ---------- 5. REUSABLE STORED PROCEDURE ----------
DROP PROCEDURE IF EXISTS sp_efficacy;
DELIMITER //
CREATE PROCEDURE sp_efficacy(IN p_visitnum INT)
BEGIN
  WITH s AS (
    SELECT arm, COUNT(*) AS n, AVG(chg) AS m, VAR_SAMP(chg) AS v
    FROM advs WHERE visitnum = p_visitnum GROUP BY arm
  )
  SELECT p_visitnum AS visitnum,
    ROUND(a.m,1) AS drug_mean_chg, ROUND(p.m,1) AS placebo_mean_chg,
    ROUND(a.m - p.m,1) AS difference,
    ROUND((a.m - p.m) / SQRT(a.v/a.n + p.v/p.n), 2) AS t_statistic
  FROM s a JOIN s p ON a.arm='Drug A' AND p.arm='Placebo';
END //
DELIMITER ;

CALL sp_efficacy(2);  -- Week 4
CALL sp_efficacy(3);  -- Week 8
