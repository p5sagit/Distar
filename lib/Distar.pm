package Distar;

use strictures 1;
use base qw(Exporter);

use Config;
use File::Spec;

our @EXPORT = qw(
  author manifest_include run_preflight
);

sub import {
  strictures->import;
  shift->export_to_level(1,@_);
}

sub author { our $Author = shift }

our $Ran_Preflight;

our @Manifest = (
  'lib' => '.pm',
  't' => '.t',
  't/lib' => '.pm',
  'xt' => '.t',
  'xt/lib' => '.pm',
  '' => qr{[^/]*\.PL},
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
            # print ref as well as stringification in case of overload ""
          : die "spec must be string or regexp, was: ${spec} (${\ref $spec})");
    push @parts, $re;
  }
  my $final = '^(?!'.join('|', map "${_}\$", @parts).')';
  open my $skip, '>', 'MANIFEST.SKIP';
  print $skip "${final}\n";
  close $skip;
}

sub run_preflight {
  $Ran_Preflight = 1;

  system("git fetch");

  my $make = $Config{make};
  my $null = File::Spec->devnull;

  for (scalar `"$make" manifest 2>&1 >$null`) {
    $_ && die "$make manifest changed:\n$_ Go check it and retry";
  }

  for (scalar `git status`) {
    /^# On branch master/ || die "Not on master. EEEK";
    /Your branch is behind|Your branch and .*? have diverged/ && die "Not synced with upstream";
  }

  for (scalar `git diff`) {
    length && die "Outstanding changes";
  }
  my $ymd = sprintf(
    "%i-%02i-%02i", (localtime)[5]+1900, (localtime)[4]+1, (localtime)[3]
  );
  my @cached = grep /^\+/, `git diff --cached -U0`;
  @cached > 0 or die "Please add:\n\n$ARGV[0] - $ymd\n\nto Changes stage Changes (git add Changes)";
  @cached == 2 or die "Pre-commit Changes not just Changes line";
  $cached[0] =~ /^\+\+\+ .\/Changes\n/ or die "Changes not changed";
  $cached[1] eq "+$ARGV[0] - $ymd\n" or die "Changes new line should be: \n\n$ARGV[0] - $ymd\n ";
}

sub MY::postamble {
    my $post = <<'END';
preflight:
	perl -IDistar/lib -MDistar -erun_preflight $(VERSION)
release: preflight
	$(MAKE) disttest
	rm -rf $(DISTVNAME)
	$(MAKE) $(DISTVNAME).tar$(SUFFIX)
	git commit -a -m "Release commit for $(VERSION)"
	git tag v$(VERSION) -m "release v$(VERSION)"
	cpan-upload $(DISTVNAME).tar$(SUFFIX)
	git push --tags origin
	git push origin HEAD
distdir: readmefile
readmefile: create_distdir
	pod2text $(VERSION_FROM) >$(DISTVNAME)/README
	$(NOECHO) cd $(DISTVNAME) && $(ABSPERLRUN) ../Distar/helpers/add-readme-to-manifest
END
    if (open my $fh, '<', 'maint/Makefile.include') {
        $post .= do { local $/; <$fh> };
    }
    return $post;
}

{
  no warnings 'redefine';
  sub main::WriteMakefile {
    my %args = @_;
    ExtUtils::MakeMaker::WriteMakefile(
      LICENSE => 'perl',
      @_, AUTHOR => our $Author, ABSTRACT_FROM => $args{VERSION_FROM},
      test => { TESTS => ($args{test}{TESTS}||'t/*.t').' xt/*.t' },
    );
  }
}

END {
  write_manifest_skip() unless $Ran_Preflight
}

1;
