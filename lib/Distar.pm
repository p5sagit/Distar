package Distar;
use strict;
use warnings FATAL => 'all';
use base qw(Exporter);
use ExtUtils::MakeMaker ();
use ExtUtils::MM ();
use File::Spec ();
use File::Basename ();

our $VERSION = '0.003000';
$VERSION =~ tr/_//d;

my $MM_VER = eval $ExtUtils::MakeMaker::VERSION;

our @EXPORT = qw(
  author manifest_include readme_generator
);

sub import {
  strict->import;
  warnings->import(FATAL => 'all');
  if (!(@MM::ISA == 1 && $MM::ISA[0] eq 'Distar::MM')) {
    @Distar::MM::ISA = @MM::ISA;
    @MM::ISA = qw(Distar::MM);
  }
  goto &Exporter::import;
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

  sub _gen_make_section {
    return join '',
      map {
        my @lines;
        if (ref) {
          @lines = @$_;
          s/^\t?/\t/mg for @lines;
        }
        else {
          @lines = $_;
        }
        s/\n?\z/\n/ for @lines;
        @lines;
      } @_;
  }

  sub new {
    my ($class, $args) = @_;
    my %test = %{$args->{test}||{}};
    my $tests = $test{TESTS} || 't/*.t';
    $tests !~ /\b\Q$_\E\b/ and $tests .= " $_"
      for 'xt/*.t', 'xt/*/*.t';
    $test{TESTS} = $tests;
    return $class->SUPER::new({
      LICENSE => 'perl_5',
      MIN_PERL_VERSION => '5.006',
      ($Distar::Author ? (
        AUTHOR => ($MM_VER >= 6.5702 ? $Distar::Author : join(', ', @$Distar::Author)),
      ) : ()),
      (exists $args->{ABSTRACT} ? () : (ABSTRACT_FROM => $args->{VERSION_FROM})),
      %$args,
      test => \%test,
      realclean => { FILES => (
        ($args->{realclean}{FILES}||'')
        . ' Distar/ MANIFEST.SKIP MANIFEST MANIFEST.bak'
      ) },
    });
  }

  sub flush {
    my $self = shift;
    `git ls-files --error-unmatch MANIFEST.SKIP 2>&1`;
    my $maniskip_tracked = !$?;

    Distar::write_manifest_skip($self)
      unless $maniskip_tracked;
    $self->SUPER::flush(@_);
  }

  sub special_targets {
    my $self = shift;
    my $targets = $self->SUPER::special_targets(@_);
    my $phony_targets = join ' ', qw(
      preflight
      check-version
      check-manifest
      check-cpan-upload
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

  sub init_dist {
    my $self = shift;
    my $out = $self->SUPER::init_dist(@_);

    my $dn = File::Spec->devnull;
    my $tar = $self->{TAR};

    my $tarflags = $self->{TARFLAGS};
    if (my ($flags) = $tarflags =~ /^-?([cvhlLf]+)$/) {
      if ($flags =~ s/c// && $flags =~ s/f//) {
        $tarflags = '--format=ustar -c'.$flags.'f';
        my $me = __FILE__;
        for my $options ('--owner=0 --group=0', '--uid=0 --gid=0') {
          my $try = `$tar -c $options "$me" 2>$dn`;
          if (length $try) {
            $tarflags = "$options $tarflags";
            last;
          }
        }
      }
    }

    $self->{TAR} = $tar;
    $self->{TARFLAGS} = $tarflags;

    $out;
  }

  sub libscan {
    my $self = shift;
    my ($path) = @_;

    # default setup for Distar involves checking it out as a subdirectory at
    # the top of the dist.  Without NORECURS, EUMM would try to include
    # Distar's Makefile.PL.  Prevent EUMM from looking inside.
    return ''
      if $path eq 'Distar';

    $self->SUPER::libscan(@_);
  }

  sub tarfile_target {
    my $self = shift;
    my $out = $self->SUPER::tarfile_target(@_);
    my $verify = _gen_make_section([
      '$(ABSPERLRUN) $(HELPERS)/verify-tarball $(DISTVNAME).tar $(DISTVNAME)/MANIFEST --tar="$(TAR)"',
    ]);
    $out =~ s{(\$\(TAR\).*\n)}{$1$verify};
    $out;
  }

  sub dist_test {
    my $self = shift;

    my $distar_lib = File::Basename::dirname(__FILE__);
    my $helpers = File::Spec->catdir($distar_lib, 'Distar', 'helpers');

    my $licenses = $self->{LICENSE} || $self->{META_ADD}{license} || $self->{META_MERGE}{license};
    my $authors = $self->{AUTHOR};
    $_ = ref $_ ? $_ : [$_ || ()]
      for $licenses, $authors;

    my %vars = (
      DISTAR_LIB => $self->quote_literal($distar_lib),
      HELPERS => $self->quote_literal($helpers),
      REMAKE => join(' ', '$(PERLRUN)', '-I$(DISTAR_LIB)', '-MDistar', 'Makefile.PL', map { $self->quote_literal($_) } @ARGV),
      BRANCH => $self->{BRANCH} ||= 'master',
      CHANGELOG => $self->{CHANGELOG} ||= 'Changes',
      DEV_NULL_STDOUT => ($self->{DEV_NULL} ? '>'.File::Spec->devnull : ''),
      DISTTEST_MAKEFILE_PARAMS => '',
      AUTHORS => $self->quote_literal(join(', ', @$authors)),
      LICENSES => join(' ', map $self->quote_literal($_), @$licenses),
      GET_CHANGELOG => '$(ABSPERLRUN) $(HELPERS)/get-changelog $(VERSION) $(CHANGELOG)',
      UPDATE_DISTAR => (
        -e File::Spec->catdir($distar_lib, File::Spec->updir, '.git')
          ? 'git -C $(DISTAR_LIB) pull'
          : '$(ECHO) "Distar code is not in a git repo, unable to update!"'
      ),
    );

    my $dist_test = $self->SUPER::dist_test(@_);
    $dist_test =~ s/(\bMakefile\.PL\b)/$1 \$(DISTTEST_MAKEFILE_PARAMS)/;

    my $include = '';
    if (open my $fh, '<', 'maint/Makefile.include') {
      $include = do { local $/; <$fh> };
      $include =~ s/\n?\z/\n/;
    }

    my @out;

    push @out, (
      'preflight: check-version check-manifest check-cpan-upload' => [
        '$(ABSPERLRUN) $(HELPERS)/preflight $(VERSION) --changelog=$(CHANGELOG) --branch=$(BRANCH)',
      ],
      'check-version:' => [
        '$(ABSPERLRUN) $(HELPERS)/check-version $(VERSION) $(TO_INST_PM) $(EXE_FILES)',
      ],
      'check-manifest:' => [
        '$(ABSPERLRUN) $(HELPERS)/check-manifest',
      ],
      'check-cpan-upload:' => [
        '$(NOECHO) cpan-upload -h $(DEV_NULL_STDOUT)',
      ],
      'releasetest:' => [
        '$(MAKE) disttest RELEASE_TESTING=1 DISTTEST_MAKEFILE_PARAMS="PREREQ_FATAL=1" PASTHRU="$(PASTHRU) TEST_FILES=\"$(TEST_FILES)\""',
        '$(NOECHO) $(TEST_F) $(DISTVNAME)/LICENSE || $(ECHO) "Failed to generate $(DISTVNAME)/LICENSE!" >&2',
        '$(NOECHO) $(TEST_F) $(DISTVNAME)/LICENSE',
      ],
      'release: preflight' => [
        '$(MAKE) releasetest',
        '$(GET_CHANGELOG) -p"Release commit for $(VERSION)" | git commit -a -F -',
        '$(GET_CHANGELOG) -p"release v$(VERSION)" | git tag -a -F - "v$(VERSION)"',
        '$(RM_RF) $(DISTVNAME)',
        '$(MAKE) $(DISTVNAME).tar$(SUFFIX)',
        '$(NOECHO) $(MAKE) pushrelease FAKE_RELEASE=$(FAKE_RELEASE)',
      ],
      'pushrelease ::' => [
        '$(NOECHO) $(NOOP)',
      ],
      'pushrelease$(FAKE_RELEASE) ::' => [
        'cpan-upload $(DISTVNAME).tar$(SUFFIX)',
        'git push origin v$(VERSION) HEAD',
      ],
      'distdir: readmefile licensefile',
      'readmefile: create_distdir' => [
        '$(NOECHO) $(TEST_F) $(DISTVNAME)/README || $(MAKE) $(DISTVNAME)/README',
      ],
      '$(DISTVNAME)/README: $(VERSION_FROM)' => [
        '$(NOECHO) $(MKPATH) $(DISTVNAME)',
        'pod2text $(VERSION_FROM) >$(DISTVNAME)/README',
        '$(NOECHO) $(ABSPERLRUN) $(HELPERS)/add-to-manifest -d $(DISTVNAME) README',
      ],
      'distsignature: readmefile licensefile',
      'licensefile: create_distdir' => [
        '$(NOECHO) $(TEST_F) $(DISTVNAME)/LICENSE || $(MAKE) $(DISTVNAME)/LICENSE || $(TRUE)',
      ],
      '$(DISTVNAME)/LICENSE: Makefile.PL' => [
        '$(NOECHO) $(MKPATH) $(DISTVNAME)',
        '$(ABSPERLRUN) $(HELPERS)/generate-license -o $(DISTVNAME)/LICENSE $(AUTHORS) $(LICENSES)',
        '$(NOECHO) $(ABSPERLRUN) $(HELPERS)/add-to-manifest -d $(DISTVNAME) LICENSE',
      ],
      'disttest: distmanicheck',
      'distmanicheck: create_distdir' => [
        $self->cd('$(DISTVNAME)',
          '$(ABSPERLRUN) "-MExtUtils::Manifest=manicheck" -e "exit manicheck"',
        ),
      ],
      'nextrelease:' => [
        '$(ABSPERLRUN) $(HELPERS)/add-changelog-heading --git $(VERSION) $(CHANGELOG)',
      ],
      'refresh:' => [
        '$(UPDATE_DISTAR)',
        '$(RM_F) $(FIRST_MAKEFILE)',
        '$(REMAKE)',
      ],
    );

    my @bump_targets =
      grep { $include !~ /^bump$_(?: +\w+)*:/m } ('', 'minor', 'major');

    push @out, map +(
      "bump$_:" => [
        '$(ABSPERLRUN) $(HELPERS)/bump-version --git $(VERSION) '.($_ || '$(V)'),
        '$(RM_F) $(FIRST_MAKEFILE)',
        '$(REMAKE)',
      ],
    ), @bump_targets;

    join('',
      $dist_test,
      "\n\n# --- Distar section:\n\n",
      (map "$_ = $vars{$_}\n", sort keys %vars),
      "\n",
      _gen_make_section(@out),
      ($include ? (
        "\n",
        "# --- Makefile.include:\n",
        "\n",
        $include,
        "\n"
      ) : ()),
      "\n",
    );
  }
}

1;
__END__

=head1 NAME

Distar - Additions to ExtUtils::MakeMaker for dist authors

=head1 SYNOPSIS

F<Makefile.PL>:

  use ExtUtils::MakeMaker;
  (do './maint/Makefile.PL.include' or die $@) unless -f 'META.yml';

  WriteMakefile(...);

F<maint/Makefile.PL.include>:

  BEGIN { -e 'Distar' or system("git clone git://git.shadowcat.co.uk/p5sagit/Distar.git") }
  use lib 'Distar/lib';
  use Distar 0.001;

  author 'A. U. Thor <author@cpan.org>';

  manifest_include t => 'test-helper.pl';
  manifest_include corpus => '.txt';

make commmands:

  $ perl Makefile.PL
  $ make bump             # bump version
  $ make bump V=2.000000  # bump to specific version
  $ make bumpminor        # bump minor version component
  $ make bumpmajor        # bump major version component
  $ make nextrelease      # add version heading to Changes file
  $ make releasetest      # build dist and test (with xt/ and RELEASE_TESTING=1)
  $ make preflight        # check that repo and file state is release ready
  $ make release          # check releasetest and preflight, commits and tags,
                          # builds and uploads to CPAN, and pushes commits and
                          # tag
  $ make release FAKE_RELEASE=1
                          # builds a release INCLUDING committing and tagging,
                          # but does not upload to cpan or push anything to git

=head1 DESCRIPTION

L<ExtUtils::MakeMaker> works well enough as development tool for
builting and testing, but using it to release is annoying and error prone.
Distar adds just enough to L<ExtUtils::MakeMaker> for it to be a usable dist
author tool.  This includes extra commands for releasing and safety checks, and
automatic generation of some files.  It doesn't require any non-core modules and
is compatible with old versions of perl.

=head1 FUNCTIONS

=head2 author( $author )

Set the author to include in generated META files.  Can be a single entry, or
an arrayref.

=head2 manifest_include( $dir, $pattern )

Add a pattern to include files in the MANIFEST file, and thus in the generated
dist files.

The pattern can be either a regex, or a path suffix.  It will be applied to the
full path past the directory specified.

The default files that are always included are: F<.pm> and F<.pod> files in
F<lib>, F<.t> files in F<t> and F<xt>, F<.pm> files in F<t/lib> and F<xt/lib>,
F<Changes>, F<MANIFEST>, F<README>, F<LICENSE>, F<META.yml>, and F<.PL> files in
the dist root, and all files in F<maint>.

=head1 AUTOGENERATED FILES

=over 4

=item F<MANIFEST.SKIP>

The F<MANIFEST.SKIP> will be automatically generated to exclude any files not
explicitly allowed via C<manifest_include> or the included defaults.  It will be
created (or updated) at C<perl Makefile.PL> time.

=item F<README>

The F<README> file will be generated at dist generation time, inside the built
dist.  It will be generated using C<pod2text> on the main module.

If a F<README> file exists in the repo, it will be used directly instead of
generating the file.

=back

=head1 MAKE COMMMANDS

=head2 test

test will be adjusted to include F<xt/> tests by default.  This will only apply
for authors, not users installing from CPAN.

=head2 release

Releases the dist.  Before releasing, checks will be done on the dist using the
C<preflight> and C<releasetest> commands.

Releasing will generate a dist tarball and upload it to CPAN using cpan-upload.
It will also create a git tag for the release, and push the tag and branch.

=head3 FAKE_RELEASE

If release is run with FAKE_RELEASE=1 set, it will skip uploading to CPAN and
pushing to git.  A release commit will still be created and tagged locally.

=head2 preflight

Performs a number of checks on the files and repository, ensuring it is in a
sane state to do a release.  The checks are:

=over 4

=item * All version numbers match

=item * The F<MANIFEST> file is up to date

=item * The branch is correct

=item * There is no existing tag for the version

=item * There are no unmerged upstream changes

=item * There are no outstanding local changes

=item * There is an appropriate staged Changes heading

=item * cpan-upload is available

=back

=head2 releasetest

Test the dist preparing for a release.  This generates a dist dir and runs the
tests from inside it.  This ensures all appropriate files are included inside
the dist.  C<RELEASE_TESTING> will be set in the environment.

=head2 nextrelease

Adds an appropriate changelog heading for the release, and prompts to stage the
change.

=head2 bump

Bumps the version number.  This will try to preserve the length and format of
the version number.  The least significant digit will be incremented.  Versions
with underscores will preserve the underscore in the same position.

Optionally accepts a C<V> option to set the version to a specific value.

The version changes will automatically be committed.  Unstaged modifications to
the files will be left untouched.

=head3 V

The V option will be passed along to the version bumping script.  It can accept
a space separated list of options, including an explicit version number.

Options:

=over 4

=item --force

Updates version numbers even if they do not match the current expected version
number.

=item --stable

Attempts to convert the updated version to a stable version, removing any
underscore.

=item --alpha

Attempts to convert the updated version to an alpha version, adding an
underscore in an appropriate place.

=back

=head2 bumpminor

Like bump, but increments the minor segment of the version.  This will treat
numeric versions as x.yyyzzz format, incrementing the yyy segment.

=head2 bumpmajor

Like bumpminor, but bumping the major segment.

=head2 refresh

Updates Distar and re-runs C<perl Makefile.PL>

=head1 SUPPORT

IRC: #web-simple on irc.perl.org

Git repository: L<git://git.shadowcat.co.uk/p5sagit/Distar>

Git browser: L<http://git.shadowcat.co.uk/gitweb/gitweb.cgi?p=p5sagit/Distar.git;a=summary>

=head1 AUTHOR

mst - Matt S. Trout (cpan:MSTROUT) <mst@shadowcat.co.uk>

=head1 CONTRIBUTORS

haarg - Graham Knop (cpan:HAARG) <haarg@cpan.org>

ether - Karen Etheridge (cpan:ETHER) <ether@cpan.org>

frew - Arthur Axel "fREW" Schmidt (cpan:FREW) <frioux@gmail.com>

Mithaldu - Christian Walde (cpan:MITHALDU) <walde.christian@googlemail.com>

=head1 COPYRIGHT

Copyright (c) 2011-2015 the Distar L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself. See L<http://dev.perl.org/licenses/>.

=cut
