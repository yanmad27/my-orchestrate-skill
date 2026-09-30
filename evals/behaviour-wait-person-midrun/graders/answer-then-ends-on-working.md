---
type: regex
pattern: '(?is)\A(?:[ \t]*\n)*(?![ \t]*(?:🕒 Working|✅ Done: |❓ Waiting on you: ))[ \t]*\S[^\n]*\n(?:(?!🕒 Working).)*(?-i:(?<![^\n])(?<!```\n)(?<!```text\n)🕒 Working[ \t]*\n-------------\n🤖 \S(?:(?! · )[^\n])* · [^\n]*\S[ \t]*(?=\n|\Z)(?:\n&emsp;&ensp;🦾 \S(?:(?! · )[^\n])* · [^\n]*\S[ \t]*(?=\n|\Z))*(?:\n🤖 \S(?:(?! · )[^\n])* · [^\n]*\S[ \t]*(?=\n|\Z)(?:\n&emsp;&ensp;🦾 \S(?:(?! · )[^\n])* · [^\n]*\S[ \t]*(?=\n|\Z))*)*)\s*\Z'
---
