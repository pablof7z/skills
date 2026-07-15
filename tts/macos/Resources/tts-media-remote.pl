#!/usr/bin/perl
# Derived from mediaremote-adapter by Jonas van den Berg and contributors.
# Licensed under the BSD 3-Clause License; see ThirdParty/MediaRemoteAdapter-LICENSE.txt.

use strict;
use warnings;
use DynaLoader;

die "Usage: $0 <adapter-dylib> <get|pause|play>\n" unless @ARGV == 2;
my ($library_path, $command) = @ARGV;
die "Adapter not found: $library_path\n" unless -f $library_path;
die "Unsupported command: $command\n" unless $command =~ /^(get|pause|play)$/;

my $library = DynaLoader::dl_load_file($library_path, 0)
    or die "Unable to load adapter: " . DynaLoader::dl_error() . "\n";
my $function = $command eq 'get' ? 'tts_media_remote_get' : 'tts_media_remote_send_env';
my $symbol = DynaLoader::dl_find_symbol($library, "_$function")
    || DynaLoader::dl_find_symbol($library, $function)
    || die "Adapter symbol not found: $function\n";
DynaLoader::dl_install_xsub("main::$function", $symbol);

if ($command eq 'get') {
    tts_media_remote_get();
} else {
    $ENV{TTS_MEDIA_REMOTE_COMMAND} = $command;
    tts_media_remote_send_env();
}
