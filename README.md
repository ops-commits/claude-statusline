# Claude Code Status Line

Shows usage limits and context in the Claude Code status bar.

```
300k/1M | 5h 42% | 7d 65% +5%
```

- **Context**: tokens used / window size
- **5h**: five-hour rolling usage %
- **7d**: seven-day rolling usage % with pace indicator (+/-)
- **?**: data is stale (API temporarily unavailable)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kayhng/claude-statusline/main/install.sh | bash
```

Restart Claude Code. That's it.

## Updates

Automatic. The script checks once per day and self-updates in the background.

## Uninstall

```bash
rm ~/.claude/statusline-command.sh
```

Then remove the `statusLine` key from `~/.claude/settings.json`.
