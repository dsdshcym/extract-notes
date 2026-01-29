# Podcast Extraction

## 1. Fetch Page Content & Metadata

First, get the webpage content to find metadata and any show notes:
```
Use mcp__browser-control__get-tab-web-content with current tab
```

Extract from page:
- **title**: Episode title
- **podcast**: Show name
- **description**: Episode description / show notes
- **outline**: Look for timestamps, chapter markers, or structured sections in show notes

## 2. Get Audio URL

### Blog/Website with Embedded Audio
Look for direct audio links in page content:
- `.mp3`, `.m4a` URLs (often from libsyn, anchor.fm, podbean, etc.)
- `<audio>` tags or audio player elements
- Links to podcast platforms (Overcast, Apple Podcasts, Spotify) = podcast episode

```bash
# Download directly if URL found
curl -L -o /tmp/podcast-episode.mp3 "{AUDIO_URL}"
```

### Overcast.fm
Look for `<audio>` tag or `data-audio-src` attribute in page content.

### Ximalaya (喜马拉雅)
```bash
# Extract audio URL from page - look for m4a/mp3 in page source or API response
# The URL is often in a JSON blob or script tag
```

### Apple Podcasts
Look for `assetUrl` in page metadata or embedded JSON.

### Xiaoyuzhoufm (小宇宙)
Audio URL often in page data or requires inspecting network requests.

### Fallback: yt-dlp
Many podcast sites are supported:
```bash
yt-dlp -j "{URL}" 2>/dev/null | jq '{title, uploader, duration_string, description}'
yt-dlp -f 'bestaudio' -o "/tmp/podcast-%(id)s.%(ext)s" "{URL}"
```

## 3. Transcribe Audio

```bash
# Convert to WAV (16kHz mono for whisper)
ffmpeg -i /tmp/podcast-*.m4a -ar 16000 -ac 1 -c:a pcm_s16le /tmp/podcast-audio.wav -y

# Transcribe with whisper-cpp
# Build prompt from title, podcast name, and description (proper nouns, names, terms)
whisper-cli -m ~/.whisper/ggml-large-v3.bin -l auto -f /tmp/podcast-audio.wav -otxt -of /tmp/podcast-transcript --prompt "{PROMPT}"
```

**Build the prompt** from metadata:
- Extract proper nouns, guest names, technical terms from title/description
- Example: Episode "对话张三：AI的未来" => `--prompt "张三, AI, 人工智能"`

Then read `/tmp/podcast-transcript.txt`.

## 4. Structure Content

Priority for structure:
1. **Show notes with timestamps**: Use as section headers `[MM:SS]`
2. **Chapter markers from page**: If podcast app shows chapters
3. **Description outline**: If show notes have bullet points or numbered sections
4. **Natural topic breaks**: Infer from transcript content

**Always include timestamps** at top-level sections in `[MM:SS]` format when available.