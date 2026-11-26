# Navigation eval

Questions an agent new to the repository should answer by finding the right
file. It measures how easy the layout is to find your way in, not the code.

Each question has the files a correct answer names (`expected`). Run it with
a fresh agent per layout you compare, the same prompt each time, and record
how many it answers correctly and how many tool calls and tokens it took:

```bash
claude -p "$(jq -r '.[] | "\(.id): \(.question)"' evals/navigation/questions.json)

Answer each question with the file paths that answer it, one line per question,
prefixed by its id. Search this repository only." --output-format json
```

Update `expected` when a move changes an answer.
