"""Inspect the public repository's latest Actions run without an API token."""
import argparse
import json
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--repository", default="windbullet/windblower")
options = parser.parse_args()
base = "https://api.github.com/repos/" + options.repository


def get(path):
    request = urllib.request.Request(base + path, headers={"User-Agent": "PureTone-build", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


run = get("/actions/runs?per_page=1")["workflow_runs"][0]
print(json.dumps({key: run[key] for key in ["id", "head_sha", "status", "conclusion", "html_url"]}))
for job in get(f"/actions/runs/{run['id']}/jobs")["jobs"]:
    print(json.dumps({"job": job["id"], "status": job["status"], "steps": [{key: step[key] for key in ["name", "status", "conclusion"]} for step in job["steps"]]}))
    if job["conclusion"] == "failure":
        for annotation in get("/check-runs/" + job["check_run_url"].split("/")[-1] + "/annotations?per_page=100"):
            print(json.dumps({key: annotation[key] for key in ["annotation_level", "message"]}))
