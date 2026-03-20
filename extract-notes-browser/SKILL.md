---
name: extract-notes:browser
description: Extract notes from a webpage in the browser
allowed-tools:
  - mcp__browser-control__*
  - Read
  - Skill(extract-notes)
---

# Extract Notes from Browser Webpage

Extract content from the current browser tab (or a specific URL) and format as notes.

## Input

```
$ARGUMENTS = [source-or-heading] [notes-taking-skill]
```

- **source-or-heading** (optional): URL or Org heading with embedded link
  - If omitted, uses current browser tab
- **notes-taking-skill** (optional): passed through to extract-notes

## Step 1: Parse Arguments

```
If $ARGUMENTS contains [[url][...]] org link pattern:
  - Extract URL: regex \[\[([^\]]+)\](?:\[[^\]]*\])?\]
  - Remaining text = title context
Else if first arg starts with http://, https://:
  - First arg = URL
  - Second arg (if any) = notes-taking-skill
Else if $ARGUMENTS is non-empty:
  - $ARGUMENTS = notes-taking-skill
  - Detect from current tab
Else:
  - Detect from current tab
```

## Step 2: Ensure Tab is Available

If URL was provided, check if it's already open:

```
PARALLEL:
  - mcp__browser-control__get-current-tab
  - mcp__browser-control__get-list-of-open-tabs
```

- Current tab matches URL => proceed
- Found in other tabs => use that tab ID
- Not found => open with `mcp__browser-control__open-browser-tab`

If no URL provided:
```
Use mcp__browser-control__get-current-tab
```

## Step 3: Extract Content

```
Use mcp__browser-control__get-tab-web-content with the tab ID
```

From the page content, identify:
- **title**: Article/post title
- **author**: If available
- **date**: Publication date if available
- **source**: URL/domain name

## Step 4: Clean and Format

Invoke `Skill(extract-notes)` to clean the extracted content and format as notes.