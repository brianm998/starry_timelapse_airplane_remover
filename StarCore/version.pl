#!/usr/bin/perl

use strict;

open my $fh, "<Sources/StarCore/Config.swift" or die "Cannot open config: $!";

while(<$fh>) {
    if(/public var star_version = "([^"]+)"/) {
	print "$1\n";
	last
    }
}
close $fh
