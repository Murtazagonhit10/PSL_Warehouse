-- psl_reporting. 10 questions split cleanly into one view each




CREATE SCHEMA IF NOT EXISTS psl_reporting;

-- Question 1
CREATE OR REPLACE VIEW psl_reporting.v_q1_top_batters_by_season AS
SELECT m.season,
       p.player_name AS batter,
       SUM(f.runs_batter)                                         AS runs,
       SUM(f.balls_faced)                                         AS balls_faced,
       ROUND(100.0 * SUM(f.runs_batter) / NULLIF(SUM(f.balls_faced), 0), 2) AS strike_rate,
       RANK() OVER (PARTITION BY m.season ORDER BY SUM(f.runs_batter) DESC) AS rank_in_season
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_match   m ON m.match_key   = f.match_key
JOIN psl_dw.dim_player  p ON p.player_key  = f.batter_key
JOIN psl_dw.dim_innings i ON i.innings_key = f.innings_key
WHERE NOT i.is_super_over
GROUP BY m.season, p.player_key, p.player_name;

SELECT * FROM psl_reporting.v_q1_top_batters_by_season
WHERE rank_in_season <= 3
ORDER BY season, rank_in_season;

-- What it does

-- It adds up the runs off the bat and the balls faced for each batter in each season.
-- Strike rate is runs per 100 balls faced, calculated from those two totals. NULLIF avoids a divide-by-zero error for a batter with no balls faced.
-- Super overs are left out, as the business question says, because they would distort the season totals.
-- RANK() numbers the batters within each season, so Power BI can show the top 5 or top 10 with a simple filter.
-- It is a view, not a table, so it always reads the current warehouse and stores nothing extra.
-- The batter is grouped by player_key and the name is only shown. Two different players with the same name therefore stay separate.









-- Question 2
CREATE OR REPLACE VIEW psl_reporting.v_q2_top_bowlers_by_season AS
SELECT m.season,
       p.player_name AS bowler,
       SUM(CASE WHEN dt.credited_to_bowler THEN f.wicket_count ELSE 0 END) AS wickets,
       SUM(f.runs_conceded)                                                AS runs_conceded,
       SUM(f.is_legal_ball)                                                AS legal_balls,
       ROUND(6.0 * SUM(f.runs_conceded) / NULLIF(SUM(f.is_legal_ball), 0), 2) AS economy,
       RANK() OVER (PARTITION BY m.season
                    ORDER BY SUM(CASE WHEN dt.credited_to_bowler THEN f.wicket_count ELSE 0 END) DESC) AS rank_in_season
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_match          m  ON m.match_key  = f.match_key
JOIN psl_dw.dim_player         p  ON p.player_key = f.bowler_key
JOIN psl_dw.dim_innings        i  ON i.innings_key = f.innings_key
JOIN psl_dw.dim_dismissal_type dt ON dt.dismissal_type_key = f.dismissal_type_key
WHERE NOT i.is_super_over
GROUP BY m.season, p.player_key, p.player_name;

SELECT * FROM psl_reporting.v_q2_top_bowlers_by_season
WHERE rank_in_season <= 3
ORDER BY season, rank_in_season;

-- What it does

-- Wickets count only dismissals credited to the bowler: bowled, caught, caught and bowled, lbw, stumped and hit wicket. Run outs and retired are left out, because a run out is not the bowler’s wicket. This uses the credited_to_bowler flag we built into dim_dismissal_type.
-- Economy is runs conceded per over (6 legal balls). It uses runs conceded, which already includes wides and no-balls but not byes and leg byes, so it follows the cricket rule.
-- A bowler who took no credited wickets gets NULL wickets, so they sort to the bottom of the rank.
-- Super overs are left out, as in Question 1.









-- Question 3
CREATE OR REPLACE VIEW psl_reporting.v_q3_phase_scoring AS
SELECT dd.year,
       t.team_name AS batting_team,
       o.phase,
       CASE o.phase WHEN 'Powerplay' THEN 1 WHEN 'Middle' THEN 2 ELSE 3 END AS phase_order,
       SUM(f.runs_total)    AS runs,
       SUM(f.is_legal_ball) AS legal_balls,
       SUM(f.wicket_count)  AS wickets_lost,
       ROUND(6.0 * SUM(f.runs_total) / NULLIF(SUM(f.is_legal_ball), 0), 2) AS run_rate
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_over    o  ON o.over_key    = f.over_key
JOIN psl_dw.dim_date    dd ON dd.date_key   = f.date_key
JOIN psl_dw.dim_team    t  ON t.team_key    = f.batting_team_key
JOIN psl_dw.dim_innings i  ON i.innings_key = f.innings_key
WHERE NOT i.is_super_over
GROUP BY dd.year, t.team_name, o.phase;

SELECT phase,
       SUM(runs)         AS runs,
       SUM(legal_balls)  AS legal_balls,
       SUM(wickets_lost) AS wickets_lost,
       ROUND(6.0 * SUM(runs) / SUM(legal_balls), 2)          AS run_rate,
       ROUND(100.0 * SUM(wickets_lost) / SUM(legal_balls), 2) AS wickets_per_100_balls
FROM psl_reporting.v_q3_phase_scoring
GROUP BY phase, phase_order
ORDER BY phase_order;

-- What it does

-- It groups every ball by calendar year, batting team and phase, which matches the question’s dimensions. The phase comes from dim_over (Powerplay overs 1-6, Middle 7-15, Death 16-20).
-- Run rate is runs per over, from total runs (including extras) divided by legal balls. Wickets lost counts every dismissal that counts as a wicket, including run outs, because the question is about wickets the batting team lost.
-- phase_order is only there so Power BI can sort Powerplay, Middle, Death in that order instead of alphabetically.
-- The view stores sums, not averages, so a ratio in Power BI is always calculated from the totals and stays correct whatever the filter.
-- Super overs are left out.







-- Question 4

CREATE OR REPLACE VIEW psl_reporting.v_q4_venue_first_innings AS
WITH last_over AS (
    SELECT DISTINCT ON (s.match_key, s.innings_key)
           s.match_key, i.innings_no, s.venue_key, s.date_key,
           s.batting_team_key, s.cumulative_runs
    FROM psl_dw.fact_over_snapshot s
    JOIN psl_dw.dim_over    o ON o.over_key    = s.over_key
    JOIN psl_dw.dim_innings i ON i.innings_key = s.innings_key
    WHERE i.innings_no IN (1, 2)
    ORDER BY s.match_key, s.innings_key, o.over_no DESC
),
per_match AS (
    SELECT a.match_key, a.venue_key, a.date_key,
           a.cumulative_runs     AS first_innings_runs,
           b.batting_team_key    AS chasing_team_key
    FROM last_over a
    JOIN last_over b ON b.match_key = a.match_key AND b.innings_no = 2
    WHERE a.innings_no = 1
)
SELECT v.venue_name, v.city, dd.year,
       COUNT(*)                                   AS matches,
       SUM(p.first_innings_runs)                  AS first_innings_runs,
       ROUND(AVG(p.first_innings_runs), 1)        AS avg_first_innings,
       COUNT(*) FILTER (WHERE m.winner <> 'Not Applicable')           AS decided_matches,
       COUNT(*) FILTER (WHERE m.winner = ct.team_name)                AS chasing_wins,
       ROUND(100.0 * COUNT(*) FILTER (WHERE m.winner = ct.team_name)
             / NULLIF(COUNT(*) FILTER (WHERE m.winner <> 'Not Applicable'), 0), 1) AS chasing_win_pct
FROM per_match p
JOIN psl_dw.dim_venue v  ON v.venue_key = p.venue_key
JOIN psl_dw.dim_date  dd ON dd.date_key = p.date_key
JOIN psl_dw.dim_match m  ON m.match_key = p.match_key
JOIN psl_dw.dim_team  ct ON ct.team_key = p.chasing_team_key
GROUP BY v.venue_name, v.city, dd.year;

SELECT venue_name,
       SUM(matches)            AS matches,
       ROUND(SUM(first_innings_runs)::NUMERIC / SUM(matches), 1) AS avg_first_innings,
       SUM(decided_matches)    AS decided,
       SUM(chasing_wins)       AS chasing_wins,
       ROUND(100.0 * SUM(chasing_wins) / SUM(decided_matches), 1) AS chasing_win_pct
FROM psl_reporting.v_q4_venue_first_innings
GROUP BY venue_name
ORDER BY matches DESC;


-- What it does

-- It takes each innings total from the last over of fact_over_snapshot, which is the running total at the end of the innings. That is why this question uses the snapshot table and not the ball table.
-- The first innings total is paired with the team that batted second in the same match.
-- Only innings 1 and 2 are used, so super overs are excluded.
-- A chasing win is a match where the winner is the team that batted second. Ties and no results have no winner, so they count in matches but not in decided_matches. The percentage uses decided matches only.
-- The view keeps sums per venue and year, so Power BI can combine years and still get correct averages.








-- Question 5
CREATE OR REPLACE VIEW psl_reporting.v_q5_toss_impact AS
WITH match_venue AS (
    SELECT DISTINCT match_key, venue_key
    FROM psl_dw.fact_match_player
)
SELECT m.season,
       v.venue_name,
       m.toss_decision,
       COUNT(*) FILTER (WHERE m.winner <> 'Not Applicable')                 AS decided_matches,
       COUNT(*) FILTER (WHERE m.winner = m.toss_winner)                     AS toss_winner_won,
       ROUND(100.0 * COUNT(*) FILTER (WHERE m.winner = m.toss_winner)
             / NULLIF(COUNT(*) FILTER (WHERE m.winner <> 'Not Applicable'), 0), 1) AS toss_winner_win_pct
FROM psl_dw.dim_match m
JOIN match_venue    mv ON mv.match_key = m.match_key
JOIN psl_dw.dim_venue v ON v.venue_key = mv.venue_key
GROUP BY m.season, v.venue_name, m.toss_decision;

SELECT toss_decision,
       SUM(decided_matches)  AS decided_matches,
       SUM(toss_winner_won)  AS toss_winner_won,
       ROUND(100.0 * SUM(toss_winner_won) / SUM(decided_matches), 1) AS toss_winner_win_pct
FROM psl_reporting.v_q5_toss_impact
GROUP BY ROLLUP (toss_decision)
ORDER BY toss_decision NULLS LAST;

-- What it does

-- For every season, venue and toss decision (bat or field), it counts the decided matches and how many of them the toss winner went on to win.
-- The venue of a match comes from the squad table, because dim_match has no venue. That table has one row set for all 357 matches, so even a washed-out match is counted once. The Phase 1 document names the snapshot table here. This one is smaller and covers every match, and the answer for decided matches is the same.
-- Ties and no results have no winner, so they are out of decided_matches.
-- The last query uses ROLLUP, which adds an overall total row (the NULL decision row) below the bat and field rows.






-- Question 6
CREATE OR REPLACE VIEW psl_reporting.v_q6_checkpoint_scores AS
SELECT m.match_id,
       dd.year,
       i.innings_no,
       t.team_name AS batting_team,
       MAX(s.cumulative_runs)    FILTER (WHERE o.over_number = 6)  AS runs_after_6,
       MAX(s.cumulative_wickets) FILTER (WHERE o.over_number = 6)  AS wickets_after_6,
       MAX(s.cumulative_runs)    FILTER (WHERE o.over_number = 10) AS runs_after_10,
       MAX(s.cumulative_wickets) FILTER (WHERE o.over_number = 10) AS wickets_after_10,
       MAX(s.cumulative_runs)    FILTER (WHERE o.over_number = 15) AS runs_after_15,
       MAX(s.cumulative_wickets) FILTER (WHERE o.over_number = 15) AS wickets_after_15,
       MAX(s.cumulative_runs)    AS final_runs,
       MAX(s.cumulative_wickets) AS final_wickets,
       CASE WHEN m.winner = 'Not Applicable' THEN 'No winner'
            WHEN m.winner = t.team_name      THEN 'Won'
            ELSE 'Lost' END AS match_result
FROM psl_dw.fact_over_snapshot s
JOIN psl_dw.dim_match   m  ON m.match_key   = s.match_key
JOIN psl_dw.dim_innings i  ON i.innings_key = s.innings_key
JOIN psl_dw.dim_over    o  ON o.over_key    = s.over_key
JOIN psl_dw.dim_team    t  ON t.team_key    = s.batting_team_key
JOIN psl_dw.dim_date    dd ON dd.date_key   = s.date_key
WHERE NOT i.is_super_over
GROUP BY m.match_id, dd.year, i.innings_no, t.team_name, m.winner;

SELECT innings_no, match_result,
       COUNT(*)                        AS innings,
       ROUND(AVG(runs_after_6), 1)     AS avg_after_6,
       ROUND(AVG(runs_after_10), 1)    AS avg_after_10,
       ROUND(AVG(runs_after_15), 1)    AS avg_after_15,
       ROUND(AVG(final_runs), 1)       AS avg_final
FROM psl_reporting.v_q6_checkpoint_scores
WHERE match_result <> 'No winner'
GROUP BY innings_no, match_result
ORDER BY innings_no, match_result DESC;

-- What it does

-- It gives one row per innings, with the running score and wickets after 6, 10 and 15 overs, plus the final total, so you can see how an early score relates to the end result.
-- Over 6 is the end of the powerplay, which is over_number 6 (the dimension is numbered from 1, the raw data from 0).
-- If an innings ended before an over was reached, because the chase finished or the team was all out, that checkpoint is NULL. That is correct, because there is no score at an over that was never bowled, and averages skip NULLs.
-- match_result says whether the batting team won or lost. Ties and no results are marked No winner, and the check below leaves them out.
-- The final total is the largest running total in the innings, which is the last over’s value, since the running total never goes down.












-- Question 7
CREATE OR REPLACE VIEW psl_reporting.v_q7_dismissal_mix AS
SELECT m.season,
       dd.year,
       o.phase,
       CASE o.phase WHEN 'Powerplay' THEN 1 WHEN 'Middle' THEN 2 ELSE 3 END AS phase_order,
       dt.dismissal_kind,
       SUM(f.wicket_count) AS wickets
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_match          m  ON m.match_key  = f.match_key
JOIN psl_dw.dim_date           dd ON dd.date_key  = f.date_key
JOIN psl_dw.dim_over           o  ON o.over_key   = f.over_key
JOIN psl_dw.dim_dismissal_type dt ON dt.dismissal_type_key = f.dismissal_type_key
JOIN psl_dw.dim_innings        i  ON i.innings_key = f.innings_key
WHERE dt.counts_as_wicket AND NOT i.is_super_over
GROUP BY m.season, dd.year, o.phase, dt.dismissal_kind;

SELECT dismissal_kind,
       SUM(wickets) AS wickets,
       ROUND(100.0 * SUM(wickets) / SUM(SUM(wickets)) OVER (), 1) AS share_pct
FROM psl_reporting.v_q7_dismissal_mix
GROUP BY dismissal_kind
ORDER BY wickets DESC;

-- What it does

-- It counts wickets for each season, year, phase and dismissal type, so you can see which kinds of dismissal dominate and whether the mix changes by phase.
-- counts_as_wicket keeps only real wickets. The “Not Applicable” row and retired hurt drop out, and run outs stay in, because here we are describing how batters get out, not crediting bowlers.
-- Super overs are excluded, as in the other views.
-- The check calculates each kind’s share with a window function (SUM(...) OVER ()), which gives the overall total in the same pass without a second query.






-- Question 8
CREATE OR REPLACE VIEW psl_reporting.v_q8_extras_by_team AS
SELECT m.season,
       dd.year,
       t.team_name AS bowling_team,
       COUNT(*) FILTER (WHERE et.is_wide)    AS wides,
       COUNT(*) FILTER (WHERE et.is_noball)  AS noballs,
       SUM(f.runs_conceded - f.runs_batter) FILTER (WHERE et.is_wide OR et.is_noball) AS wide_noball_runs,
       SUM(f.is_legal_ball) AS legal_balls
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_match      m  ON m.match_key       = f.match_key
JOIN psl_dw.dim_date       dd ON dd.date_key       = f.date_key
JOIN psl_dw.dim_team       t  ON t.team_key        = f.bowling_team_key
JOIN psl_dw.dim_extra_type et ON et.extra_type_key = f.extra_type_key
JOIN psl_dw.dim_innings    i  ON i.innings_key     = f.innings_key
WHERE NOT i.is_super_over
GROUP BY m.season, dd.year, t.team_name;

SELECT bowling_team,
       SUM(wides)            AS wides,
       SUM(noballs)          AS noballs,
       SUM(wide_noball_runs) AS wide_noball_runs,
       ROUND(6.0 * (SUM(wides) + SUM(noballs)) / SUM(legal_balls), 2) AS extra_balls_per_over
FROM psl_reporting.v_q8_extras_by_team
GROUP BY bowling_team
ORDER BY SUM(wides) + SUM(noballs) DESC;

-- What it does

-- It counts the wides and no-balls bowled by each team in each season. These are the extras that are the bowler’s fault, so byes and leg byes are not counted.
-- Wides and no-balls come from the flags in dim_extra_type, so a ball recorded as “byes;noballs” still counts as a no-ball.
-- wide_noball_runs is the runs conceded minus the batter’s runs on those balls, which is exactly the wide and no-ball runs. It does not pick up the bye runs that appear on the same ball, which a plain runs_extras sum would.
-- legal_balls is stored so that the last column can show the rate. Teams that played more matches always have more extras, so a rate is the fair comparison.
-- Super overs are excluded.







-- Question 9
CREATE OR REPLACE VIEW psl_reporting.v_q9_powerplay_dot_balls AS
SELECT m.season,
       p.player_name AS bowler,
       SUM(f.is_legal_ball) AS legal_balls,
       SUM(f.is_dot_ball)   AS dot_balls,
       ROUND(100.0 * SUM(f.is_dot_ball) / NULLIF(SUM(f.is_legal_ball), 0), 1) AS dot_ball_pct
FROM psl_dw.fact_delivery f
JOIN psl_dw.dim_match   m ON m.match_key   = f.match_key
JOIN psl_dw.dim_player  p ON p.player_key  = f.bowler_key
JOIN psl_dw.dim_over    o ON o.over_key    = f.over_key
JOIN psl_dw.dim_innings i ON i.innings_key = f.innings_key
WHERE o.phase = 'Powerplay' AND NOT i.is_super_over
GROUP BY m.season, p.player_key, p.player_name;

SELECT bowler,
       SUM(legal_balls) AS powerplay_balls,
       SUM(dot_balls)   AS dot_balls,
       ROUND(100.0 * SUM(dot_balls) / SUM(legal_balls), 1) AS dot_ball_pct
FROM psl_reporting.v_q9_powerplay_dot_balls
GROUP BY bowler
HAVING SUM(legal_balls) >= 120
ORDER BY dot_ball_pct DESC
LIMIT 10;


-- What it does

-- It looks only at powerplay overs (1 to 6). For each bowler and season it counts the legal balls bowled and how many were dot balls, then calculates the dot ball percentage.
-- A dot ball is a legal ball with no runs at all, so a wide, a no-ball and a bye are not dots. This uses the is_dot_ball flag stored in the fact table.
-- Super overs are left out here for a specific reason. Over 1 of a super over carries the powerplay label in dim_over, so without this filter those balls would be counted as powerplay.
-- The view keeps every bowler, even with only a handful of balls, because a 100% dot rate over 3 balls means nothing. The cutoff belongs in the report, so the check below uses at least 120 powerplay balls (20 overs).







-- Question 10

CREATE OR REPLACE VIEW psl_reporting.v_q10_player_appearances AS
SELECT m.season,
       t.team_name,
       p.player_name,
       COUNT(*) AS matches_played
FROM psl_dw.fact_match_player f
JOIN psl_dw.dim_match  m ON m.match_key  = f.match_key
JOIN psl_dw.dim_team   t ON t.team_key   = f.team_key
JOIN psl_dw.dim_player p ON p.player_key = f.player_key
GROUP BY m.season, t.team_key, t.team_name, p.player_key, p.player_name;

CREATE OR REPLACE VIEW psl_reporting.v_q10_multi_franchise_players AS
SELECT p.player_name,
       COUNT(DISTINCT f.team_key) AS franchises,
       STRING_AGG(DISTINCT t.team_name, ', ' ORDER BY t.team_name) AS teams,
       COUNT(*) AS matches_played
FROM psl_dw.fact_match_player f
JOIN psl_dw.dim_team   t ON t.team_key   = f.team_key
JOIN psl_dw.dim_player p ON p.player_key = f.player_key
GROUP BY p.player_key, p.player_name
HAVING COUNT(DISTINCT f.team_key) > 1;

SELECT COUNT(*) AS players_with_more_than_one_franchise
FROM psl_reporting.v_q10_multi_franchise_players;

SELECT * FROM psl_reporting.v_q10_multi_franchise_players
ORDER BY franchises DESC, matches_played DESC
LIMIT 10;

-- What it does

-- v_q10_player_appearances counts, for each season, team and player, how many matches the player was named in the playing XI. A player who changed teams has one row per team per season.
-- v_q10_multi_franchise_players has one row per player who played for more than one franchise, with the number of franchises, the list of team names and the total matches.
-- An appearance means being in a team’s listed XI for a match, not necessarily batting or bowling. A player who was named but didn’t bat or bowl still counts as having played.
-- Players are grouped by player_key, so two different players with the same name are never merged.











-- All the views we have made so far . it should return 11 rows, question 10 has 2 views

SELECT table_name AS view_name
FROM information_schema.views
WHERE table_schema = 'psl_reporting'
ORDER BY table_name;









/*
SUMMARY: psl_reporting.sql

11 views in psl_reporting, one per business question (Question 10 has two).
They read only from psl_dw, store no data, and are created with
CREATE OR REPLACE, so the file can be rerun safely. Super overs are left out
of every view that uses ball or over data. Views keep sums and counts, and
ratios (strike rate, economy, run rate, percentages) are calculated from them.

Q1  v_q1_top_batters_by_season      runs, balls faced, strike rate, rank per season
Q2  v_q2_top_bowlers_by_season      wickets credited to the bowler, economy, rank
Q3  v_q3_phase_scoring              run rate and wickets lost by phase, team, year
Q4  v_q4_venue_first_innings        average first innings total, chasing win % per venue
Q5  v_q5_toss_impact                toss winner win % by season, venue, toss decision
Q6  v_q6_checkpoint_scores          score and wickets after 6, 10, 15 overs vs result
Q7  v_q7_dismissal_mix              wickets by dismissal type, phase, season
Q8  v_q8_extras_by_team             wides, no-balls and their runs per bowling team
Q9  v_q9_powerplay_dot_balls        dot ball % of powerplay balls per bowler
Q10 v_q10_player_appearances        matches per player per team per season
    v_q10_multi_franchise_players   players with more than one franchise

Checked results:
- Phase totals add back to 115,022 runs and 4,503 wickets with the super overs.
- Q4 covers 354 matches (357 minus 3 no results) with 350 decided; Q5 and Q6
  also count 350 decided matches.
- Dismissal shares add up to 4,497 wickets (4,503 minus 6 in super overs).
- 192 players played for more than one franchise.

Design notes:
- Q2 counts only dismissals credited to the bowler (run outs excluded).
- Q4 reads the last over of each innings in fact_over_snapshot.
- Q5 takes the venue from fact_match_player so every match is counted once.
- A bug in the first version of Q2 (NULL wickets ranked first) was fixed by
  counting missing wickets as 0.
*/



























































































