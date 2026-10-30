import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1])
if log.exists():
    lines = log.read_text(errors='replace').splitlines()
    selected = []
    context = 0
    for line in lines:
        line = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
        match = re.search(r'(?:\berror\b|\be:\s|What went wrong|Could not resolve|Could not find|Execution failed|FAILED|FAILURE:)', line, re.I)
        if match or context:
            if line and line not in selected:
                selected.append(line[:600])
            context = 6 if match else context - 1
        if len(selected) >= 24:
            break
    if selected:
        message = '\n'.join(selected)
        escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::error title=Native verification details::{escaped}')
