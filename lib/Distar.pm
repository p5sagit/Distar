package Distar;

use strictures 1;
use base qw(Exporter);

our @EXPORT = qw(
  author manifest_include
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
  '' => qr{t/smells-of-vcs/.svn},
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

sub MY::postamble { <<'END'; }
upload: $(DISTVNAME).tar$(SUFFIX)
	cpan-upload $<
release: upload
	git commit -a -m "Release commit for $(VERSION)"
	git tag release_$(VERSION)
	git push
	git push --tags
END

{
  no warnings 'redefine';
  sub main::WriteMakefile {
    my %args = @_;
    system("pod2text $args{VERSION_FROM} >README");
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
