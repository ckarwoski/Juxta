import json


def render(summary):
    lines = []
    for key, value in summary.items():
        lines.append(f"{key:>8}: {value}")
    return "\n".join(lines)


def summarize(records):
    total = sum(r["bytes"] for r in records)
    peak = max(r["bytes"] for r in records)
    return {"total": total, "peak": peak}


def load(path):
    with open(path) as f:
        return json.load(f)


def main():
    records = load("traffic.json")
    print(render(summarize(records)))


if __name__ == "__main__":
    main()
