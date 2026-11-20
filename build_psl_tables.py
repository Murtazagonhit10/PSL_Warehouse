"""
Flatten Cricsheet PSL JSON match files into 4 CSV tables.

Usage (put this script in the same folder as the psl_json folder):
    python build_psl_tables.py

Optional: give the JSON folder and output folder explicitly:
    python build_psl_tables.py <folder_with_json_files> [output_folder]

Outputs (in the output folder):
    matches.csv        one row per match
    deliveries.csv     one row per delivery entry (wides / no-balls are their own rows)
    match_players.csv  one row per player per match (the playing XI)
    over_snapshot.csv  one row per innings per over (running score at end of over)

Rules used when counting:
    legal ball      = not a wide and not a no-ball. A penalty-only entry (penalty runs
                      for illegal fielding) is a dead ball that does not count in the
                      over, unless the over has fewer than 6 other legal balls.
    ball faced      = not a wide and not a dead-ball penalty entry
                      (a no-ball is still a ball the batter faces)
    runs conceded   = batter runs + wides + no-ball runs (byes and leg byes are not charged to the bowler)
    wicket          = any dismissal except "retired hurt" (retired hurt is kept in the
                      dismissal columns but does not add to wicket_count)
"""
import csv
import json
import sys
from pathlib import Path

NOT_A_WICKET = {"retired hurt"}


def join(values):
    return ";".join(str(v) for v in values) if values else ""


def main(src_dir, out_dir):
    src = Path(src_dir)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    if not src.is_dir():
        sys.exit(f"Folder not found: {src}")
    # Only *.json files are read; LICENSE.txt / README.txt are ignored.
    files = sorted(src.glob("*.json"))
    if not files:
        sys.exit(f"No .json files found in {src}")
    print(f"Reading {len(files)} JSON files from {src}")

    matches, deliveries, players, snapshots = [], [], [], []

    for path in files:
        match_id = path.stem
        data = json.loads(path.read_text(encoding="utf-8"))
        info = data["info"]
        teams = info.get("teams", [])
        outcome = info.get("outcome", {})
        by = outcome.get("by", {})
        event = info.get("event", {})
        umpires = info.get("officials", {}).get("umpires", [])
        registry = info.get("registry", {}).get("people", {})

        matches.append({
            "match_id": match_id,
            "match_date": (info.get("dates") or [""])[0],
            "season": info.get("season", ""),
            "event_name": event.get("name", ""),
            "match_number": event.get("match_number", ""),
            "stage": event.get("stage", ""),
            "venue": info.get("venue", ""),
            "city": info.get("city", ""),
            "team1": teams[0] if len(teams) > 0 else "",
            "team2": teams[1] if len(teams) > 1 else "",
            "toss_winner": info.get("toss", {}).get("winner", ""),
            "toss_decision": info.get("toss", {}).get("decision", ""),
            "winner": outcome.get("winner", ""),
            "win_by_type": next(iter(by), ""),
            "win_by_value": next(iter(by.values()), ""),
            "result": outcome.get("result", ""),          # tie / no result / draw
            "method": outcome.get("method", ""),          # e.g. D/L
            "eliminator": outcome.get("eliminator", ""),  # super over winner after a tie
            "player_of_match": join(info.get("player_of_match", [])),
            "umpire1": umpires[0] if len(umpires) > 0 else "",
            "umpire2": umpires[1] if len(umpires) > 1 else "",
        })

        for team, names in info.get("players", {}).items():
            for name in names:
                players.append({
                    "match_id": match_id,
                    "team": team,
                    "player_name": name,
                    "player_id": registry.get(name, ""),
                })

        for innings_no, inn in enumerate(data.get("innings", []), start=1):
            batting_team = inn.get("team", "")
            bowling_team = next((t for t in teams if t != batting_team), "")
            is_super_over = bool(inn.get("super_over", False))
            cum_runs = cum_wkts = cum_legal = 0
            ball_seq = 0

            for over in inn.get("overs", []):
                over_no = over["over"]
                over_runs = over_wkts = 0

                over_deliveries = over.get("deliveries", [])
                # A penalty-only entry (e.g. 5 runs for illegal fielding) can be a dead
                # ball that does not count in the over. It is legal only if the over has
                # fewer than 6 other legal balls; otherwise it is the extra dead-ball entry.
                other_legal = sum(
                    1 for x in over_deliveries
                    if not ({"wides", "noballs"} & set(x.get("extras", {})))
                    and set(x.get("extras", {})) != {"penalty"})
                penalty_legal_budget = max(0, 6 - other_legal)

                for d in over_deliveries:
                    ball_seq += 1
                    extras = d.get("extras", {})
                    wickets = d.get("wickets", [])
                    runs = d["runs"]

                    is_penalty_only = set(extras) == {"penalty"}
                    if is_penalty_only:
                        is_legal = penalty_legal_budget > 0
                        if is_legal:
                            penalty_legal_budget -= 1
                    else:
                        is_legal = not ("wides" in extras or "noballs" in extras)
                    ball_faced = 0 if ("wides" in extras or (is_penalty_only and not is_legal)) else 1
                    runs_conceded = (runs["batter"]
                                     + extras.get("wides", 0)
                                     + extras.get("noballs", 0))
                    real_wickets = [w for w in wickets if w["kind"] not in NOT_A_WICKET]
                    wicket_count = len(real_wickets)
                    first = (real_wickets or wickets or [None])[0]

                    deliveries.append({
                        "match_id": match_id,
                        "innings_no": innings_no,
                        "is_super_over": int(is_super_over),
                        "batting_team": batting_team,
                        "bowling_team": bowling_team,
                        "over_no": over_no,
                        "delivery_seq": ball_seq,
                        "batter": d["batter"],
                        "bowler": d["bowler"],
                        "non_striker": d["non_striker"],
                        "runs_batter": runs["batter"],
                        "runs_extras": runs["extras"],
                        "runs_total": runs["total"],
                        "runs_conceded": runs_conceded,
                        "extras_type": join(extras.keys()),
                        "is_legal_ball": int(is_legal),
                        "balls_faced": ball_faced,
                        "wicket_count": wicket_count,
                        "dismissed_player": first["player_out"] if first else "",
                        "dismissal_kind": first["kind"] if first else "",
                        "all_players_out": join([w["player_out"] for w in wickets]),
                        "all_wicket_kinds": join([w["kind"] for w in wickets]),
                        "fielders": join([f.get("name", "")
                                          for w in wickets
                                          for f in w.get("fielders", [])]),
                    })

                    over_runs += runs["total"]
                    over_wkts += wicket_count
                    cum_legal += int(is_legal)

                cum_runs += over_runs
                cum_wkts += over_wkts
                snapshots.append({
                    "match_id": match_id,
                    "innings_no": innings_no,
                    "is_super_over": int(is_super_over),
                    "batting_team": batting_team,
                    "bowling_team": bowling_team,
                    "over_no": over_no,
                    "runs_in_over": over_runs,
                    "wickets_in_over": over_wkts,
                    "cumulative_runs": cum_runs,
                    "cumulative_wickets": cum_wkts,
                    "cumulative_legal_balls": cum_legal,
                })

    for name, rows in [("matches", matches), ("deliveries", deliveries),
                       ("match_players", players), ("over_snapshot", snapshots)]:
        with open(out / f"{name}.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        print(f"{name}.csv: {len(rows):,} rows")


if __name__ == "__main__":
    # Default: look for a "psl_json" folder next to this script and write the
    # CSVs to an "out" folder next to it too. Works from any working directory.
    here = Path(__file__).resolve().parent
    src_arg = sys.argv[1] if len(sys.argv) > 1 else here / "psl_json"
    out_arg = sys.argv[2] if len(sys.argv) > 2 else here / "out"
    main(src_arg, out_arg)