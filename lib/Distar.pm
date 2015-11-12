package Distar;
use strict;
use warnings FATAL => 'all';
use base qw(Exporter);
use ExtUtils::MakeMaker ();
use ExtUtils::MM ();

our $VERSION = '0.002000';
$VERSION = eval $VERSION;

my $MM_VER = eval $ExtUtils::MakeMaker::VERSION;

our @EXPORT = qw(
  author manifest_include readme_generator
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

our @Manifest = (
  'lib' => '.pm',
  'lib' => '.pod',
  't' => '.t',
  't/lib' => '.pm',
  'xt' => '.t',
  'xt/lib' => '.pm',
  '' => qr{[^/]*\.PL},
  '' => qr{Changes|MANIFEST|README|LICENSE|META\.yml},
  'maint' => qr{[^.].*},
);

sub manifest_include {
  push @Manifest, @_;
}

sub readme_generator {
  die "readme_generator unsupported" if @_ && $_[0];
}

sub write_manifest_skip {
  my ($mm) = @_;
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
  my $dist_name = $mm->{DISTNAME};
  my $include = join '|', map "${_}\$", @parts;
  my $final = "^(?:\Q$dist_name\E-v?[0-9_.]+/|(?!$include))";
  open my $skip, '>', 'MANIFEST.SKIP'
    or die "can't open MANIFEST.SKIP: $!";
  print $skip "${final}\n";
  close $skip;
}

{
  package Distar::MM;
  our @ISA = @MM::ISA;
  @MM::ISA = (__PACKAGE__);

  sub new {
    my ($class, $args) = @_;
    return $class->SUPER::new({
      LICENSE => 'perl_5',
      MIN_PERL_VERSION => '5.006',
      AUTHOR => ($MM_VER >= 6.5702 ? $Distar::Author : join(', ', @$Distar::Author)),
      ABSTRACT_FROM => $args->{VERSION_FROM},
      %$args,
      test => { TESTS => ($args->{test}{TESTS}||'t/*.t').' xt/*.t xt/*/*.t' },
      realclean => { FILES => (
        ($args->{realclean}{FILES}||'')
        . ' Distar/ MANIFEST.SKIP MANIFEST MANIFEST.bak'
      ) },
    });
  }

  sub flush {
    my $self = shift;
    Distar::write_manifest_skip($self);
    $self->SUPER::flush(@_);
  }

  sub special_targets {
    my $self = shift;
    my $targets = $self->SUPER::special_targets(@_);
    my $phony_targets = join ' ', qw(
      preflight
      releasetest
      release
      readmefile
      distmanicheck
      nextrelease
      refresh
      bump
      bumpmajor
      bumpminor
    );
    $targets =~ s/^(\.PHONY *:.*)/$1 $phony_targets/m;
    $targets;
  }

  sub dist_test {
    my $self = shift;

    my $include = '';
    if (open my $fh, '<', 'maint/Makefile.include') {
      $include = "\n# --- Makefile.include:\n\n" . do { local $/; <$fh> };
      $include =~ s/\n?\z/\n/;
    }

    my @bump_targets =
      grep { $include !~ /^bump$_(?: +\w+)*:/m } ('', 'minor', 'major');

    my %vars = (
      REMAKE => join(' ', '$(PERLRUN)', 'Makefile.PL', map { $self->quote_literal($_) } @ARGV),
      BRANCH => $self->{BRANCH} ||= 'master',
    );

    join('',
      $self->SUPER::dist_test(@_),
      "\n\n# --- Distar section:\n\n",
      (map "$_ = $vars{$_}\n", sort keys %vars),
      <<'END',

preflight:
	$(ABSPERLRUN) Distar/helpers/preflight $(VERSION) --branch=$(BRANCH)
releasetest:
	$(MAKE) disttest RELEASE_TESTING=1 PASTHRU="$(PASTHRU) TEST_FILES=\"$(TEST_FILES)\""
release: preflight releasetest
	$(RM_RF) $(DISTVNAME)
	$(MAKE) $(DISTVNAME).tar$(SUFFIX)
	git commit -a -m "Release commit for $(VERSION)"
	git tag v$(VERSION) -m "release v$(VERSION)"
	cpan-upload $(DISTVNAME).tar$(SUFFIX)
	git push origin v$(VERSION) HEAD
distdir: readmefile
readmefile: create_distdir $(DISTVNAME)/README
	$(NOECHO) cd $(DISTVNAME) && $(ABSPERLRUN) ../Distar/helpers/add-to-manifest README
$(DISTVNAME)/README: $(VERSION_FROM)
	$(NOECHO) $(MKPATH) $(DISTVNAME)
	pod2text $(VERSION_FROM) >$(DISTVNAME)/README
disttest: distmanicheck
distmanicheck: create_distdir
	cd $(DISTVNAME) && $(ABSPERLRUN) "-MExtUtils::Manifest=manicheck" -e "exit manicheck"
nextrelease:
	$(ABSPERLRUN) Distar/helpers/add-changelog-heading --git $(VERSION) Changes
refresh:
	cd Distar && git pull
	$(RM_F) $(FIRST_MAKEFILE)
	$(REMAKE)
END
      map(sprintf(<<'END', "bump$_", ($_ || '$(V)')), @bump_targets),
%s:
	$(ABSPERLRUN) Distar/helpers/bump-version --git $(VERSION) %s
	$(RM_F) $(FIRST_MAKEFILE)
	$(REMAKE)
END
      $include,
      "\n",
    );
  }
}

1;
