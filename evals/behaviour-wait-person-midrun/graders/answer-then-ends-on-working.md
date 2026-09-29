---
type: regex
pattern: '(?is)\A(?:[ \t]*\n)*(?![ \t]*(?:⏳ Working:|✅ Done: |❓ Waiting on you: ))[ \t]*\S[^\n]*\n(?:(?!⏳ Working:).)*(?-i:⏳ Working:[ \t]*\n(?:[ \t]*\n)*\[Lead\] [^\n(]*\([^\n]*\)[ \t]*(?=\n|\Z)(?:\n(?:\[Lead\] [^\n(]*\([^\n]*\)[ \t]*(?=\n|\Z)|\|_ \[[^\]\n]+\] [^\n]*\((?:running|permission pending)\)[ \t]*(?=\n|\Z)))*(?!(?:\n[ \t]*)*\n[ \t]*(?:\||-[ \t]*\[|\[[^\]\n]+\] )))\s*\Z'
---
