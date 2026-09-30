#!/usr/bin/perl
# C6 static guard: every place a fixture EXECUTES the slp-gc binary (whatever the arguments) must be a line
# marked "# slpgc-sandboxed" sitting under an env block that sets SLP_GC_TEST=1 and a sandbox HOME=.
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
    my $from = $i >= 12 ? $i - 12 : 0;
    my $blk = join "\n", @l[$from .. $i];
    unless ($blk =~ /SLP_GC_TEST=1/ && $blk =~ /HOME="\$/) { print "$f:$n: wrapper env lacks SLP_GC_TEST=1 / sandbox HOME\n"; $bad = 1 }
  }
}
exit($bad ? 1 : 0);
