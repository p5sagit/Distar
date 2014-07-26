package Distar;

use strict;
use warnings FATAL => 'all';
use base qw(Exporter);
use ExtUtils::MakeMaker ();
use ExtUtils::MM ();

use Config;
use File::Spec;

our $VERSION = '0.001000';
$VERSION = eval $VERSION;

my $MM_VER = eval $ExtUtils::MakeMaker::VERSION;

our @EXPORT = qw(
  author manifest_include run_preflight
);

sub import {
  strict->import;
  warnings->import(FATAL => 'all');
  shift->export_to_level(1,@_);
}

sub author {
  our $Author = shift;
  $Author = [ $Author ]
    if !ref $Author;
}

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
  open my $skip, '>', 'MANIFEST.SKIP'
    or die "can't open MANIFEST.SKIP: $!";
  print $skip "${final}\n";
  close $skip;
}

sub run_preflight {
  $Ran_Preflight = 1;
  my $version = $ARGV[0];

  my $make = $Config{make};
  my $null = File::Spec->devnull;

  system("git fetch");
  if (system("git rev-parse --quiet --verify v$version >$null") == 0) {
    die "Tag v$version already exists!";
  }

  require File::Find;
  File::Find::find({ no_chdir => 1, wanted => sub {
    return
      unless -f && /\.pm$/;
    my $file_version = MM->parse_version($_);
    die "Module $_ version $file_version doesn't match dist version $version"
      unless $file_version eq 'undef' || $file_version eq $version;
  }}, 'lib');

  for (scalar `"$make" manifest 2>&1 >$null`) {
    $_ && die "$make manifest changed:\n$_ Go check it and retry";
  }

  for (scalar `git status`) {
    /^(?:# )?On branch master/ || die "Not on master. EEEK";
    /Your branch is behind|Your branch and .*? have diverged/ && die "Not synced with upstream";
  }

  for (scalar `git diff`) {
    length && die "Outstanding changes";
  }
  my $ymd = sprintf(
    "%i-%02i-%02i", (gmtime)[5]+1900, (gmtime)[4]+1, (gmtime)[3]
  );
  my $changes_line = "$version - $ymd\n";
  my @cached = grep /^\+/, `git diff --cached -U0`;
  @cached > 0 or die "Please add:\n\n$changes_line\nto Changes stage Changes (git add Changes)";
  @cached == 2 or die "Pre-commit Changes not just Changes line";
  $cached[0] =~ /^\+\+\+ .\/Changes\n/ or die "Changes not changed";
  $cached[1] eq "+$changes_line" or die "Changes new line should be: \n\n$changes_line ";

  { no warnings 'exec'; `cpan-upload -h`; }
  $? and die "cpan-upload not available";
}

{
  package Distar::MM;
  our @ISA = @ExtUtils::MM::ISA;
  @ExtUtils::MM::ISA = (__PACKAGE__);

  sub new {
    my ($class, $args) = @_;
    return $class->SUPER::new({
      LICENSE => 'perl_5',
      MIN_PERL_VERSION => '5.006',
      AUTHOR => ($MM_VER >= 6.5702 ? $Distar::Author : $Distar::Author->[0]),
      %$args,
      ABSTRACT_FROM => $args->{VERSION_FROM},
      test => { TESTS => ($args->{test}{TESTS}||'t/*.t').' xt/*.t xt/*/*.t' },
    });
  }

  sub dist_test {
    my $self = shift;
    my $dist_test = $self->SUPER::dist_test(@_) . <<'END';

# --- Distar section:
preflight:
	perl -IDistar/lib -MDistar -erun_preflight $(VERSION)
release: preflight
	$(MAKE) disttest
	rm -rf $(DISTVNAME)
	$(MAKE) $(DISTVNAME).tar$(SUFFIX)
	git commit -a -m "Release commit for $(VERSION)"
	git tag v$(VERSION) -m "release v$(VERSION)"
	cpan-upload $(DISTVNAME).tar$(SUFFIX)
	git push origin v$(VERSION) HEAD
distdir: readmefile
readmefile: create_distdir
	pod2text $(VERSION_FROM) >$(DISTVNAME)/README
	$(NOECHO) cd $(DISTVNAME) && $(ABSPERLRUN) ../Distar/helpers/add-readme-to-manifest
disttest: distmanicheck
distmanicheck: create_distdir
	cd $(DISTVNAME) && $(ABSPERLRUN) "-MExtUtils::Manifest=manicheck" -e "exit manicheck"

END
    if (open my $fh, '<', 'maint/Makefile.include') {
      $dist_test .= do { local $/; <$fh> };
    }
    return $dist_test;
  }
}

END {
  write_manifest_skip() unless $Ran_Preflight
}

1;
