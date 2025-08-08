import os
import requests
import json

def run_ollama(prompt):
    response = requests.post(
        "http://localhost:11434/api/generate",
        json={"model": "llama3", "prompt": prompt},
        stream=True,
    )
    response.raise_for_status()

    output = ""
    for line in response.iter_lines(decode_unicode=True):
        if line.strip():
            try:
                data = json.loads(line)
                output += data.get("response", "")
            except json.JSONDecodeError:
                continue
    return output

# Read commits from summary.txt (passed as env var)
commits_file = os.environ.get("COMMITS_FILE", "summary.txt")

with open(commits_file, "r") as f:
    commit_text = f.read()

prompt = f"Summarize the changes of tekton pipelines and tasks for the commits merged in recent 7 days into bullet points:\n{commit_text}"

response = run_ollama(prompt)
print(response)
