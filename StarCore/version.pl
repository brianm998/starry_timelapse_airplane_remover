#!/usr/bin/perl

use strict;

open my $fh, "<Sources/StarCore/Config.swift" or die "Cannot open config: $!";

while(<$fh>) {
    if(/public var starVersion = "([^"]+)"/) {
	print "$1\n";
	close $fh;
	exit;
    }
}

die "couldn't get starVersion from Sources/StarCore/Config.swift";
close $fh;
