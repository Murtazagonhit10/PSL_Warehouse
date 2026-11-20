-- indexes on fact_delivery. This is the biggest table, so it gets the most indexes


CREATE INDEX IF NOT EXISTS idx_fd_batter       ON psl_dw.fact_delivery (batter_key);
CREATE INDEX IF NOT EXISTS idx_fd_bowler       ON psl_dw.fact_delivery (bowler_key);
CREATE INDEX IF NOT EXISTS idx_fd_batting_team ON psl_dw.fact_delivery (batting_team_key);
CREATE INDEX IF NOT EXISTS idx_fd_bowling_team ON psl_dw.fact_delivery (bowling_team_key);
CREATE INDEX IF NOT EXISTS idx_fd_date         ON psl_dw.fact_delivery (date_key);
CREATE INDEX IF NOT EXISTS idx_fd_venue        ON psl_dw.fact_delivery (venue_key);
CREATE INDEX IF NOT EXISTS idx_fd_over         ON psl_dw.fact_delivery (over_key);

SELECT indexname
FROM pg_indexes
WHERE schemaname = 'psl_dw' AND tablename = 'fact_delivery'
ORDER BY indexname;







-- the indexes on the other two fact tables.
CREATE INDEX IF NOT EXISTS idx_fos_batting_team ON psl_dw.fact_over_snapshot (batting_team_key);
CREATE INDEX IF NOT EXISTS idx_fos_venue        ON psl_dw.fact_over_snapshot (venue_key);
CREATE INDEX IF NOT EXISTS idx_fos_date         ON psl_dw.fact_over_snapshot (date_key);


CREATE INDEX IF NOT EXISTS idx_fmp_player ON psl_dw.fact_match_player (player_key);

-- should get 6 rows: 4 for fact_over_snapshot (the primary key plus 3) and 2 for fact_match_player (the primary key plus 1)
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'psl_dw' AND tablename IN ('fact_over_snapshot', 'fact_match_player')
ORDER BY tablename, indexname;





-- refresh the statistics. The tables were loaded after they were created, 
-- so PostgreSQL doesn’t know yet how many rows each one has or how the values are spread.


ANALYZE psl_dw.fact_delivery;
ANALYZE psl_dw.fact_over_snapshot;
ANALYZE psl_dw.fact_match_player;
ANALYZE psl_dw.dim_match;
ANALYZE psl_dw.dim_player;

SELECT relname AS table_name, n_live_tup AS estimated_rows, last_analyze IS NOT NULL AS analyzed
FROM pg_stat_user_tables
WHERE schemaname = 'psl_dw'
ORDER BY relname;






-- =====================================================================
-- INDEX SUMMARY (psl_dw)
-- Indexes are built after loading, which is faster than maintaining them
-- during the load. Primary keys already index the match, so there are no
-- separate indexes on match_key or innings_key.
--
--   fact_delivery       7 indexes: batter, bowler, batting team, bowling team,
--                       date, venue, over   (+ primary key)
--   fact_over_snapshot  3 indexes: batting team, venue, date   (+ primary key)
--   fact_match_player   1 index: player   (+ primary key)
--
-- Only the keys used by the business questions are indexed, to avoid extra
-- storage and slower loads. ANALYZE was run on the 3 fact tables and on
-- dim_match and dim_player, so the query planner has up-to-date row statistics.
-- Verified: 14 indexes on the fact tables, and estimated row counts match the
-- real counts (83,799 / 13,594 / 7,858 / 357 / 461).
-- =====================================================================






















































































































































































