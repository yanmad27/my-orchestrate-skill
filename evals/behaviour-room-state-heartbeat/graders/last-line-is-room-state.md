---
type: regex
pattern: '(?s)\A(?!.*(?:✅ Done:|❓ Waiting on you:)).*⏳ Working:[ \t]*\n(?:[ \t]*\n)*\[Lead\] [^\n(]*\([^\n]*\)[ \t]*(?=\n|\Z)(?:\n(?:\[Lead\] [^\n(]*\([^\n]*\)[ \t]*(?=\n|\Z)|\|_ \[[^\]\n]+\] [^\n]*\((?:running|permission pending)\)[ \t]*(?=\n|\Z)))*(?!(?:\n[ \t]*)*\n[ \t]*(?:\||-[ \t]*\[|\[[^\]\n]+\] ))'
---
