# PSL Data Warehouse

A dimensional data warehouse built from the ball-by-ball history of the Pakistan Super League (PSL), using PostgreSQL and Python.

Course: DL3004 Data Warehousing and Business Intelligence Lab, Fall 2026
Institution: FAST-NUCES, Lahore Campus
Program: BS Data Science

Group members

| Name | Roll number |
|---|---|
| Ghulam Murtaza | 24L-2566 |
| Waniya Suhail | 24L-2552 |
| Abdul Rehman | 24L-2613 |

## Overview

The PSL has been played since 2016, and every ball of every match has been recorded. The data is normally seen one scorecard at a time. This project loads the whole history into a star schema so that questions across matches, seasons, teams, players and venues can be answered with ordinary SQL.

The warehouse holds 357 matches, 83,799 delivery entries, 13,594 overs and 7,858 squad selections, covering the seasons from 2015/16 to 2026.

## Data Source

The data comes from [Cricsheet](https://cricsheet.org), which publishes one JSON file for each match. It is released under the Open Data Commons Attribution License (ODC-BY). The raw JSON files are kept in `02_Data/psl_json`.

## Architecture

The data moves through three PostgreSQL schemas in one database (`PSL_Warehouse`).

| Schema | Contents |
|---|---|
| `psl_staging` | Four tables loaded as text, exactly as they come from the CSV files. They are never edited. |
| `psl_dw` | The star schema: 9 dimension tables and 3 fact tables. All cleaning and type conversion happens when these are loaded. |
| `psl_reporting` | Views that answer the ten business questions. |

The flow is: JSON files, then a Python script that flattens them into four CSV files, then the staging tables, then the warehouse, then the reporting views.

## Star Schema

**Fact tables**

| Table | Type | Grain | Rows |
|---|---|---|---|
| `fact_delivery` | Transaction | One delivery entry (a ball, wide or no-ball) | 83,799 |
| `fact_over_snapshot` | Periodic snapshot | One over of one innings of one match | 13,594 |
| `fact_match_player` | Factless | One player in one team's playing XI in one match | 7,858 |

**Dimension tables**

| Table | Rows | Notes |
|---|---|---|
| `dim_date` | 4,018 | One row for each day from 2016 to 2026 |
| `dim_match` | 357 | Season, stage, toss, result, umpires |
| `dim_venue` | 7 | Cleaned through a mapping table |
| `dim_team` | 8 | Used as both batting team and bowling team |
| `dim_player` | 461 | 460 players and one Not Applicable row. Used as batter, bowler, non-striker and dismissed player |
| `dim_innings` | 4 | Innings 1 and 2, and the two super-over innings |
| `dim_over` | 20 | Over number with its phase (Powerplay, Middle, Death) |
| `dim_dismissal_type` | 11 | Flags for wickets and for wickets credited to the bowler |
| `dim_extra_type` | 8 | Flags for wides, no-balls, byes, leg byes and penalties |

Every dimension has an integer surrogate key, and the source business key is kept as a unique column. Where a ball has no wicket or no extra, the fact row points to a Not Applicable row with key -1, so no foreign key is ever empty.

## Repository Structure

```
01_Project_Documentation/   Phase 1 documents, data dictionary, cleaning and quality reports
02_Data/
    psl_json/               Raw Cricsheet match files
    csv/                    Flattened files produced by the script
03_ETL/
    build_psl_tables.py     Flattens the JSON files into four CSV files
    psl_staging.sql         Schemas, staging tables, profiling checks, venue mapping
    psl_data_quality.sql    Validation queries
04_Data_Warehouse/
    psl_dw.sql              Dimension and fact tables, dimension loads, fact loads
    psl_indexes.sql         Indexes and statistics
05_Analytics/
    psl_reporting.sql       Views for the ten business questions
06_Dashboard/               Power BI report (Phase 3)
```

## How to Run

1. Create a PostgreSQL database named `PSL_Warehouse`.
2. Flatten the JSON files into CSV files:
   ```
   python 03_ETL/build_psl_tables.py 02_Data/psl_json 02_Data/csv
   ```
   This writes `matches.csv`, `deliveries.csv`, `match_players.csv` and `over_snapshot.csv`.
3. Run the first part of `psl_staging.sql` to create the schemas and the four staging tables. Import each CSV file into its table (in pgAdmin: Import/Export, header on). Then run the rest of the file for the profiling checks and the venue mapping table.
4. Run `psl_dw.sql`. It creates the dimension and fact tables and loads them in that order.
5. Run `psl_indexes.sql`.
6. Run `psl_data_quality.sql`. Every check should return 0 problem rows.
7. Run `psl_reporting.sql` to create the reporting views.

All load statements use `ON CONFLICT DO NOTHING`, so a load can be run again without creating duplicate rows.

## Data Cleaning

The raw data was in good shape, and the problems found were handled while loading the warehouse. The staging tables were not changed.

- The same ground was written under two names, and 43 matches had no city. These were fixed with a mapping table, which gives 7 venues.
- Three players had a number in brackets added to their name. The player ID identifies a person, so the number is removed and one name is kept for each ID.
- Empty descriptive values are stored as Not Applicable.
- Penalty runs are recorded as a separate entry. When such an entry follows six normal balls it is a dead ball, so it is not counted as a legal ball or a ball faced.

The details are in the Data Cleaning Report.

## Data Quality

The checks are in `psl_data_quality.sql` and are grouped as follows.

| Group | Result |
|---|---|
| Completeness: row counts and missing values | Every source row reached the warehouse |
| Accuracy: totals compared with the source | Runs 115,022, wickets 4,503 and legal balls 80,814, with no difference |
| Integrity: orphan keys and duplicate keys | 0 in every table |
| Business rules on each ball | 0 violations |
| Cricket limits, such as at most 6 legal balls in an over | 0 violations |

The cricket-limit checks found one real defect, the penalty entries described above. It was fixed in the script, the affected tables were reloaded, and the checks were run again. The Data Quality Report has the full results.

## Reporting Views

`psl_reporting.sql` contains one view for each business question.

| Question | View |
|---|---|
| 1. Top batters and strike rate by season | `v_q1_top_batters_by_season` |
| 2. Top bowlers and economy by season | `v_q2_top_bowlers_by_season` |
| 3. Run rate and wickets lost by phase | `v_q3_phase_scoring` |
| 4. Average first innings total and chasing wins by venue | `v_q4_venue_first_innings` |
| 5. Effect of the toss on the result | `v_q5_toss_impact` |
| 6. Score after 6, 10 and 15 overs against the result | `v_q6_checkpoint_scores` |
| 7. Dismissal types by phase and season | `v_q7_dismissal_mix` |
| 8. Wides and no-balls by bowling team | `v_q8_extras_by_team` |
| 9. Dot ball share of powerplay balls by bowler | `v_q9_powerplay_dot_balls` |
| 10. Appearances by player, team and season, and players with more than one franchise | `v_q10_player_appearances`, `v_q10_multi_franchise_players` |

The views keep sums and counts. Ratios such as strike rate, economy and run rate are calculated from those totals. Super overs are left out of every view that uses ball or over data.

## Project Status

| Phase | Content | Status |
|---|---|---|
| 1 | Business analysis and dimensional design | Complete |
| 2 | Physical implementation and ETL | Complete |
| 3 | Analytics and Power BI dashboard | Not started |

## Credits

Match data: Cricsheet, https://cricsheet.org, licensed under ODC-BY.
