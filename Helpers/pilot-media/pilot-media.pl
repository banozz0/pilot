# pilot-media.pl <pilot-media.dylib> pause|play: runs pilot-media.m's function of that name inside /usr/bin/perl, which
# macOS lets read what is playing (see pilot-media.m).
use strict;
use warnings;
use DynaLoader;

my ($library, $command) = @ARGV;
die "usage: pilot-media.pl <library> pause|play\n" unless defined $command && $command =~ /^(pause|play)$/;
my $handle = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "pilot_media_$command") or die DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::run", $symbol);
main::run();
