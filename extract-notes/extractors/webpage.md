# Web Page Extraction

## 1. Get Tab Content

Find tab by URL if needed:
```
Use mcp__browser-control__get-list-of-open-tabs to find tab ID matching URL
```

Then fetch content:
```
Use mcp__browser-control__get-tab-web-content with the tab ID
```

## 2. Extract Metadata

From the page content, identify:
- **title**: Article/post title
- **author**: If available
- **date**: Publication date if available
- **source**: URL/domain name

## 3. Output

Pass metadata and article text to the note formatting step.