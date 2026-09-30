#!/usr/bin/perl
# C6 static guard: every place a fixture EXECUTES the slp-gc binary (whatever the arguments) must be a line
# marked "# slpgc-sandboxed" whose OWN command (its backslash-continued env -i lines) sets SLP_GC_TEST=1 and a
# sandbox HOME=. Only fx_gc_bare (read-only report, production mode) is exempt from SLP_GC_TEST, with structural checks.
# Usage: check-sandboxed.pl <fixture file>...   Prints one "file:line: reason" per violation; exit 1 if any.
use strict; use warnings;
my $bad = 0;
my $ref = qr/(\$\{?(?:GC|FX_GC|BIN|SLP_GC_BIN)\}?|[\w.\/-]*paseo\/bin\/slp-gc)/;
sub is_exec {
  my ($pre) = @_;
  (my $p = $pre) =~ s/[\s"']+$//;
  return 1 if $p eq '';
  my @t = split /\s+/, $p;
  my $last = $t[-1];
  return 0 if $last =~ /=$|:-$/;
  return 1 if $last =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
  (my $n = $last) =~ s/^["'(\$]+//;
  return 1 if $n eq '' || $n =~ /^(?:;|&&|\|\||\||then|do|\{|!|bash|sh|env|exec|time|-c)$/;
  return 1 if $last =~ /^\$\($/ || $last =~ /;$|&&$|\|\|$|\|$/;
  if ($n =~ /^-/ && @t >= 2 && $t[-2] =~ /^(?:bash|sh)$/) { return $n ne '-n' }
  return 0;
}
for my $f (@ARGV) {
  open my $fh, '<', $f or do { print "$f: unreadable\n"; $bad = 1; next };
  my @l = <$fh>; close $fh;
  for my $i (0 .. $#l) {
    my $line = $l[$i]; chomp $line;
    next if $line =~ /^\s*#/ || $line =~ /^\s*(?:FX_GC|GC|BIN)=/;
    my $hit = 0;
    while ($line =~ /$ref/g) { my $pre = substr($line, 0, $-[0]); if (is_exec($pre)) { $hit = 1; last } }
    next unless $hit;
    my $n = $i + 1;
    if ($line !~ /# slpgc-sandboxed/) { print "$f:$n: slp-gc executed outside a sandboxed wrapper\n"; $bad = 1; next }
    my $s = $i;   # the marked line's own command: its backslash-continued lines, nothing from neighbours
    $s-- while $s > 0 && $l[$s - 1] =~ /\\\s*$/;
    my $cmd = join "\n", @l[$s .. $i];
    my $h = $s; $h-- while $h > 0 && $l[$h] !~ /^(\w+)\(\)\s*\{/;
    my $fn = $l[$h] =~ /^(\w+)\(\)\s*\{/ ? $1 : '';
    if ($fn eq 'fx_gc_bare') {   # the one production-mode exception: read-only `report`, structurally enforced
      my $body = join "\n", @l[$h .. $i];
      my @miss;
      push @miss, 'env -i' unless $cmd =~ /\benv -i\b/;
      push @miss, 'sandbox HOME' unless $cmd =~ /HOME="\$/;
      push @miss, 'logging stubs first on PATH' unless $cmd =~ /PATH="\$FX_BIN:/;
      push @miss, 'SLP_GC_TEST must not be set' if $cmd =~ /SLP_GC_TEST=/;
      push @miss, 'report-only guard' unless $body =~ /case " \$\* " in \*" report "\*\) ;; \*\) [^\n]*return 2/;
      push @miss, '--apply refusal' unless $body =~ /\*" --apply "\*\) [^\n]*return 2/;
      if (@miss) { print "$f:$n: fx_gc_bare violates its read-only contract: " . join(', ', @miss) . "\n"; $bad = 1 }
      next;
    }
    my @miss;
    push @miss, 'env -i' unless $cmd =~ /\benv -i\b/;
    push @miss, 'SLP_GC_TEST=1' unless $cmd =~ /SLP_GC_TEST=1/;
    push @miss, 'sandbox HOME' unless $cmd =~ /HOME="\$/;
    if (@miss) { print "$f:$n: wrapper " . ($fn || '(none)') . " lacks in its own command: " . join(', ', @miss) . "\n"; $bad = 1 }
  }
}
exit($bad ? 1 : 0);
