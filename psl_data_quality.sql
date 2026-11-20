-- Step 1: completeness, comparing row counts. The question is whether every source row reached the warehouse
SELECT check_name, source_rows, warehouse_rows, source_rows - warehouse_rows AS difference
FROM (
    SELECT 'matches -> dim_match' AS check_name,
           (SELECT COUNT(*) FROM psl_staging.stg_matches) AS source_rows,
           (SELECT COUNT(*) FROM psl_dw.dim_match)        AS warehouse_rows
    UNION ALL
    SELECT 'distinct players -> dim_player (without the -1 row)',
           (SELECT COUNT(DISTINCT player_id) FROM psl_staging.stg_match_players),
           (SELECT COUNT(*) FROM psl_dw.dim_player WHERE player_key <> -1)
    UNION ALL
    SELECT 'match_players -> fact_match_player',
           (SELECT COUNT(*) FROM psl_staging.stg_match_players),
           (SELECT COUNT(*) FROM psl_dw.fact_match_player)
    UNION ALL
    SELECT 'over_snapshot -> fact_over_snapshot',
           (SELECT COUNT(*) FROM psl_staging.stg_over_snapshot),
           (SELECT COUNT(*) FROM psl_dw.fact_over_snapshot)
    UNION ALL
    SELECT 'deliveries -> fact_delivery',
           (SELECT COUNT(*) FROM psl_staging.stg_deliveries),
           (SELECT COUNT(*) FROM psl_dw.fact_delivery)
) t;







-- Step 2: completeness, looking for missing values.
SELECT 'fact_delivery: batter, bowler or non-striker is -1 (must be 0)' AS check_name, COUNT(*) AS rows_found
FROM psl_dw.fact_delivery
WHERE batter_key = -1 OR bowler_key = -1 OR non_striker_key = -1
UNION ALL
SELECT 'dim_player: empty names (must be 0)', COUNT(*)
FROM psl_dw.dim_player WHERE TRIM(player_name) = ''
UNION ALL
SELECT 'dim_venue: city empty or Unknown (must be 0)', COUNT(*)
FROM psl_dw.dim_venue WHERE TRIM(city) = '' OR city = 'Unknown'
UNION ALL
SELECT 'dim_match: win_by_value is NULL (ties and no results)', COUNT(*)
FROM psl_dw.dim_match WHERE win_by_value IS NULL
UNION ALL
SELECT 'dim_match: match_number is NULL', COUNT(*)
FROM psl_dw.dim_match WHERE match_number IS NULL
UNION ALL
SELECT 'dim_match: winner is Not Applicable', COUNT(*)
FROM psl_dw.dim_match WHERE winner = 'Not Applicable'
UNION ALL
SELECT 'dim_match: player_of_match is Not Applicable', COUNT(*)
FROM psl_dw.dim_match WHERE player_of_match = 'Not Applicable';

-- Above Code Output (These results are all as expected)
-- "fact_delivery: batter, bowler or non-striker is -1 (must be 0)"	0
-- "dim_player: empty names (must be 0)"	0
-- "dim_venue: city empty or Unknown (must be 0)"	0
-- "dim_match: win_by_value is NULL (ties and no results)"	7
-- "dim_match: match_number is NULL"	44
-- "dim_match: winner is Not Applicable"	7
-- "dim_match: player_of_match is Not Applicable"	5







-- Step 3: accuracy, reconciling the totals. Here we prove that the numbers in the warehouse are the same as in the source
SELECT measure, source_total, warehouse_total, source_total - warehouse_total AS difference
FROM (
    SELECT 'runs_batter' AS measure,
           (SELECT SUM(runs_batter::INT) FROM psl_staging.stg_deliveries) AS source_total,
           (SELECT SUM(runs_batter) FROM psl_dw.fact_delivery)            AS warehouse_total
    UNION ALL
    SELECT 'runs_extras',
           (SELECT SUM(runs_extras::INT) FROM psl_staging.stg_deliveries),
           (SELECT SUM(runs_extras) FROM psl_dw.fact_delivery)
    UNION ALL
    SELECT 'runs_total',
           (SELECT SUM(runs_total::INT) FROM psl_staging.stg_deliveries),
           (SELECT SUM(runs_total) FROM psl_dw.fact_delivery)
    UNION ALL
    SELECT 'runs_conceded',
           (SELECT SUM(runs_conceded::INT) FROM psl_staging.stg_deliveries),
           (SELECT SUM(runs_conceded) FROM psl_dw.fact_delivery)
    UNION ALL
    SELECT 'is_legal_ball',
           (SELECT SUM(is_legal_ball::INT) FROM psl_staging.stg_deliveries),
           (SELECT SUM(is_legal_ball) FROM psl_dw.fact_delivery)
    UNION ALL
    SELECT 'balls_faced',
           (SELECT SUM(balls_faced::INT) FROM psl_staging.stg_deliveries),
           (SELECT SUM(balls_faced) FROM psl_dw.fact_delivery)
    UNION ALL
    SELECT 'wicket_count',
           (SELECT SUM(wicket_count::INT) FROM psl_staging.stg_deliveries),
           (SELECT SUM(wicket_count) FROM psl_dw.fact_delivery)
    UNION ALL
    SELECT 'is_dot_ball',
           (SELECT COUNT(*) FROM psl_staging.stg_deliveries WHERE is_legal_ball = '1' AND runs_total = '0'),
           (SELECT SUM(is_dot_ball) FROM psl_dw.fact_delivery)
) t;








-- Step 4: accuracy across two fact tables. fact_delivery and fact_over_snapshot were loaded from different files. 
-- If both are correct, they must agree at the innings level and at the over level.
SELECT 'innings: runs, wickets or legal balls differ from the last over of fact_over_snapshot' AS check_name,
       COUNT(*) AS problem_rows
FROM (SELECT match_key, innings_key, SUM(runs_total) AS runs, SUM(wicket_count) AS wickets, SUM(is_legal_ball) AS balls
      FROM psl_dw.fact_delivery GROUP BY match_key, innings_key) d
FULL JOIN (SELECT DISTINCT ON (s1.match_key, s1.innings_key) s1.match_key, s1.innings_key,
                  s1.cumulative_runs AS runs, s1.cumulative_wickets AS wickets, s1.cumulative_legal_balls AS balls
           FROM psl_dw.fact_over_snapshot s1
           JOIN psl_dw.dim_over o ON o.over_key = s1.over_key
           ORDER BY s1.match_key, s1.innings_key, o.over_no DESC) s
       ON s.match_key = d.match_key AND s.innings_key = d.innings_key
WHERE d.runs IS DISTINCT FROM s.runs OR d.wickets IS DISTINCT FROM s.wickets OR d.balls IS DISTINCT FROM s.balls
UNION ALL
SELECT 'overs: runs_in_over differs from the sum of the balls in that over', COUNT(*)
FROM (SELECT match_key, innings_key, over_key, SUM(runs_total) AS runs
      FROM psl_dw.fact_delivery GROUP BY match_key, innings_key, over_key) d
FULL JOIN psl_dw.fact_over_snapshot s
       ON s.match_key = d.match_key AND s.innings_key = d.innings_key AND s.over_key = d.over_key
WHERE d.runs IS DISTINCT FROM s.runs_in_over;

-- Both accuracy checks are 0, so the two fact tables agree with each other









-- Step 5: integrity, looking for orphan keys. The question here is whether any fact row points to a dimension row that doesn’t exist
SELECT 'fact_delivery' AS fact_table, COUNT(*) AS rows_without_matching_dimension
FROM psl_dw.fact_delivery f
LEFT JOIN psl_dw.dim_match dm          ON dm.match_key = f.match_key
LEFT JOIN psl_dw.dim_innings di        ON di.innings_key = f.innings_key
LEFT JOIN psl_dw.dim_date dd           ON dd.date_key = f.date_key
LEFT JOIN psl_dw.dim_venue dv          ON dv.venue_key = f.venue_key
LEFT JOIN psl_dw.dim_over dov          ON dov.over_key = f.over_key
LEFT JOIN psl_dw.dim_team bat          ON bat.team_key = f.batting_team_key
LEFT JOIN psl_dw.dim_team bowl         ON bowl.team_key = f.bowling_team_key
LEFT JOIN psl_dw.dim_player p1         ON p1.player_key = f.batter_key
LEFT JOIN psl_dw.dim_player p2         ON p2.player_key = f.bowler_key
LEFT JOIN psl_dw.dim_player p3         ON p3.player_key = f.non_striker_key
LEFT JOIN psl_dw.dim_player p4         ON p4.player_key = f.dismissed_player_key
LEFT JOIN psl_dw.dim_dismissal_type dt ON dt.dismissal_type_key = f.dismissal_type_key
LEFT JOIN psl_dw.dim_extra_type et     ON et.extra_type_key = f.extra_type_key
WHERE dm.match_key IS NULL OR di.innings_key IS NULL OR dd.date_key IS NULL OR dv.venue_key IS NULL
   OR dov.over_key IS NULL OR bat.team_key IS NULL OR bowl.team_key IS NULL OR p1.player_key IS NULL
   OR p2.player_key IS NULL OR p3.player_key IS NULL OR p4.player_key IS NULL
   OR dt.dismissal_type_key IS NULL OR et.extra_type_key IS NULL
UNION ALL
SELECT 'fact_over_snapshot', COUNT(*)
FROM psl_dw.fact_over_snapshot f
LEFT JOIN psl_dw.dim_match dm    ON dm.match_key = f.match_key
LEFT JOIN psl_dw.dim_innings di  ON di.innings_key = f.innings_key
LEFT JOIN psl_dw.dim_over dov    ON dov.over_key = f.over_key
LEFT JOIN psl_dw.dim_date dd     ON dd.date_key = f.date_key
LEFT JOIN psl_dw.dim_venue dv    ON dv.venue_key = f.venue_key
LEFT JOIN psl_dw.dim_team bat    ON bat.team_key = f.batting_team_key
LEFT JOIN psl_dw.dim_team bowl   ON bowl.team_key = f.bowling_team_key
WHERE dm.match_key IS NULL OR di.innings_key IS NULL OR dov.over_key IS NULL OR dd.date_key IS NULL
   OR dv.venue_key IS NULL OR bat.team_key IS NULL OR bowl.team_key IS NULL
UNION ALL
SELECT 'fact_match_player', COUNT(*)
FROM psl_dw.fact_match_player f
LEFT JOIN psl_dw.dim_match dm  ON dm.match_key = f.match_key
LEFT JOIN psl_dw.dim_team dt   ON dt.team_key = f.team_key
LEFT JOIN psl_dw.dim_player dp ON dp.player_key = f.player_key
LEFT JOIN psl_dw.dim_date dd   ON dd.date_key = f.date_key
LEFT JOIN psl_dw.dim_venue dv  ON dv.venue_key = f.venue_key
WHERE dm.match_key IS NULL OR dt.team_key IS NULL OR dp.player_key IS NULL
   OR dd.date_key IS NULL OR dv.venue_key IS NULL;












-- Step 6: integrity, checking for duplicates. This last check is about uniqueness.
SELECT 'dim_match: duplicate match_id' AS check_name, COUNT(*) AS duplicates
FROM (SELECT match_id FROM psl_dw.dim_match GROUP BY match_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'dim_player: duplicate player_id', COUNT(*)
FROM (SELECT player_id FROM psl_dw.dim_player GROUP BY player_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'dim_team: duplicate team_name', COUNT(*)
FROM (SELECT team_name FROM psl_dw.dim_team GROUP BY team_name HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'dim_venue: duplicate venue_name', COUNT(*)
FROM (SELECT venue_name FROM psl_dw.dim_venue GROUP BY venue_name HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'dim_date: duplicate full_date', COUNT(*)
FROM (SELECT full_date FROM psl_dw.dim_date GROUP BY full_date HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'fact_delivery: duplicate (match, innings, delivery_seq)', COUNT(*)
FROM (SELECT 1 FROM psl_dw.fact_delivery
      GROUP BY match_key, innings_key, delivery_seq HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'fact_over_snapshot: duplicate (match, innings, over)', COUNT(*)
FROM (SELECT 1 FROM psl_dw.fact_over_snapshot
      GROUP BY match_key, innings_key, over_key HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'fact_match_player: duplicate (match, team, player)', COUNT(*)
FROM (SELECT 1 FROM psl_dw.fact_match_player
      GROUP BY match_key, team_key, player_key HAVING COUNT(*) > 1) x;











-- Step 7: the rules on each ball, including with deliberately broken rows.
-- What the rules are:
-- A wicket needs a dismissed player and a dismissal type.
-- wicket_count must agree with the dismissal type. retired hurt is not a wicket.
-- Total runs equal bat runs plus extras.
-- Runs conceded can’t exceed total runs.
-- A wide or no-ball is never a legal ball.
-- A wide is never a ball faced.
-- A dot ball means a legal ball with no runs.
-- A team can’t bat against itself.
WITH c AS (
    SELECT COUNT(*) FILTER (WHERE f.wicket_count > 0 AND (f.dismissed_player_key = -1 OR f.dismissal_type_key = -1)) AS r1,
           COUNT(*) FILTER (WHERE (f.dismissed_player_key = -1) <> (f.dismissal_type_key = -1))                      AS r2,
           COUNT(*) FILTER (WHERE (f.wicket_count > 0) <> dt.counts_as_wicket)                                       AS r3,
           COUNT(*) FILTER (WHERE f.runs_total <> f.runs_batter + f.runs_extras)                                     AS r4,
           COUNT(*) FILTER (WHERE f.runs_conceded > f.runs_total)                                                    AS r5,
           COUNT(*) FILTER (WHERE (f.is_legal_ball = 1 AND (et.is_wide OR et.is_noball))
                               OR (f.is_legal_ball = 0 AND NOT (et.is_wide OR et.is_noball)))                        AS r6,
           COUNT(*) FILTER (WHERE (f.balls_faced = 1 AND et.is_wide) OR (f.balls_faced = 0 AND NOT et.is_wide))      AS r7,
           COUNT(*) FILTER (WHERE (f.is_dot_ball = 1) <> (f.is_legal_ball = 1 AND f.runs_total = 0))                 AS r8,
           COUNT(*) FILTER (WHERE f.batting_team_key = f.bowling_team_key)                                           AS r9
    FROM psl_dw.fact_delivery f
    JOIN psl_dw.dim_dismissal_type dt ON dt.dismissal_type_key = f.dismissal_type_key
    JOIN psl_dw.dim_extra_type et     ON et.extra_type_key = f.extra_type_key
)
SELECT v.check_name, v.problem_rows
FROM c
CROSS JOIN LATERAL (VALUES
    ('wicket on the ball but no dismissed player or dismissal type',   c.r1),
    ('dismissed player and dismissal type disagree',                   c.r2),
    ('wicket_count disagrees with the dismissal type',                 c.r3),
    ('runs_total <> runs_batter + runs_extras',                        c.r4),
    ('runs_conceded greater than runs_total',                          c.r5),
    ('legal-ball flag disagrees with wides and no-balls',              c.r6),
    ('balls_faced disagrees with wides',                               c.r7),
    ('is_dot_ball disagrees with legal ball and zero runs',            c.r8),
    ('batting team is also the bowling team',                          c.r9)
) AS v(check_name, problem_rows);








-- Step 8: cross-table consistency. These checks compare the tables with each other.
SELECT 'a match has more than one date or venue across the fact tables' AS check_name, COUNT(*) AS problem_rows
FROM (SELECT match_key
      FROM (SELECT DISTINCT match_key, date_key, venue_key FROM psl_dw.fact_delivery
            UNION
            SELECT DISTINCT match_key, date_key, venue_key FROM psl_dw.fact_over_snapshot
            UNION
            SELECT DISTINCT match_key, date_key, venue_key FROM psl_dw.fact_match_player) u
      GROUP BY match_key
      HAVING COUNT(DISTINCT date_key) > 1 OR COUNT(DISTINCT venue_key) > 1) x
UNION ALL
SELECT 'batter is not in the squad of the batting team', COUNT(*)
FROM psl_dw.fact_delivery f
LEFT JOIN psl_dw.fact_match_player mp ON mp.match_key = f.match_key AND mp.player_key = f.batter_key
WHERE mp.team_key IS DISTINCT FROM f.batting_team_key
UNION ALL
SELECT 'non-striker is not in the squad of the batting team', COUNT(*)
FROM psl_dw.fact_delivery f
LEFT JOIN psl_dw.fact_match_player mp ON mp.match_key = f.match_key AND mp.player_key = f.non_striker_key
WHERE mp.team_key IS DISTINCT FROM f.batting_team_key
UNION ALL
SELECT 'bowler is not in the squad of the bowling team', COUNT(*)
FROM psl_dw.fact_delivery f
LEFT JOIN psl_dw.fact_match_player mp ON mp.match_key = f.match_key AND mp.player_key = f.bowler_key
WHERE mp.team_key IS DISTINCT FROM f.bowling_team_key
UNION ALL
SELECT 'team names in dim_match that are missing from dim_team', COUNT(*)
FROM psl_dw.dim_match m
WHERE m.team1 NOT IN (SELECT team_name FROM psl_dw.dim_team)
   OR m.team2 NOT IN (SELECT team_name FROM psl_dw.dim_team)
   OR m.toss_winner NOT IN (SELECT team_name FROM psl_dw.dim_team)
   OR (m.winner <> 'Not Applicable' AND m.winner NOT IN (SELECT team_name FROM psl_dw.dim_team))
   OR (m.eliminator <> 'Not Applicable' AND m.eliminator NOT IN (SELECT team_name FROM psl_dw.dim_team));









-- Step 9: cricket limits. This last group checks the data against the rules of the game, which would reveal missing or extra rows
SELECT 'innings with a gap in the over numbers' AS check_name, COUNT(*) AS problem_rows
FROM (SELECT s.match_key, s.innings_key
      FROM psl_dw.fact_over_snapshot s
      JOIN psl_dw.dim_over o ON o.over_key = s.over_key
      GROUP BY s.match_key, s.innings_key
      HAVING MIN(o.over_no) <> 0 OR COUNT(*) <> MAX(o.over_no) + 1) x
UNION ALL
SELECT 'innings with a gap in the ball numbers (delivery_seq)', COUNT(*)
FROM (SELECT match_key, innings_key
      FROM psl_dw.fact_delivery
      GROUP BY match_key, innings_key
      HAVING MIN(delivery_seq) <> 1 OR COUNT(*) <> MAX(delivery_seq)) x
UNION ALL
SELECT 'overs with more than 6 legal balls', COUNT(*)
FROM (SELECT 1 FROM psl_dw.fact_delivery
      GROUP BY match_key, innings_key, over_key
      HAVING SUM(is_legal_ball) > 6) x
UNION ALL
SELECT 'innings with more than 10 wickets', COUNT(*)
FROM (SELECT 1 FROM psl_dw.fact_delivery
      GROUP BY match_key, innings_key
      HAVING SUM(wicket_count) > 10) x
UNION ALL
SELECT 'innings with more than 120 legal balls (6 in a super over)', COUNT(*)
FROM (SELECT 1
      FROM psl_dw.fact_delivery f
      JOIN psl_dw.dim_innings i ON i.innings_key = f.innings_key
      GROUP BY f.match_key, f.innings_key, i.is_super_over
      HAVING SUM(f.is_legal_ball) > CASE WHEN i.is_super_over THEN 6 ELSE 120 END) x;


-- Above Output
-- "innings with a gap in the over numbers"	0
-- "innings with more than 10 wickets"	0
-- "overs with more than 6 legal balls"	2
-- "innings with a gap in the ball numbers (delivery_seq)"	0
-- "innings with more than 120 legal balls (6 in a super over)"	2



-- Step 9b: list the overs with more than 6 legal balls
SELECT m.match_id, m.season, m.stage, i.innings_no, o.over_number,
       SUM(f.is_legal_ball) AS legal_balls, COUNT(*) AS delivery_rows
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_match   m ON m.match_key   = f.match_key
JOIN psl_dw.dim_innings i ON i.innings_key = f.innings_key
JOIN psl_dw.dim_over    o ON o.over_key    = f.over_key
GROUP BY f.match_key, f.innings_key, f.over_key, m.match_id, m.season, m.stage, i.innings_no, o.over_number
HAVING SUM(f.is_legal_ball) > 6
ORDER BY m.match_id, i.innings_no, o.over_number;

-- Above Ouput (the 2 problem rows with more than 6 balls per over)
-- "1168820"	"2018/19"	"Not Applicable"	1	2	7	7
-- "1416502"	"2023/24"	"Qualifier"	1	11	7	7


-- Step 9c: look at the raw balls of those two overs
SELECT match_id, innings_no, over_no, delivery_seq, batter, bowler, runs_total, extras_type, is_legal_ball
FROM psl_staging.stg_deliveries
WHERE (match_id = '1168820' AND innings_no = '1' AND over_no = '1')
   OR (match_id = '1416502' AND innings_no = '1' AND over_no = '10')
ORDER BY match_id, delivery_seq::INT;

-- Above Output
-- "1168820"	"1"	"1"	"7"	"Fakhar Zaman"	"SR Patel"	"0"		"1"
-- "1168820"	"1"	"1"	"8"	"Fakhar Zaman"	"SR Patel"	"0"		"1"
-- "1168820"	"1"	"1"	"9"	"Fakhar Zaman"	"SR Patel"	"0"		"1"
-- "1168820"	"1"	"1"	"10"	"Fakhar Zaman"	"SR Patel"	"1"		"1"
-- "1168820"	"1"	"1"	"11"	"Sohail Akhtar"	"SR Patel"	"7"	"penalty"	"1"
-- "1168820"	"1"	"1"	"12"	"Sohail Akhtar"	"SR Patel"	"1"		"1"
-- "1168820"	"1"	"1"	"13"	"Fakhar Zaman"	"SR Patel"	"0"		"1"
-- "1416502"	"1"	"10"	"61"	"Babar Azam"	"Khushdil Shah"	"0"		"1"
-- "1416502"	"1"	"10"	"62"	"Babar Azam"	"Khushdil Shah"	"4"		"1"
-- "1416502"	"1"	"10"	"63"	"Babar Azam"	"Khushdil Shah"	"1"		"1"
-- "1416502"	"1"	"10"	"64"	"T Kohler-Cadmore"	"Khushdil Shah"	"1"		"1"
-- "1416502"	"1"	"10"	"65"	"Babar Azam"	"Khushdil Shah"	"1"		"1"
-- "1416502"	"1"	"10"	"66"	"T Kohler-Cadmore"	"Khushdil Shah"	"7"	"penalty"	"1"
-- "1416502"	"1"	"10"	"67"	"T Kohler-Cadmore"	"Khushdil Shah"	"1"		"1"


-- Both extra balls are penalty rows: 5 penalty runs recorded as a delivery entry with 7 runs in total, where the extra ball also carries batter runs
-- Found the cause, and it is a problem in our rule, not in the match data.

-- The cricket rule: when penalty runs are awarded for illegal fielding (like the ball hitting the wicketkeeper’s glove), 
-- Law 28.2.3 makes the ball dead, and it does not count as one of the over. The bowler bowls it again. The source records that dead ball as its own entry,
-- with the 5 penalty runs plus any runs the batters had completed (7 here).

-- What our counting did: my script’s rule counted every delivery as a legal ball unless it was a wide or a no-ball. So these penalty entries were 
-- counted as legal balls, which made two overs 7 balls long. I should have included penalty in that rule when I wrote it.

-- What it affects: is_legal_ball, balls_faced and cumulative_legal_balls are off by one each time. Only 3 delivery rows in the whole dataset have a penalty,
-- so the effect is tiny. Runs and wickets are right.


-- Step 9d: look at all 3 penalty rows.
SELECT d.match_id, d.innings_no, d.over_no, d.delivery_seq, d.batter, d.bowler,
       d.runs_batter, d.runs_extras, d.runs_total, d.is_legal_ball,
       c.rows_in_over, c.legal_in_over
FROM psl_staging.stg_deliveries d
JOIN (SELECT match_id, innings_no, over_no,
             COUNT(*) AS rows_in_over, SUM(is_legal_ball::INT) AS legal_in_over
      FROM psl_staging.stg_deliveries
      GROUP BY match_id, innings_no, over_no) c
  ON c.match_id = d.match_id AND c.innings_no = d.innings_no AND c.over_no = d.over_no
WHERE d.extras_type = 'penalty'
ORDER BY d.match_id, d.delivery_seq::INT;

-- Output of above
-- "1168820"	"1"	"1"	"11"	"Sohail Akhtar"	"SR Patel"	"2"	"5"	"7"	"1"	7	7
-- "1416502"	"1"	"10"	"66"	"T Kohler-Cadmore"	"Khushdil Shah"	"2"	"5"	"7"	"1"	7	7
-- "1527557"	"2"	"18"	"118"	"Khushdil Shah"	"Mustafizur Rahman"	"1"	"5"	"6"	"1"	6	6



-- Step 9e: how did innings 2 of match 1527557 end?
SELECT over_no, COUNT(*) AS delivery_rows, SUM(is_legal_ball::INT) AS legal_balls, SUM(runs_total::INT) AS runs
FROM psl_staging.stg_deliveries
WHERE match_id = '1527557' AND innings_no = '2' AND over_no::INT >= 16
GROUP BY over_no
ORDER BY over_no::INT;

SELECT match_id, match_date, season, stage, team1, team2, winner, win_by_type, win_by_value
FROM psl_staging.stg_matches
WHERE match_id = '1527557';

SELECT over_no, COUNT(*) AS delivery_rows, SUM(is_legal_ball::INT) AS legal_balls, SUM(runs_total::INT) AS runs
FROM psl_staging.stg_deliveries
WHERE match_id = '1527557' AND innings_no = '2' AND over_no::INT >= 16
GROUP BY over_no
ORDER BY over_no::INT;


-- Crux of the above
-- The three cases don’t all behave the same, so “penalty means not legal” would be wrong. The right rule, in words:

-- A penalty-only entry is not a legal ball when its over already has 6 other legal balls. That is the dead ball that doesn’t count. This applies to cases 1 and 2.
-- Otherwise it is a legal ball. This applies to case 3.
-- A dead-ball penalty entry also isn’t a ball faced.
-- In simple words, a penalty ball can be a legal ball, that's why there are 7 legal balls in 2 overs in the history of PSL











-- Idempotency proof.
-- to check really, run the load of the fact oversnapshot and fact delivery and it should show INSERT 0 0
INSERT INTO psl_dw.fact_over_snapshot
SELECT * FROM psl_dw.fact_over_snapshot
ON CONFLICT DO NOTHING;



/*
SUMMARY: psl_data_quality.sql

Purpose: validate the warehouse after loading (completeness, accuracy, integrity).

1. Completeness: no missing keys or NULLs in fact_delivery, fact_over_snapshot
   and fact_match_player; dimension rows have no missing values.
2. Reconciliation (staging vs warehouse), difference = 0 for every measure:
   - rows: 357 matches, 83,799 deliveries, 13,594 overs, 7,858 match players
   - runs_batter 109,117; runs_extras 5,905; runs_total 115,022;
     runs_conceded 112,688
   - legal balls 80,814; balls faced 81,165; wickets 4,503; dot balls 28,391
3. Integrity: no fact row without a matching dimension row (orphans = 0);
   no duplicate surrogate or natural keys in any dimension.
4. Consistency: runs_in_over equals the sum of its balls; innings totals
   equal the last over of fact_over_snapshot.
5. Cricket rules: no innings with an over gap, a ball gap, more than 10
   wickets, or more than 120 legal balls (6 in a super over); no over with
   more than 6 legal balls.
6. Defect found and fixed: penalty-only entries (5 runs, illegal fielding)
   were counted as legal balls, giving 2 overs with 7 legal balls and 2
   innings over 120. Fixed in build_psl_tables.py: a penalty-only entry is
   legal only if its over has fewer than 6 other legal balls. Legal balls
   80,816 -> 80,814 and balls faced 81,167 -> 81,165. Runs and wickets
   unchanged. Fact tables were reloaded; all checks are now 0.
7. Idempotency: rerunning both fact loads inserts 0 rows (ON CONFLICT DO
   NOTHING), so the pipeline can be rerun safely.
*/




























































