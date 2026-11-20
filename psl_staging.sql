-- Creating SCHEMAS

CREATE SCHEMA IF NOT EXISTS psl_staging;
CREATE SCHEMA IF NOT EXISTS psl_dw;
CREATE SCHEMA IF NOT EXISTS psl_reporting;


-- Creating Staging Tables!!

CREATE TABLE psl_staging.stg_matches (
    match_id TEXT, match_date TEXT, season TEXT, event_name TEXT,
    match_number TEXT, stage TEXT, venue TEXT, city TEXT,
    team1 TEXT, team2 TEXT, toss_winner TEXT, toss_decision TEXT,
    winner TEXT, win_by_type TEXT, win_by_value TEXT, result TEXT,
    method TEXT, eliminator TEXT, player_of_match TEXT,
    umpire1 TEXT, umpire2 TEXT
);

CREATE TABLE psl_staging.stg_deliveries (
    match_id TEXT, innings_no TEXT, is_super_over TEXT,
    batting_team TEXT, bowling_team TEXT, over_no TEXT, delivery_seq TEXT,
    batter TEXT, bowler TEXT, non_striker TEXT,
    runs_batter TEXT, runs_extras TEXT, runs_total TEXT, runs_conceded TEXT,
    extras_type TEXT, is_legal_ball TEXT, balls_faced TEXT, wicket_count TEXT,
    dismissed_player TEXT, dismissal_kind TEXT,
    all_players_out TEXT, all_wicket_kinds TEXT, fielders TEXT
);

CREATE TABLE psl_staging.stg_match_players (
    match_id TEXT, team TEXT, player_name TEXT, player_id TEXT
);

CREATE TABLE psl_staging.stg_over_snapshot (
    match_id TEXT, innings_no TEXT, is_super_over TEXT,
    batting_team TEXT, bowling_team TEXT, over_no TEXT,
    runs_in_over TEXT, wickets_in_over TEXT,
    cumulative_runs TEXT, cumulative_wickets TEXT, cumulative_legal_balls TEXT
);






-- Imported Data from csv files and now checking their count
SELECT 'stg_matches' AS table_name, COUNT(*) AS row_count FROM psl_staging.stg_matches
UNION ALL
SELECT 'stg_deliveries', COUNT(*) FROM psl_staging.stg_deliveries
UNION ALL
SELECT 'stg_match_players', COUNT(*) FROM psl_staging.stg_match_players
UNION ALL
SELECT 'stg_over_snapshot', COUNT(*) FROM psl_staging.stg_over_snapshot;






-- checking for problem rows like no duplicates, missing IDs or orphans
SELECT 'matches: duplicate match_id' AS check_name, COUNT(*) AS problem_rows
FROM (SELECT match_id FROM psl_staging.stg_matches
      GROUP BY match_id HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'matches: missing match_id', COUNT(*)
FROM psl_staging.stg_matches WHERE match_id IS NULL
UNION ALL
SELECT 'deliveries: duplicate (match, innings, delivery_seq)', COUNT(*)
FROM (SELECT 1 FROM psl_staging.stg_deliveries
      GROUP BY match_id, innings_no, delivery_seq HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'deliveries: missing batter or bowler', COUNT(*)
FROM psl_staging.stg_deliveries WHERE batter IS NULL OR bowler IS NULL
UNION ALL
SELECT 'deliveries: match_id not in matches', COUNT(*)
FROM psl_staging.stg_deliveries d
LEFT JOIN psl_staging.stg_matches m ON m.match_id = d.match_id
WHERE m.match_id IS NULL
UNION ALL
SELECT 'match_players: missing player_id', COUNT(*)
FROM psl_staging.stg_match_players WHERE player_id IS NULL
UNION ALL
SELECT 'match_players: duplicate (match, team, player)', COUNT(*)
FROM (SELECT 1 FROM psl_staging.stg_match_players
      GROUP BY match_id, team, player_name HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'over_snapshot: duplicate (match, innings, over)', COUNT(*)
FROM (SELECT 1 FROM psl_staging.stg_over_snapshot
      GROUP BY match_id, innings_no, over_no HAVING COUNT(*) > 1) x;






-- check the team names, it should be the same everywhere, for example, there shouldnt be Lahore and LAHORE separately
SELECT team_name, COUNT(*) AS times_used
FROM (
    SELECT team1 AS team_name FROM psl_staging.stg_matches
    UNION ALL
    SELECT team2 FROM psl_staging.stg_matches
    UNION ALL
    SELECT team FROM psl_staging.stg_match_players
    UNION ALL
    SELECT batting_team FROM psl_staging.stg_deliveries
) t
GROUP BY team_name
ORDER BY team_name;




-- check venues.
SELECT venue, city, COUNT(*) AS matches
FROM psl_staging.stg_matches
GROUP BY venue, city
ORDER BY venue, city;

-- Output of the above code (we found real defects). (I'm showing output here because 
-- we are to clean data and next time we run this code there won't be any defects)

-- venue 									city 		matches
-- "Dubai International Cricket Stadium"	"Dubai"		33
-- "Dubai International Cricket Stadium"				27
-- "Gaddafi Stadium"						"Lahore"	13
-- "Gaddafi Stadium, Lahore"				"Lahore"	73
-- "Multan Cricket Stadium"					"Multan"	16
-- "National Stadium"						"Karachi"	34
-- "National Stadium, Karachi"				"Karachi"	63
-- "Rawalpindi Cricket Stadium"			"Rawalpindi"	36
-- "Sharjah Cricket Stadium"				"Sharjah"	22
-- "Sharjah Cricket Stadium"							16
-- "Sheikh Zayed Stadium"					"Abu Dhabi"	4
-- "Sheikh Zayed Stadium, Abu Dhabi"		"Abu Dhabi"	20

-- Same ground, two names: Gaddafi Stadium and Gaddafi Stadium, Lahore, National Stadium and National Stadium, Karachi, and Sheikh Zayed Stadium and 
-- Sheikh Zayed Stadium, Abu Dhabi. The city is part of the name in one version.
-- Missing city: 27 Dubai matches and 16 Sharjah matches have an empty city.




-- Fixing above: create a small venue mapping table.
CREATE TABLE psl_staging.map_venue (
    venue_raw   TEXT PRIMARY KEY,
    venue_clean TEXT NOT NULL,
    city_clean  TEXT NOT NULL
);

INSERT INTO psl_staging.map_venue (venue_raw, venue_clean, city_clean) VALUES
('Dubai International Cricket Stadium', 'Dubai International Cricket Stadium', 'Dubai'),
('Gaddafi Stadium',                     'Gaddafi Stadium',                     'Lahore'),
('Gaddafi Stadium, Lahore',             'Gaddafi Stadium',                     'Lahore'),
('Multan Cricket Stadium',              'Multan Cricket Stadium',              'Multan'),
('National Stadium',                    'National Stadium',                    'Karachi'),
('National Stadium, Karachi',           'National Stadium',                    'Karachi'),
('Rawalpindi Cricket Stadium',          'Rawalpindi Cricket Stadium',          'Rawalpindi'),
('Sharjah Cricket Stadium',             'Sharjah Cricket Stadium',             'Sharjah'),
('Sheikh Zayed Stadium',                'Sheikh Zayed Stadium',                'Abu Dhabi'),
('Sheikh Zayed Stadium, Abu Dhabi',     'Sheikh Zayed Stadium',                'Abu Dhabi');


-- check that every match has a mapping
SELECT COUNT(*) AS unmapped_matches
FROM psl_staging.stg_matches m
LEFT JOIN psl_staging.map_venue v ON v.venue_raw = m.venue
WHERE v.venue_raw IS NULL;





-- list the distinct values of the category columns in stg_matches
SELECT 'season' AS column_name, season AS value, COUNT(*) AS matches
FROM psl_staging.stg_matches GROUP BY season
UNION ALL
SELECT 'event_name', event_name, COUNT(*) FROM psl_staging.stg_matches GROUP BY event_name
UNION ALL
SELECT 'stage', stage, COUNT(*) FROM psl_staging.stg_matches GROUP BY stage
UNION ALL
SELECT 'toss_decision', toss_decision, COUNT(*) FROM psl_staging.stg_matches GROUP BY toss_decision
UNION ALL
SELECT 'win_by_type', win_by_type, COUNT(*) FROM psl_staging.stg_matches GROUP BY win_by_type
UNION ALL
SELECT 'result', result, COUNT(*) FROM psl_staging.stg_matches GROUP BY result
UNION ALL
SELECT 'method', method, COUNT(*) FROM psl_staging.stg_matches GROUP BY method
UNION ALL
SELECT 'eliminator', eliminator, COUNT(*) FROM psl_staging.stg_matches GROUP BY eliminator
ORDER BY column_name, value;



-- OUTPUT of the above code
-- column_name  VALUE				matches
-- "eliminator"	"Islamabad United"	1
-- "eliminator"	"Karachi Kings"	1
-- "eliminator"	"Lahore Qalandars"	1
-- "eliminator"	"Peshawar Zalmi"	1
-- "eliminator"		353
-- "event_name"	"Pakistan Super League"	357
-- "method"	"D/L"	4
-- "method"		353
-- "result"	"no result"	3
-- "result"	"tie"	4
-- "result"		350
-- "season"	"2015/16"	23
-- "season"	"2016/17"	24
-- "season"	"2017/18"	33
-- "season"	"2018/19"	34
-- "season"	"2019/20"	28
-- "season"	"2020/21"	18
-- "season"	"2021"	20
-- "season"	"2021/22"	34
-- "season"	"2022/23"	34
-- "season"	"2023/24"	32
-- "season"	"2025"	34
-- "season"	"2026"	43
-- "stage"	"Eliminator"	17
-- "stage"	"Final"	11
-- "stage"	"Qualifier"	8
-- "stage"	"Qualifier 1"	3
-- "stage"	"Qualifier 2"	3
-- "stage"	"Qualifier 3"	2
-- "stage"		313
-- "toss_decision"	"bat"	87
-- "toss_decision"	"field"	270
-- "win_by_type"	"runs"	155
-- "win_by_type"	"wickets"	195
-- "win_by_type"		7




-- check the dates behind the season labels.
SELECT season, MIN(match_date) AS first_match, MAX(match_date) AS last_match, COUNT(*) AS matches
FROM psl_staging.stg_matches
GROUP BY season
ORDER BY first_match;

-- Above output all good






-- check for extra spaces in names. An invisible space at the start or end makes "Babar Azam" and "Babar Azam " count as two different players
SELECT 'matches.venue' AS column_checked, COUNT(*) AS rows_with_extra_spaces FROM psl_staging.stg_matches WHERE venue <> TRIM(venue)
UNION ALL SELECT 'matches.city', COUNT(*) FROM psl_staging.stg_matches WHERE city <> TRIM(city)
UNION ALL SELECT 'matches.team1', COUNT(*) FROM psl_staging.stg_matches WHERE team1 <> TRIM(team1)
UNION ALL SELECT 'matches.team2', COUNT(*) FROM psl_staging.stg_matches WHERE team2 <> TRIM(team2)
UNION ALL SELECT 'matches.toss_winner', COUNT(*) FROM psl_staging.stg_matches WHERE toss_winner <> TRIM(toss_winner)
UNION ALL SELECT 'matches.winner', COUNT(*) FROM psl_staging.stg_matches WHERE winner <> TRIM(winner)
UNION ALL SELECT 'matches.player_of_match', COUNT(*) FROM psl_staging.stg_matches WHERE player_of_match <> TRIM(player_of_match)
UNION ALL SELECT 'matches.umpire1', COUNT(*) FROM psl_staging.stg_matches WHERE umpire1 <> TRIM(umpire1)
UNION ALL SELECT 'matches.umpire2', COUNT(*) FROM psl_staging.stg_matches WHERE umpire2 <> TRIM(umpire2)
UNION ALL SELECT 'deliveries.batter', COUNT(*) FROM psl_staging.stg_deliveries WHERE batter <> TRIM(batter)
UNION ALL SELECT 'deliveries.bowler', COUNT(*) FROM psl_staging.stg_deliveries WHERE bowler <> TRIM(bowler)
UNION ALL SELECT 'deliveries.non_striker', COUNT(*) FROM psl_staging.stg_deliveries WHERE non_striker <> TRIM(non_striker)
UNION ALL SELECT 'deliveries.dismissed_player', COUNT(*) FROM psl_staging.stg_deliveries WHERE dismissed_player <> TRIM(dismissed_player)
UNION ALL SELECT 'match_players.player_name', COUNT(*) FROM psl_staging.stg_match_players WHERE player_name <> TRIM(player_name)
UNION ALL SELECT 'match_players.team', COUNT(*) FROM psl_staging.stg_match_players WHERE team <> TRIM(team);

-- Above Output, every thing is fine and count of differences is 0







-- check that every player name in the deliveries can be matched to a player ID
SELECT 'batter' AS role, COUNT(*) AS unmatched_rows
FROM psl_staging.stg_deliveries d
LEFT JOIN psl_staging.stg_match_players p
       ON p.match_id = d.match_id AND p.player_name = d.batter
WHERE p.player_id IS NULL
UNION ALL
SELECT 'bowler', COUNT(*)
FROM psl_staging.stg_deliveries d
LEFT JOIN psl_staging.stg_match_players p
       ON p.match_id = d.match_id AND p.player_name = d.bowler
WHERE p.player_id IS NULL
UNION ALL
SELECT 'non_striker', COUNT(*)
FROM psl_staging.stg_deliveries d
LEFT JOIN psl_staging.stg_match_players p
       ON p.match_id = d.match_id AND p.player_name = d.non_striker
WHERE p.player_id IS NULL
UNION ALL
SELECT 'dismissed_player', COUNT(*)
FROM psl_staging.stg_deliveries d
LEFT JOIN psl_staging.stg_match_players p
       ON p.match_id = d.match_id AND p.player_name = d.dismissed_player
WHERE d.dismissed_player IS NOT NULL AND p.player_id IS NULL;

-- above output, no orphans detected






-- check each player ID for more than one name. The same person can appear under different spellings across seasons

SELECT player_id,
       COUNT(DISTINCT player_name) AS name_count,
       STRING_AGG(DISTINCT player_name, ' | ') AS names_used
FROM psl_staging.stg_match_players
GROUP BY player_id
HAVING COUNT(DISTINCT player_name) > 1
ORDER BY player_id;

-- Above output

-- "2b0f2af3"	2	"Imran Khan | Imran Khan (2)"
-- "3086f7a4"	2	"Mohammad Nawaz | Mohammad Nawaz (3)"
-- "687e20b3"	2	"Mohammad Imran | Mohammad Imran (2)"

-- 3 players found with different player_ids across different seasons



-- see all the IDs that use these three names, and how often each spelling appears

SELECT player_id, player_name, COUNT(*) AS matches_played
FROM psl_staging.stg_match_players
WHERE player_name LIKE 'Imran Khan%'
   OR player_name LIKE 'Mohammad Nawaz%'
   OR player_name LIKE 'Mohammad Imran%'
GROUP BY player_id, player_name
ORDER BY player_name, player_id;

-- Above Output

-- "2b0f2af3"	"Imran Khan"	9
-- "195fb6db"	"Imran Khan (1)"	3
-- "2b0f2af3"	"Imran Khan (2)"	1
-- "65a2fff5"	"Mohammad Imran"	6
-- "687e20b3"	"Mohammad Imran"	14
-- "687e20b3"	"Mohammad Imran (2)"	1
-- "3086f7a4"	"Mohammad Nawaz"	41
-- "3086f7a4"	"Mohammad Nawaz (3)"	57








-- Query A: format checks. Every row must be 0
SELECT 'matches: blank text instead of NULL' AS check_name, COUNT(*) AS problem_rows
FROM psl_staging.stg_matches
WHERE stage = '' OR city = '' OR result = '' OR method = '' OR eliminator = ''
   OR win_by_type = '' OR player_of_match = ''
UNION ALL
SELECT 'deliveries: blank text instead of NULL', COUNT(*)
FROM psl_staging.stg_deliveries
WHERE extras_type = '' OR dismissed_player = '' OR dismissal_kind = ''
UNION ALL
SELECT 'matches: bad date', COUNT(*)
FROM psl_staging.stg_matches
WHERE COALESCE(match_date,'') !~ '^\d{4}-\d{2}-\d{2}$'
UNION ALL
SELECT 'matches: non-numeric match_number or win_by_value', COUNT(*)
FROM psl_staging.stg_matches
WHERE match_number !~ '^\d+$' OR win_by_value !~ '^\d+$'
UNION ALL
SELECT 'deliveries: non-numeric number or flag columns', COUNT(*)
FROM psl_staging.stg_deliveries
WHERE COALESCE(innings_no,'')    !~ '^\d+$' OR COALESCE(over_no,'')       !~ '^\d+$'
   OR COALESCE(delivery_seq,'')  !~ '^\d+$' OR COALESCE(runs_batter,'')   !~ '^\d+$'
   OR COALESCE(runs_extras,'')   !~ '^\d+$' OR COALESCE(runs_total,'')    !~ '^\d+$'
   OR COALESCE(runs_conceded,'') !~ '^\d+$' OR COALESCE(wicket_count,'')  !~ '^\d+$'
   OR COALESCE(is_legal_ball,'') NOT IN ('0','1')
   OR COALESCE(balls_faced,'')   NOT IN ('0','1')
   OR COALESCE(is_super_over,'') NOT IN ('0','1')
UNION ALL
SELECT 'over_snapshot: non-numeric number or flag columns', COUNT(*)
FROM psl_staging.stg_over_snapshot
WHERE COALESCE(innings_no,'')              !~ '^\d+$' OR COALESCE(over_no,'')             !~ '^\d+$'
   OR COALESCE(runs_in_over,'')            !~ '^\d+$' OR COALESCE(wickets_in_over,'')     !~ '^\d+$'
   OR COALESCE(cumulative_runs,'')         !~ '^\d+$' OR COALESCE(cumulative_wickets,'')  !~ '^\d+$'
   OR COALESCE(cumulative_legal_balls,'')  !~ '^\d+$'
   OR COALESCE(is_super_over,'')           NOT IN ('0','1');







-- Query B: logic and cross-table checks. Every row must be 0 (Accuracy Check)
SELECT 'deliveries: runs_total <> runs_batter + runs_extras' AS check_name, COUNT(*) AS problem_rows
FROM psl_staging.stg_deliveries
WHERE runs_total::int <> runs_batter::int + runs_extras::int
UNION ALL
SELECT 'deliveries: wicket but no dismissal kind', COUNT(*)
FROM psl_staging.stg_deliveries
WHERE wicket_count::int > 0 AND dismissal_kind IS NULL
UNION ALL
SELECT 'deliveries: legal-ball flag disagrees with wides/no-balls', COUNT(*)
FROM psl_staging.stg_deliveries
WHERE (is_legal_ball = '1' AND (extras_type LIKE '%wides%' OR extras_type LIKE '%noballs%'))
   OR (is_legal_ball = '0' AND COALESCE(extras_type,'') NOT LIKE '%wides%'
                           AND COALESCE(extras_type,'') NOT LIKE '%noballs%')
UNION ALL
SELECT 'deliveries: super-over flag disagrees with innings_no', COUNT(*)
FROM psl_staging.stg_deliveries
WHERE (innings_no::int > 2) <> (is_super_over = '1')
UNION ALL
SELECT 'deliveries: over_no above 19', COUNT(*)
FROM psl_staging.stg_deliveries WHERE over_no::int > 19
UNION ALL
SELECT 'deliveries: batting team is also bowling team', COUNT(*)
FROM psl_staging.stg_deliveries WHERE batting_team = bowling_team
UNION ALL
SELECT 'deliveries: team not playing in that match', COUNT(*)
FROM psl_staging.stg_deliveries d
JOIN psl_staging.stg_matches m ON m.match_id = d.match_id
WHERE d.batting_team NOT IN (m.team1, m.team2) OR d.bowling_team NOT IN (m.team1, m.team2)
UNION ALL
SELECT 'over_snapshot: team not playing in that match', COUNT(*)
FROM psl_staging.stg_over_snapshot s
JOIN psl_staging.stg_matches m ON m.match_id = s.match_id
WHERE s.batting_team NOT IN (m.team1, m.team2) OR s.bowling_team NOT IN (m.team1, m.team2)
UNION ALL
SELECT 'match_players: team not playing in that match', COUNT(*)
FROM psl_staging.stg_match_players p
JOIN psl_staging.stg_matches m ON m.match_id = p.match_id
WHERE p.team NOT IN (m.team1, m.team2)
UNION ALL
SELECT 'matches: toss winner or winner is not one of the two teams', COUNT(*)
FROM psl_staging.stg_matches
WHERE toss_winner NOT IN (team1, team2) OR winner NOT IN (team1, team2)
UNION ALL
SELECT 'matches: same date and same two teams twice', COUNT(*)
FROM (SELECT 1 FROM psl_staging.stg_matches
      GROUP BY match_date, team1, team2 HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'overs in deliveries and over_snapshot do not match', COUNT(*)
FROM (SELECT DISTINCT match_id, innings_no, over_no FROM psl_staging.stg_deliveries) d
FULL JOIN psl_staging.stg_over_snapshot s
       ON s.match_id = d.match_id AND s.innings_no = d.innings_no AND s.over_no = d.over_no
WHERE d.match_id IS NULL OR s.match_id IS NULL
UNION ALL
SELECT 'innings totals: deliveries vs last over of over_snapshot differ', COUNT(*)
FROM (SELECT match_id, innings_no, SUM(runs_total::int) AS runs,
             SUM(wicket_count::int) AS wickets, SUM(is_legal_ball::int) AS balls
      FROM psl_staging.stg_deliveries GROUP BY match_id, innings_no) d
FULL JOIN (SELECT DISTINCT ON (match_id, innings_no) match_id, innings_no,
                  cumulative_runs::int AS runs, cumulative_wickets::int AS wickets,
                  cumulative_legal_balls::int AS balls
           FROM psl_staging.stg_over_snapshot
           ORDER BY match_id, innings_no, over_no::int DESC) s
       ON s.match_id = d.match_id AND s.innings_no = d.innings_no
WHERE d.runs IS DISTINCT FROM s.runs OR d.wickets IS DISTINCT FROM s.wickets
   OR d.balls IS DISTINCT FROM s.balls;








-- Query C: lists to look at. These are not “must be 0” checks. They give me the real values for DimDismissalType and DimExtraType, 
-- and show whether any match has no ball data (for example, abandoned matches).

SELECT 'dismissal_kind' AS what, dismissal_kind AS value, COUNT(*) AS delivery_rows
FROM psl_staging.stg_deliveries GROUP BY dismissal_kind
UNION ALL
SELECT 'extras_type', extras_type, COUNT(*)
FROM psl_staging.stg_deliveries GROUP BY extras_type
UNION ALL
SELECT 'innings_no / is_super_over', innings_no || ' / ' || is_super_over, COUNT(*)
FROM psl_staging.stg_deliveries GROUP BY innings_no, is_super_over
UNION ALL
SELECT 'over_no smallest to largest', MIN(over_no::int) || ' to ' || MAX(over_no::int), COUNT(*)
FROM psl_staging.stg_deliveries
UNION ALL
SELECT 'matches with no delivery rows', '', COUNT(*)
FROM psl_staging.stg_matches m
WHERE NOT EXISTS (SELECT 1 FROM psl_staging.stg_deliveries d WHERE d.match_id = m.match_id)
UNION ALL
SELECT 'matches with no squad rows', '', COUNT(*)
FROM psl_staging.stg_matches m
WHERE NOT EXISTS (SELECT 1 FROM psl_staging.stg_match_players p WHERE p.match_id = m.match_id)
UNION ALL
SELECT 'players per team per match: fewest to most', MIN(n) || ' to ' || MAX(n), COUNT(*)
FROM (SELECT COUNT(*) AS n FROM psl_staging.stg_match_players GROUP BY match_id, team) t
ORDER BY what, value;









-- =====================================================================
-- STAGING SUMMARY (psl_staging)
-- All four tables were loaded as TEXT, exactly as they arrived in the CSVs.
-- Row counts: stg_matches 357, stg_deliveries 83,799,
--             stg_match_players 7,858, stg_over_snapshot 13,594.
--
-- CHECKS THAT PASSED (all 0 problem rows)
--  - No duplicate or missing keys; no delivery without a match.
--  - Every batter, bowler, non-striker and dismissed player is found in
--    that match's squad, so every name can be mapped to a player_id.
--  - No leading or trailing spaces in names; team names are consistent (8 teams).
--  - Numbers, dates and 0/1 flags are in a valid format; empty cells are NULL.
--  - runs_total = runs_batter + runs_extras; wickets have a dismissal kind;
--    the legal-ball flag agrees with wides/no-balls; super-over flag agrees
--    with innings_no; teams belong to their own match.
--  - stg_deliveries and stg_over_snapshot agree on overs, runs, wickets and
--    legal balls for every innings (reconciliation).
--
-- DEFECTS FOUND AND HOW THEY WILL BE FIXED (raw data stays unchanged)
--  1. Same ground written two ways (Gaddafi, National, Sheikh Zayed with the
--     city in the name) and 43 matches with an empty city (Dubai 27, Sharjah 16)
--     -> fixed through psl_staging.map_venue when loading dim_venue.
--  2. Three player_ids appear with a number in brackets after the name,
--     e.g. "Imran Khan (2)" -> the " (number)" ending is removed and one name
--     is kept per player_id when loading dim_player.
--     The player_id, not the name, identifies a person.
--  3. Empty category values (stage, result, method, eliminator, etc.)
--     -> stored as 'Not Applicable' in dim_match.
--  4. Season labels come from Cricsheet and are mixed (2020/21 and 2021 cover
--     one split tournament). Kept as given; dim_date.year gives the calendar year.
--
-- VALUES FOUND FOR THE LOOKUP DIMENSIONS
--  - Dismissal kinds (10): bowled, caught, caught and bowled, hit wicket, lbw,
--    obstructing the field, retired hurt, retired out, run out, stumped.
--    retired hurt is not counted as a wicket.
--  - Extras types (7): byes, byes;noballs, legbyes, legbyes;noballs, noballs,
--    penalty, wides, plus one "no extras" row.
--  - Innings 1 to 4 (3 and 4 are super overs). Overs 0 to 19.
--  - 8 teams. 357 matches, every match has ball data and squad rows.
--    Squads have 11 to 12 players per team.
-- =====================================================================















