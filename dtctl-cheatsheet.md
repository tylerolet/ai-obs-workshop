# dtctl Cheatsheet

## Auth & Context

```bash
# Login / add a new context
dtctl auth login --context <name> --environment "https://<tenant>.apps.dynatrace.com"

# Switch context
dtctl config use-context <name>           # persistent switch
dtctl ctx <name>                          # shorthand alias

# Per-command context override (no persistent switch)
dtctl get workflows --context staging

# Inspect current context
dtctl config current-context
dtctl config describe-context $(dtctl config current-context) --plain

# Whoami
dtctl auth whoami --plain

# Permission check
dtctl auth can-i create workflows
dtctl auth can-i delete dashboards
```

## Core Verbs

| Verb | Description |
|------|-------------|
| `get` | List resources |
| `describe` | Show resource details |
| `edit` | Edit resource interactively |
| `apply` | Create or update from file |
| `delete` | Delete resource |
| `exec` | Execute workflow / function / analyzer |
| `query` | Run a DQL query |
| `wait` | Wait for a query condition |
| `logs` | Print execution logs |
| `history` | Show document version history |
| `restore` | Restore a previous version |
| `diff` | Compare local file vs live resource |
| `verify` | Validate DQL without running |
| `find` | Discover resources by data |
| `open` | Open resource in browser |
| `share` | Share a document with a user |
| `commands` | List all commands (machine-readable) |

## Resource Types (and aliases)

| Resource | Aliases |
|----------|---------|
| `workflow` | `wf` |
| `workflow-execution` | `wfe` |
| `dashboard` | `dash` |
| `notebook` | `nb` |
| `bucket` | `bkt` |
| `settings` | `setting` |
| `settings-schema` | `schema` |
| `slo` | — |
| `lookup` | `lkup` |
| `extension` | `ext` |
| `extension-config` | `extcfg` |
| `function` | `fn`, `func` |
| `analyzer` | `analyzers` |
| `copilot-skill` | `copilot-skills` |
| `app` | `apps` |
| `group` | `groups` |
| `user` | `users` |
| `edgeconnect` | `ec` |
| `intent` | `intents` |
| `notification` | `notifications` |
| `trash` | `deleted` |

## Get & Describe

```bash
# List resources
dtctl get workflows
dtctl get workflows --mine                    # only yours
dtctl get dashboards -o json --plain          # JSON, no color
dtctl get dashboards -o yaml --plain

# Find IDs by name
dtctl get workflows -o json --plain | jq -r '.[] | "\(.id)  \(.name)"'

# Describe a specific resource
dtctl describe workflow <id>
dtctl describe dashboard <id> -o json --plain
```

## Apply (Create / Update)

```bash
# Create or update from file
dtctl apply -f workflow.yaml
dtctl apply -f workflow.yaml --plain

# With template variables
dtctl apply -f workflow.yaml --set environment=prod --set team=platform

# Preview diff without applying
dtctl diff -f workflow.yaml

# Export existing resource to file
dtctl get workflow <id> -o yaml --plain > workflow.yaml
dtctl get dashboard <id> -o yaml --plain > dashboard.yaml
```

## Delete & Restore

```bash
dtctl delete workflow <id>
dtctl history dashboard <id>
dtctl restore dashboard <id> --version 3
```

## Execute

```bash
# Run a workflow
dtctl exec workflow <id>

# Run with input payload
dtctl exec function <id> --payload '{"key":"value"}' --plain

# Run an analyzer
dtctl exec analyzer <id> --input '{"timeframe":"now-2h"}' --plain
```

## DQL Queries

```bash
# Inline query
dtctl query "fetch logs | filter status='ERROR' | limit 100"

# Inline query with chart output
dtctl query "timeseries avg(dt.host.cpu.usage)" -o chart --plain
dtctl query "timeseries avg(dt.host.cpu.usage), by:{host.name}, filter:startsWith(host.name, \"aks\")" -o chart

# Query from file with variables
dtctl query -f query.dql --set host=h-123 --set timerange=2h -o json --plain

# Wait for results
dtctl wait query "fetch spans | filter test_id='test-123'" --for=count=1 --timeout 5m
dtctl wait query "fetch logs | filter status='ERROR'" --for=any

# Validate DQL without running
dtctl verify query 'fetch logs | limit 10' --fail-on-warn
```

## Output Flags

| Flag | Use |
|------|-----|
| `-o json` | JSON output |
| `-o yaml` | YAML output |
| `-o table` | Table (default) |
| `-o wide` | Wide table |
| `-o csv` | CSV |
| `-o chart` | ASCII time series chart |
| `-o sparkline` | ASCII sparkline |
| `-o barchart` | ASCII bar chart |
| `--plain` | Strip colors/prompts — use for scripting/AI |
| `--agent` / `-A` | Structured JSON envelope (auto in AI envs) |

## Template Variables in Files

```yaml
# workflow.yaml
title: "{{.environment}} Deployment"
owner: "{{.team}}"
trigger:
  schedule:
    cron: "{{.schedule | default \"0 0 * * *\"}}"
```

```dql
# query.dql
fetch logs
| filter host.name == "{{.host}}"
| filter timestamp > now() - {{.timerange | default "1h"}}
```

## Context & Credentials Setup

```bash
# Store token
dtctl config set-credentials "my-token" --token "$TOKEN"

# Create context
dtctl config set-context "prod" \
  --environment "https://tenant.apps.dynatrace.com" \
  --token-ref "my-token" \
  --safety-level readwrite-mine
```

### Safety Levels

| Level | Use Case |
|-------|----------|
| `readonly` | Production monitoring |
| `readwrite-mine` | Development (recommended default) |
| `readwrite-all` | Shared environments |
| `dangerously-unrestricted` | Emergency admin |

## Sharing & Discovery

```bash
dtctl share dashboard <id> --user email@example.com
dtctl unshare dashboard <id> --user email@example.com

dtctl find intents --data trace.id=abc
dtctl open intent <app/intent> --data key=value
```

## Breakpoints (Live Debugging)

```bash
# Target a workload
dtctl update breakpoint --filters k8s.namespace.name:prod

# Create a breakpoint
dtctl create breakpoint OrderController.java:310

# List / inspect
dtctl get breakpoints
dtctl describe OrderController.java:310

# Add a condition
dtctl update breakpoint OrderController.java:310 --condition "orderId != null"

# Disable
dtctl update breakpoint OrderController.java:310 --enabled false

# View snapshots
dtctl query "fetch application.snapshots | sort timestamp desc | limit 5" --decode-snapshots

# Delete
dtctl delete breakpoint OrderController.java:310
```

## Handy One-Liners

```bash
# Discover all available commands
dtctl commands --brief -o json

# Show all my workflows as a table
dtctl get workflows --mine

# Export all my dashboards to YAML files
dtctl get dashboards --mine -o json --plain | \
  jq -r '.[].id' | \
  xargs -I{} sh -c 'dtctl get dashboard {} -o yaml --plain > {}.yaml'

# Quick log tail
dtctl query "fetch logs | sort timestamp desc | limit 25" --plain

# CPU usage chart for a host prefix
dtctl query "timeseries avg(dt.host.cpu.usage), by:{host.name}, filter:startsWith(host.name, \"aks\")" -o chart

# Check what you're allowed to do
dtctl auth can-i create workflows
dtctl auth can-i delete dashboards
```
