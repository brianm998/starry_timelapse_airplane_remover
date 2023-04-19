#!/usr/bin/perl

use strict;

open my $fh, "<Sources/NtarCore/Config.swift" or die $!;

while(<$fh>) {
    if(/public var ntar_version = "([^"]+)"/) {
	print "$1\n";
	last
    }
}
close $fh
