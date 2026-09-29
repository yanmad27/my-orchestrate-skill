---
type: regex
pattern: '(?m)^(?:⏳ Working:[ \t]*\n(?:[ \t]*\n)*\[Lead\] [^\n(]*\([^\n]*\)[ \t]*(?=\n|\Z)(?:\n(?:\[Lead\] [^\n(]*\([^\n]*\)[ \t]*(?=\n|\Z)|\|_ \[[^\]\n]+\] [^\n]*\((?:running|permission pending)\)[ \t]*(?=\n|\Z)))*(?!(?:\n[ \t]*)*\n[ \t]*(?:\||-[ \t]*\[|\[[^\]\n]+\] ))|✅ Done: \S.*|❓ Waiting on you: \S.*)$'
---
