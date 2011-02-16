package Distar;

use strictures 1;
use base qw(Exporter);

our @EXPORT = qw(
  author manifest_include run_preflight
);

sub import {
  strictures->import;
  shift->export_to_level(1,@_);
}

sub author { our $Author = shift }

our @Manifest = (
  'lib' => '.pm',
  't' => '.t',
  't/lib' => '.pm',
  'xt' => '.t',
  'xt/lib' => '.pm',
  '' => '.PL',
  '' => qr{Changes|MANIFEST|README|META\.yml},
  'maint' => qr{[^.].*},
);

sub manifest_include {
  push @Manifest, @_;
}

sub write_manifest_skip {
  use autodie;
  my @files = @Manifest;
  my @parts;
  while (my ($dir, $spec) = splice(@files, 0, 2)) {
    my $re = ($dir ? $dir.'/' : '').
      ((ref($spec) eq 'Regexp')
        ? $spec
        : !ref($spec)
          ? ".*\Q${spec}\E"
          : die "spec must be string or regexp, was: ${spec} (${\ref $spec})");
    push @parts, $re;
  }
  my $final = '^(?!'.join('|', map "${_}\$", @parts).')';
  open my $skip, '>', 'MANIFEST.SKIP';
  print $skip "${final}\n";
  close $skip;
}

sub run_preflight {
  system("git fetch");

  for (scalar `git status`) {
    /Your branch is (behind|ahead of)/ && die "Not synced with upstream";
  }

  for (scalar `git diff`) {
    length && die "Oustanding changes";
  }
  my @cached = grep /^\+/, `git diff --cached -U0`;
  @cached == 2 or die "Pre-commit Changes not just Changes line";
  $cached[0] eq "+++ b/Changes\n" or die "Changes not changed";
  my $ymd = sprintf(
    "%i-%02i-%02i", (localtime)[5]+1900, (localtime)[4]+1, (localtime)[3]
  );
  $cached[1] eq "+$ARGV[0] - $ymd\n" or die "Changes new line should be: \n\n$ARGV[0] - $ymd\n ";
}

sub MY::postamble { <<'END'; }
preflight:
	perl -Idistar/lib -MDistar -erun_preflight $(VERSION)
upload: preflight disttest $(DISTVNAME).tar$(SUFFIX)
	cpan-upload $(DISTVNAME).tar$(SUFFIX)
release: upload
	git commit -a -m "Release commit for $(VERSION)"
	git tag release_$(VERSION)
	git push
	git push --tags
distdir: readmefile
readmefile: create_distdir
	pod2text $(VERSION_FROM) >$(DISTVNAME)/README
END

{
  no warnings 'redefine';
  sub main::WriteMakefile {
    my %args = @_;
    ExtUtils::MakeMaker::WriteMakefile(
      @_, AUTHOR => our $Author, ABSTRACT_FROM => $args{VERSION_FROM},
      test => { TESTS => ($args{test}{TESTS}||'').' xt/*.t' },
    );
  }
}

END {
  write_manifest_skip()
}

1;
